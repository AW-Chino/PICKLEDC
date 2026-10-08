-- Warn when a player is already on court in another live match. Run after 005_admin.sql.
-- A busy team still blocks the start. A busy player only warns: the app asks the umpire and,
-- if they choose "Start anyway", sends p_match.allow_busy_players = true.
create or replace function pb_start_match(p_pass text, p_match jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v record;
  busy text;
  ta uuid := nullif(p_match->>'team_a','')::uuid;
  tb uuid := nullif(p_match->>'team_b','')::uuid;
  mine text[] := array(
    select lower(trim(w)) from jsonb_array_elements_text(jsonb_build_array(
      p_match->'players'->'A'->>'p1', p_match->'players'->'A'->>'p2',
      p_match->'players'->'B'->>'p1', p_match->'players'->'B'->>'p2')) w
    where w is not null and trim(w) <> '');
begin
  perform pb_auth(p_pass);
  lock table matches in share row exclusive mode;   -- two umpires starting at once can't both win

  select m.id, m.label, m.umpire, m.team_a, m.team_b into v
  from matches m
  where m.status = 'live' and m.id <> p_match->>'id' and m.updated_at > now() - interval '30 minutes'
    and (m.team_a in (ta, tb) or m.team_b in (ta, tb))
  limit 1;
  if found then
    return jsonb_build_object('ok', false, 'reason', 'team', 'label', v.label, 'umpire', v.umpire,
                              'team_a', v.team_a, 'team_b', v.team_b);
  end if;

  if not coalesce((p_match->>'allow_busy_players')::boolean, false) then
    for v in select m.label, m.umpire, m.players from matches m
             where m.status = 'live' and m.id <> p_match->>'id' and m.updated_at > now() - interval '30 minutes'
    loop
      select string_agg(distinct x, ', ') into busy
      from jsonb_array_elements_text(jsonb_build_array(
        v.players->'A'->>'p1', v.players->'A'->>'p2', v.players->'B'->>'p1', v.players->'B'->>'p2')) x
      where x is not null and lower(trim(x)) = any(mine);
      if busy is not null then
        return jsonb_build_object('ok', false, 'reason', 'player', 'players', busy, 'label', v.label, 'umpire', v.umpire);
      end if;
    end loop;
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
