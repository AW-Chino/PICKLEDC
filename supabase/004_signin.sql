-- Case-insensitive umpire sign-in. Run after 003_board.sql.
-- "juan cruz", "Juan Cruz" and "JUAN  CRUZ" are the same umpire; the first spelling used is kept.
create or replace function pb_signin(p_pass text, p_umpire text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v text;
  n text := regexp_replace(trim(coalesce(p_umpire, '')), '\s+', ' ', 'g');
begin
  perform pb_auth(p_pass);
  if n = '' then return ''; end if;
  select name into v from umpires where lower(name) = lower(n) limit 1;
  if v is null then
    insert into umpires(name) values (n) returning name into v;
  else
    update umpires set last_seen = now() where name = v;
  end if;
  return v;
end $$;

grant execute on function pb_signin(text, text) to anon, authenticated;
