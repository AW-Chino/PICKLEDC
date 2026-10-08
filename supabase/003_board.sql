-- Live scoreboard feed and moving teams between categories. Run after 002_locks_live.sql.

-- Every live match (plus ones that finished in the last 3 minutes) with its scoreboard state.
create or replace function pb_live(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform pb_auth(p_pass);
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'label', m.label, 'umpire', m.umpire,
                                                       'status', m.status, 'updated_at', m.updated_at,
                                                       'started_at', m.started_at, 'state', m.state)
                                    order by m.started_at)
                   from matches m
                   where m.state is not null and (
                     (m.status = 'live' and m.updated_at > now() - interval '30 minutes')
                     or (m.status in ('final', 'ended_early') and m.ended_at > now() - interval '3 minutes'))),
                  '[]'::jsonb);
end $$;

-- Same as before, but editing a team can also move it to another category.
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
    on conflict (id) do update set category_id = excluded.category_id, code = excluded.code,
                                   player1 = excluded.player1, player2 = excluded.player2;
  else
    raise exception 'unknown kind %', p_kind;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

grant execute on function pb_live(text) to anon, authenticated;
