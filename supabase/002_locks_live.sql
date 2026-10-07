-- Team locks, single scorer per match, and live viewing.
-- Run after schema.sql. Safe to run more than once.
--
-- A team is locked while it is in a match with status 'live' that was updated in the last 30 minutes.
-- Each match belongs to the phone (device_id) that started it; other phones can only read it,
-- unless an umpire uses "Take over scoring", which moves the match to their phone.

alter table matches add column if not exists device_id text;
alter table matches add column if not exists state jsonb;   -- full scoreboard state for live viewers

create or replace function pb_get_data(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform pb_auth(p_pass);
  return jsonb_build_object(
    'tournaments', coalesce((select jsonb_agg(t order by t.created_at) from tournaments t), '[]'::jsonb),
    'categories',  coalesce((select jsonb_agg(c order by c.created_at) from categories c), '[]'::jsonb),
    'teams',       coalesce((select jsonb_agg(x order by x.code) from teams x), '[]'::jsonb),
    'live',        coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'team_a', m.team_a, 'team_b', m.team_b,
                                                                'umpire', m.umpire, 'label', m.label, 'device_id', m.device_id))
                             from matches m
                             where m.status = 'live' and m.updated_at > now() - interval '30 minutes'), '[]'::jsonb)
  );
end $$;

-- Claims both teams for a new tournament match. Returns {ok:false,...} if either team is busy.
create or replace function pb_start_match(p_pass text, p_match jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v record;
  ta uuid := nullif(p_match->>'team_a','')::uuid;
  tb uuid := nullif(p_match->>'team_b','')::uuid;
begin
  perform pb_auth(p_pass);
  lock table matches in share row exclusive mode;   -- two umpires starting at once can't both win
  select m.id, m.label, m.umpire, m.team_a, m.team_b into v
  from matches m
  where m.status = 'live' and m.id <> p_match->>'id' and m.updated_at > now() - interval '30 minutes'
    and (m.team_a in (ta, tb) or m.team_b in (ta, tb))
  limit 1;
  if found then
    return jsonb_build_object('ok', false, 'label', v.label, 'umpire', v.umpire, 'team_a', v.team_a, 'team_b', v.team_b);
  end if;
  insert into matches(id, tournament_id, category_id, team_a, team_b, mode, label, players, umpire, status,
                      target, time_limit_min, started_at, device_id, state, updated_at)
  values (p_match->>'id', nullif(p_match->>'tournament_id','')::uuid, nullif(p_match->>'category_id','')::uuid,
          ta, tb, coalesce(p_match->>'mode','tournament'), p_match->>'label', p_match->'players', p_match->>'umpire',
          'live', (p_match->>'target')::int, (p_match->>'time_limit_min')::int, (p_match->>'started_at')::timestamptz,
          p_match->>'device_id', p_match->'state', now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- Only the phone that owns a match may update it.
create or replace function pb_sync_match(p_pass text, p_match jsonb, p_events jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int; v_dev text; v_ump text;
begin
  perform pb_auth(p_pass);
  select device_id, umpire into v_dev, v_ump from matches where id = p_match->>'id' for update;
  if v_dev is not null and v_dev is distinct from p_match->>'device_id' then
    raise exception 'taken over by %', coalesce(v_ump, 'another umpire') using errcode = 'P0001';
  end if;

  insert into matches(id, tournament_id, category_id, team_a, team_b, mode, label, players, umpire, status,
                      score_a, score_b, winner, target, time_limit_min, duration_ms, started_at, ended_at,
                      device_id, state, updated_at)
  values (p_match->>'id',
          nullif(p_match->>'tournament_id','')::uuid, nullif(p_match->>'category_id','')::uuid,
          nullif(p_match->>'team_a','')::uuid, nullif(p_match->>'team_b','')::uuid,
          coalesce(p_match->>'mode','tournament'), p_match->>'label', p_match->'players', p_match->>'umpire',
          coalesce(p_match->>'status','live'),
          coalesce((p_match->>'score_a')::int,0), coalesce((p_match->>'score_b')::int,0), p_match->>'winner',
          (p_match->>'target')::int, (p_match->>'time_limit_min')::int, (p_match->>'duration_ms')::int,
          (p_match->>'started_at')::timestamptz, (p_match->>'ended_at')::timestamptz,
          p_match->>'device_id', p_match->'state', now())
  on conflict (id) do update set
    label = excluded.label, players = excluded.players, umpire = excluded.umpire, status = excluded.status,
    score_a = excluded.score_a, score_b = excluded.score_b, winner = excluded.winner,
    duration_ms = excluded.duration_ms, ended_at = excluded.ended_at,
    device_id = coalesce(excluded.device_id, matches.device_id),
    state = coalesce(excluded.state, matches.state), updated_at = now();

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
  return coalesce((select jsonb_agg(to_jsonb(m) - 'state' order by m.started_at desc nulls last)
                   from (select * from matches where status <> 'discarded' order by started_at desc nulls last limit 300) m),
                  '[]'::jsonb);
end $$;

-- What a live viewer polls every few seconds.
create or replace function pb_match_state(p_pass text, p_match_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform pb_auth(p_pass);
  return (select jsonb_build_object('id', id, 'status', status, 'umpire', umpire, 'device_id', device_id,
                                    'state', state, 'updated_at', updated_at, 'label', label)
          from matches where id = p_match_id);
end $$;

-- Moves a live match to another phone (when the scoring phone dies). The old phone is locked out.
create or replace function pb_takeover(p_pass text, p_match_id text, p_device text, p_umpire text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  perform pb_auth(p_pass);
  update matches set device_id = p_device, umpire = p_umpire, updated_at = now()
  where id = p_match_id and status = 'live'
  returning state into v;
  if not found then
    raise exception 'match is not live' using errcode = 'P0001';
  end if;
  return v;
end $$;

grant execute on function pb_start_match(text, jsonb), pb_match_state(text, text), pb_takeover(text, text, text, text)
  to anon, authenticated;
