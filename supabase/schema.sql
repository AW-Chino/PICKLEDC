-- Pickleball Umpire: shared tournament data, match results and activity logs.
-- Run once in the Supabase SQL editor.
--
-- Security model: tables have row level security on and NO policies, so the public
-- (anon/publishable) key cannot touch them directly. Everything goes through the
-- pb_* functions below, which check the shared tournament password first.

create extension if not exists pgcrypto;

create table if not exists tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by text,
  created_at timestamptz not null default now()
);

create table if not exists categories (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references tournaments(id) on delete cascade,
  name text not null,
  code text not null,
  created_at timestamptz not null default now()
);

create table if not exists teams (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references categories(id) on delete cascade,
  code text not null,
  player1 text not null,
  player2 text not null,
  created_at timestamptz not null default now()
);

create table if not exists matches (
  id text primary key,                 -- generated on the phone
  tournament_id uuid references tournaments(id) on delete set null,
  category_id uuid references categories(id) on delete set null,
  team_a uuid references teams(id) on delete set null,
  team_b uuid references teams(id) on delete set null,
  mode text not null default 'tournament',   -- tournament | open
  label text,                                -- e.g. "Men's Doubles · MD-01 vs MD-04"
  players jsonb,                             -- {"A":{"code","p1","p2"},"B":{...}}
  umpire text,
  status text not null default 'live',       -- live | final | ended_early | discarded
  score_a int not null default 0,
  score_b int not null default 0,
  winner text,                               -- A | B | null
  target int,
  time_limit_min int,
  duration_ms int,
  started_at timestamptz,
  ended_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists match_events (
  id text primary key,                 -- generated on the phone, so re-sending is safe
  match_id text not null references matches(id) on delete cascade,
  seq int not null,
  at timestamptz not null,             -- real time on the umpire's phone
  game_ms int not null default 0,      -- game clock when it happened
  umpire text,
  kind text not null,
  detail text,
  score text
);
create index if not exists match_events_match on match_events(match_id, seq);

create table if not exists umpires (
  name text primary key,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now()
);

alter table tournaments  enable row level security;
alter table categories   enable row level security;
alter table teams        enable row level security;
alter table matches      enable row level security;
alter table match_events enable row level security;
alter table umpires      enable row level security;

-- ---------- password gate ----------
create or replace function pb_auth(p_pass text) returns void
language plpgsql security definer set search_path = public as $$
begin
  -- Replace the placeholder with the real password when running this. Never commit the real one.
  if p_pass is distinct from '__TOURNAMENT_PASSWORD__' then
    raise exception 'wrong password' using errcode = '28P01';
  end if;
end $$;

create or replace function pb_check(p_pass text, p_umpire text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform pb_auth(p_pass);
  if coalesce(trim(p_umpire), '') <> '' then
    insert into umpires(name) values (trim(p_umpire))
    on conflict (name) do update set last_seen = now();
  end if;
  return true;
end $$;

-- ---------- tournament data ----------
create or replace function pb_get_data(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform pb_auth(p_pass);
  return jsonb_build_object(
    'tournaments', coalesce((select jsonb_agg(t order by t.created_at) from tournaments t), '[]'::jsonb),
    'categories',  coalesce((select jsonb_agg(c order by c.created_at) from categories c), '[]'::jsonb),
    'teams',       coalesce((select jsonb_agg(x order by x.code) from teams x), '[]'::jsonb)
  );
end $$;

-- p_kind: tournament | category | team. p_row carries the columns; id is optional for inserts.
create or replace function pb_save(p_pass text, p_kind text, p_row jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce(nullif(p_row->>'id','')::uuid, gen_random_uuid());
begin
  perform pb_auth(p_pass);
  if p_kind = 'tournament' then
    insert into tournaments(id, name, created_by) values (v_id, p_row->>'name', p_row->>'created_by')
    on conflict (id) do update set name = excluded.name;
  elsif p_kind = 'category' then
    insert into categories(id, tournament_id, name, code)
    values (v_id, (p_row->>'tournament_id')::uuid, p_row->>'name', p_row->>'code')
    on conflict (id) do update set name = excluded.name, code = excluded.code;
  elsif p_kind = 'team' then
    insert into teams(id, category_id, code, player1, player2)
    values (v_id, (p_row->>'category_id')::uuid, p_row->>'code', p_row->>'player1', p_row->>'player2')
    on conflict (id) do update set code = excluded.code, player1 = excluded.player1, player2 = excluded.player2;
  else
    raise exception 'unknown kind %', p_kind;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function pb_delete(p_pass text, p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pb_auth(p_pass);
  if p_kind = 'tournament' then delete from tournaments where id = p_id;
  elsif p_kind = 'category' then delete from categories where id = p_id;
  elsif p_kind = 'team' then delete from teams where id = p_id;
  else raise exception 'unknown kind %', p_kind;
  end if;
end $$;

-- ---------- matches & logs ----------
-- Upserts the match summary and appends any events not already stored.
create or replace function pb_sync_match(p_pass text, p_match jsonb, p_events jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform pb_auth(p_pass);
  insert into matches(id, tournament_id, category_id, team_a, team_b, mode, label, players, umpire, status,
                      score_a, score_b, winner, target, time_limit_min, duration_ms, started_at, ended_at, updated_at)
  values (p_match->>'id',
          nullif(p_match->>'tournament_id','')::uuid, nullif(p_match->>'category_id','')::uuid,
          nullif(p_match->>'team_a','')::uuid, nullif(p_match->>'team_b','')::uuid,
          coalesce(p_match->>'mode','tournament'), p_match->>'label', p_match->'players', p_match->>'umpire',
          coalesce(p_match->>'status','live'),
          coalesce((p_match->>'score_a')::int,0), coalesce((p_match->>'score_b')::int,0), p_match->>'winner',
          (p_match->>'target')::int, (p_match->>'time_limit_min')::int, (p_match->>'duration_ms')::int,
          (p_match->>'started_at')::timestamptz, (p_match->>'ended_at')::timestamptz, now())
  on conflict (id) do update set
    label = excluded.label, players = excluded.players, umpire = excluded.umpire, status = excluded.status,
    score_a = excluded.score_a, score_b = excluded.score_b, winner = excluded.winner,
    duration_ms = excluded.duration_ms, ended_at = excluded.ended_at, updated_at = now();

  insert into match_events(id, match_id, seq, at, game_ms, umpire, kind, detail, score)
  select e->>'id', p_match->>'id', (e->>'seq')::int, (e->>'at')::timestamptz, coalesce((e->>'game_ms')::int,0),
         e->>'umpire', e->>'kind', e->>'detail', e->>'score'
  from jsonb_array_elements(coalesce(p_events,'[]'::jsonb)) e
  on conflict (id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function pb_matches(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform pb_auth(p_pass);
  return coalesce((select jsonb_agg(m order by m.started_at desc nulls last)
                   from (select * from matches where status <> 'discarded' order by started_at desc nulls last limit 300) m),
                  '[]'::jsonb);
end $$;

create or replace function pb_match_log(p_pass text, p_match_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform pb_auth(p_pass);
  return coalesce((select jsonb_agg(e order by e.seq) from match_events e where e.match_id = p_match_id), '[]'::jsonb);
end $$;

-- Only the pb_* entry points are callable from the app.
revoke all on function pb_auth(text) from public, anon, authenticated;
grant execute on function pb_check(text, text), pb_get_data(text), pb_save(text, text, jsonb),
  pb_delete(text, text, uuid), pb_sync_match(text, jsonb, jsonb), pb_matches(text), pb_match_log(text, text)
  to anon, authenticated;
