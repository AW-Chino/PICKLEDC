-- Court numbers (1-4). Run after 006_player_check.sql.
alter table matches add column if not exists court int;

-- Start checks, in order: busy team (blocks), busy court (warns), busy player (warns).
-- The app re-sends with allow_busy_court / allow_busy_players when the umpire chooses "Start anyway".
create or replace function pb_start_match(p_pass text, p_match jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v record;
  busy text;
  ta uuid := nullif(p_match->>'team_a','')::uuid;
  tb uuid := nullif(p_match->>'team_b','')::uuid;
  ct int := nullif(p_match->>'court','')::int;
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

  if ct is not null and not coalesce((p_match->>'allow_busy_court')::boolean, false) then
    select m.label, m.umpire into v
    from matches m
    where m.status = 'live' and m.id <> p_match->>'id' and m.updated_at > now() - interval '30 minutes' and m.court = ct
    limit 1;
    if found then
      return jsonb_build_object('ok', false, 'reason', 'court', 'court', ct, 'label', v.label, 'umpire', v.umpire);
    end if;
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
                      target, time_limit_min, started_at, device_id, state, court, updated_at)
  values (p_match->>'id', nullif(p_match->>'tournament_id','')::uuid, nullif(p_match->>'category_id','')::uuid,
          ta, tb, coalesce(p_match->>'mode','tournament'), p_match->>'label', p_match->'players', p_match->>'umpire',
          'live', (p_match->>'target')::int, (p_match->>'time_limit_min')::int, (p_match->>'started_at')::timestamptz,
          p_match->>'device_id', p_match->'state', ct, now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- Same as 002, plus the court.
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
                      device_id, state, court, updated_at)
  values (p_match->>'id',
          nullif(p_match->>'tournament_id','')::uuid, nullif(p_match->>'category_id','')::uuid,
          nullif(p_match->>'team_a','')::uuid, nullif(p_match->>'team_b','')::uuid,
          coalesce(p_match->>'mode','tournament'), p_match->>'label', p_match->'players', p_match->>'umpire',
          coalesce(p_match->>'status','live'),
          coalesce((p_match->>'score_a')::int,0), coalesce((p_match->>'score_b')::int,0), p_match->>'winner',
          (p_match->>'target')::int, (p_match->>'time_limit_min')::int, (p_match->>'duration_ms')::int,
          (p_match->>'started_at')::timestamptz, (p_match->>'ended_at')::timestamptz,
          p_match->>'device_id', p_match->'state', nullif(p_match->>'court','')::int, now())
  on conflict (id) do update set
    label = excluded.label, players = excluded.players, umpire = excluded.umpire, status = excluded.status,
    score_a = excluded.score_a, score_b = excluded.score_b, winner = excluded.winner,
    duration_ms = excluded.duration_ms, ended_at = excluded.ended_at,
    device_id = coalesce(excluded.device_id, matches.device_id),
    state = coalesce(excluded.state, matches.state),
    court = coalesce(excluded.court, matches.court), updated_at = now();

  insert into match_events(id, match_id, seq, at, game_ms, umpire, kind, detail, score)
  select e->>'id', p_match->>'id', (e->>'seq')::int, (e->>'at')::timestamptz, coalesce((e->>'game_ms')::int,0),
         e->>'umpire', e->>'kind', e->>'detail', e->>'score'
  from jsonb_array_elements(coalesce(p_events,'[]'::jsonb)) e
  on conflict (id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Same as 005, plus the court of each live match.
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
                                                                'umpire', m.umpire, 'label', m.label, 'device_id', m.device_id,
                                                                'court', m.court))
                             from matches m
                             where m.status = 'live' and m.updated_at > now() - interval '30 minutes'), '[]'::jsonb)
  );
end $$;

-- Same as 003, plus the court.
create or replace function pb_live(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform pb_auth(p_pass);
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'label', m.label, 'umpire', m.umpire,
                                                       'status', m.status, 'updated_at', m.updated_at,
                                                       'started_at', m.started_at, 'court', m.court, 'state', m.state)
                                    order by m.started_at)
                   from matches m
                   where m.state is not null and (
                     (m.status = 'live' and m.updated_at > now() - interval '30 minutes')
                     or (m.status in ('final', 'ended_early') and m.ended_at > now() - interval '3 minutes'))),
                  '[]'::jsonb);
end $$;
