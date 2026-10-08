-- Admin role, official teams, and admin tools. Run after 004_signin.sql.
-- Replace both placeholders with the real passwords when running. Never commit them.
--   __TOURNAMENT_PASSWORD__  umpires
--   __ADMIN_PASSWORD__       organizer only

alter table teams add column if not exists official boolean not null default false;

create table if not exists settings (key text primary key, value jsonb);
alter table settings enable row level security;

-- Either password lets you in; only the admin one unlocks admin functions.
create or replace function pb_auth(p_pass text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_pass is distinct from '__TOURNAMENT_PASSWORD__' and p_pass is distinct from '__ADMIN_PASSWORD__' then
    raise exception 'wrong password' using errcode = '28P01';
  end if;
end $$;

create or replace function pb_is_admin(p_pass text) returns boolean
language sql security definer set search_path = public as $$
  select p_pass = '__ADMIN_PASSWORD__'
$$;

create or replace function pb_admin(p_pass text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not pb_is_admin(p_pass) then
    raise exception 'admin only' using errcode = '42501';
  end if;
end $$;

create or replace function pb_hide_official() returns boolean
language sql security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::boolean from settings where key = 'hide_official'), false)
$$;

-- Sign-in: case-insensitive umpire name, plus whether this password is the admin one.
create or replace function pb_login(p_pass text, p_umpire text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v text;
  n text := regexp_replace(trim(coalesce(p_umpire, '')), '\s+', ' ', 'g');
begin
  perform pb_auth(p_pass);
  if n <> '' then
    select name into v from umpires where lower(name) = lower(n) limit 1;
    if v is null then
      insert into umpires(name) values (n) returning name into v;
    else
      update umpires set last_seen = now() where name = v;
    end if;
  end if;
  return jsonb_build_object('name', coalesce(v, n), 'admin', pb_is_admin(p_pass));
end $$;

-- Official teams are left out for umpires while the admin has them hidden.
create or replace function pb_get_data(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare adm boolean; hide boolean;
begin
  perform pb_auth(p_pass);
  adm := pb_is_admin(p_pass);
  hide := pb_hide_official();
  return jsonb_build_object(
    'admin', adm,
    'settings', jsonb_build_object('hide_official', hide,
                                   'matches_epoch', (select value #>> '{}' from settings where key = 'matches_epoch')),
    'tournaments', coalesce((select jsonb_agg(t order by t.created_at) from tournaments t), '[]'::jsonb),
    'categories',  coalesce((select jsonb_agg(c order by c.created_at) from categories c), '[]'::jsonb),
    'teams',       coalesce((select jsonb_agg(x order by x.code) from teams x
                             where adm or not hide or not x.official), '[]'::jsonb),
    'live',        coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'team_a', m.team_a, 'team_b', m.team_b,
                                                                'umpire', m.umpire, 'label', m.label, 'device_id', m.device_id))
                             from matches m
                             where m.status = 'live' and m.updated_at > now() - interval '30 minutes'), '[]'::jsonb)
  );
end $$;

-- Umpires may add teams and change their own; tournaments, categories and official teams are admin only.
create or replace function pb_save(p_pass text, p_kind text, p_row jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := coalesce(nullif(p_row->>'id','')::uuid, gen_random_uuid());
  adm boolean := pb_is_admin(p_pass);
  was_official boolean;
begin
  perform pb_auth(p_pass);
  if p_kind = 'tournament' then
    perform pb_admin(p_pass);
    insert into tournaments(id, name, created_by) values (v_id, p_row->>'name', p_row->>'created_by')
    on conflict (id) do update set name = excluded.name;
  elsif p_kind = 'category' then
    perform pb_admin(p_pass);
    insert into categories(id, tournament_id, name, code)
    values (v_id, (p_row->>'tournament_id')::uuid, p_row->>'name', p_row->>'code')
    on conflict (id) do update set name = excluded.name, code = excluded.code;
  elsif p_kind = 'team' then
    select official into was_official from teams where id = v_id;
    if was_official and not adm then
      raise exception 'official team' using errcode = '42501';
    end if;
    insert into teams(id, category_id, code, player1, player2, official)
    values (v_id, (p_row->>'category_id')::uuid, p_row->>'code', p_row->>'player1', p_row->>'player2', adm)
    on conflict (id) do update set category_id = excluded.category_id, code = excluded.code,
                                   player1 = excluded.player1, player2 = excluded.player2;
  else
    raise exception 'unknown kind %', p_kind;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function pb_delete(p_pass text, p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pb_auth(p_pass);
  if p_kind = 'tournament' then perform pb_admin(p_pass); delete from tournaments where id = p_id;
  elsif p_kind = 'category' then perform pb_admin(p_pass); delete from categories where id = p_id;
  elsif p_kind = 'team' then
    if not pb_is_admin(p_pass) and exists(select 1 from teams where id = p_id and official) then
      raise exception 'official team' using errcode = '42501';
    end if;
    delete from teams where id = p_id;
  else raise exception 'unknown kind %', p_kind;
  end if;
end $$;

-- ---------- admin tools ----------
create or replace function pb_admin_setting(p_pass text, p_key text, p_value jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pb_admin(p_pass);
  insert into settings(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
end $$;

create or replace function pb_admin_stats(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform pb_admin(p_pass);
  return jsonb_build_object(
    'official_teams', (select count(*) from teams where official),
    'tester_teams', (select count(*) from teams where not official),
    'matches', (select count(*) from matches),
    'live', (select count(*) from matches where status = 'live' and updated_at > now() - interval '30 minutes'),
    'log_entries', (select count(*) from match_events),
    'umpires', (select count(*) from umpires));
end $$;

-- p_what: matches (all matches and their logs) | tester_teams (teams umpires added) | umpires (sign-in list)
create or replace function pb_admin_clear(p_pass text, p_what text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform pb_admin(p_pass);
  if p_what = 'matches' then
    delete from matches where true;   -- Supabase requires a WHERE on deletes
    get diagnostics n = row_count;
    -- Phones see the new epoch and drop their own saved copies of older matches.
    insert into settings(key, value) values ('matches_epoch', to_jsonb(now()::text))
    on conflict (key) do update set value = excluded.value;
    return n;
  elsif p_what = 'tester_teams' then delete from teams where not official;
  elsif p_what = 'umpires' then delete from umpires where true;
  else raise exception 'unknown %', p_what;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function pb_is_admin(text), pb_admin(text), pb_hide_official() from public, anon, authenticated;
grant execute on function pb_login(text, text), pb_admin_setting(text, text, jsonb), pb_admin_stats(text),
  pb_admin_clear(text, text) to anon, authenticated;
