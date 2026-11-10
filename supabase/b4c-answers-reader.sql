-- Run once in the gridaudit Supabase project:
-- Dashboard > SQL Editor > New query > paste > Run.
-- Lets gatehousestrategic.com/b4c/answers show the Bike4Chai answers
-- to whoever types the right passcode. The passcode itself is set
-- separately (see the last statement) so it never lives in this repo.

create extension if not exists pgcrypto with schema extensions;

create table if not exists b4c_settings (
  key text primary key,
  value text not null
);
alter table b4c_settings enable row level security;
-- No policies: the public key cannot read or change settings.

create or replace function public.b4c_scope_answers_list(passcode text)
returns setof b4c_scope_answers
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  h text;
begin
  select value into h from b4c_settings where key = 'answers_passcode_hash';
  if h is null or passcode is null or crypt(passcode, h) <> h then
    raise exception 'wrong passcode' using errcode = '28P01';
  end if;
  return query select * from b4c_scope_answers order by created_at desc;
end;
$$;

revoke all on function public.b4c_scope_answers_list(text) from public;
grant execute on function public.b4c_scope_answers_list(text) to anon;

-- Set or change the passcode: replace YOUR-PASSCODE and run this line.
-- insert into b4c_settings (key, value)
--   values ('answers_passcode_hash', extensions.crypt('YOUR-PASSCODE', extensions.gen_salt('bf')))
--   on conflict (key) do update set value = excluded.value;
