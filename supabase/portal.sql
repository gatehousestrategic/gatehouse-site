-- Gatehouse client portal: run in the gridaudit Supabase project.
-- Dashboard > SQL Editor > New query > paste > Run. Safe to run again.
--
-- What the public key (the one inside the web pages) can do here:
--   * try an access code (portal_login), limited to 10 wrong codes per
--     15 minutes from one network
--   * with the session it gets back, read that one client's items and
--     record that an item was opened
-- Nothing else. It cannot read clients, codes, items or the activity log.
--
-- Admins sign in on /admin with a Supabase account whose email is listed in
-- portal_admins. They can do everything in the dashboard.
--
-- After the first run, add yourself as an admin (use your own email):
--   insert into portal_admins (email) values ('you@example.com') on conflict do nothing;
-- and create that user under Authentication > Users > Add user (with a password).

create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------

create table if not exists portal_admins (
  email text primary key
);

create table if not exists portal_clients (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text not null check (char_length(name) between 1 and 120),
  note text check (char_length(note) <= 1000),
  archived boolean not null default false
);

create table if not exists portal_codes (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  client_id uuid not null references portal_clients(id) on delete cascade,
  code text not null check (char_length(code) between 6 and 40),
  code_norm text generated always as (upper(regexp_replace(code, '[^A-Za-z0-9]', '', 'g'))) stored,
  label text check (char_length(label) <= 120),
  active boolean not null default true,
  expires_at timestamptz,
  last_used_at timestamptz,
  use_count int not null default 0
);
create unique index if not exists portal_codes_norm on portal_codes (code_norm);
create index if not exists portal_codes_client on portal_codes (client_id);

create table if not exists portal_items (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  client_id uuid not null references portal_clients(id) on delete cascade,
  kind text not null check (kind in ('link', 'file', 'note')),
  title text not null check (char_length(title) between 1 and 200),
  url text check (char_length(url) <= 2000),
  file_path text check (char_length(file_path) <= 500),
  file_name text check (char_length(file_name) <= 300),
  body text check (char_length(body) <= 10000),
  position int not null default 0
);
create index if not exists portal_items_client on portal_items (client_id, position);

create table if not exists portal_sessions (
  token text primary key,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  client_id uuid not null references portal_clients(id) on delete cascade,
  code_id uuid references portal_codes(id) on delete set null
);

create table if not exists portal_events (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind text not null,
  client_id uuid references portal_clients(id) on delete set null,
  code_id uuid references portal_codes(id) on delete set null,
  item_id uuid references portal_items(id) on delete set null,
  detail text,
  ip text,
  user_agent text
);
create index if not exists portal_events_time on portal_events (created_at desc);
create index if not exists portal_events_client on portal_events (client_id, created_at desc);
create index if not exists portal_events_ip on portal_events (ip, kind, created_at desc);

-- ---------- access rules ----------

create or replace function portal_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from portal_admins
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

alter table portal_admins enable row level security;
alter table portal_clients enable row level security;
alter table portal_codes enable row level security;
alter table portal_items enable row level security;
alter table portal_sessions enable row level security;
alter table portal_events enable row level security;

drop policy if exists portal_admins_self on portal_admins;
create policy portal_admins_self on portal_admins for select to authenticated
  using (portal_is_admin());

drop policy if exists portal_clients_admin on portal_clients;
create policy portal_clients_admin on portal_clients for all to authenticated
  using (portal_is_admin()) with check (portal_is_admin());

drop policy if exists portal_codes_admin on portal_codes;
create policy portal_codes_admin on portal_codes for all to authenticated
  using (portal_is_admin()) with check (portal_is_admin());

drop policy if exists portal_items_admin on portal_items;
create policy portal_items_admin on portal_items for all to authenticated
  using (portal_is_admin()) with check (portal_is_admin());

drop policy if exists portal_sessions_admin on portal_sessions;
create policy portal_sessions_admin on portal_sessions for select to authenticated
  using (portal_is_admin());

drop policy if exists portal_events_admin on portal_events;
create policy portal_events_admin on portal_events for select to authenticated
  using (portal_is_admin());

-- ---------- request details for the activity log ----------

create or replace function portal_req(field text) returns text
language sql stable as $$
  select case field
    when 'ip' then nullif(trim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)), '')
    when 'ua' then left(current_setting('request.headers', true)::json ->> 'user-agent', 300)
  end;
$$;

-- ---------- what the public key may call ----------

create or replace function portal_login(p_code text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_norm text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_ip text := portal_req('ip');
  v_ua text := portal_req('ua');
  v_code portal_codes%rowtype;
  v_client portal_clients%rowtype;
  v_token text;
begin
  if v_ip is not null and (
    select count(*) from portal_events
    where kind = 'login_fail' and ip = v_ip and created_at > now() - interval '15 minutes'
  ) >= 10 then
    insert into portal_events (kind, detail, ip, user_agent) values ('login_blocked', 'Too many wrong codes', v_ip, v_ua);
    return json_build_object('ok', false, 'error', 'too_many');
  end if;

  select c.* into v_code
  from portal_codes c join portal_clients cl on cl.id = c.client_id
  where c.code_norm = v_norm and c.active and not cl.archived
    and (c.expires_at is null or c.expires_at > now());

  if not found then
    insert into portal_events (kind, detail, ip, user_agent)
    values ('login_fail', 'Wrong code (' || char_length(v_norm) || ' characters)', v_ip, v_ua);
    return json_build_object('ok', false, 'error', 'no_match');
  end if;

  select * into v_client from portal_clients where id = v_code.client_id;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into portal_sessions (token, expires_at, client_id, code_id)
  values (v_token, now() + interval '12 hours', v_code.client_id, v_code.id);
  update portal_codes set last_used_at = now(), use_count = use_count + 1 where id = v_code.id;
  insert into portal_events (kind, client_id, code_id, detail, ip, user_agent)
  values ('login_ok', v_code.client_id, v_code.id, coalesce(v_code.label, v_code.code), v_ip, v_ua);
  delete from portal_sessions where expires_at < now() - interval '1 day';

  return json_build_object('ok', true, 'token', v_token, 'client', v_client.name);
end;
$$;

create or replace function portal_open(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare
  s portal_sessions%rowtype;
  v_name text;
begin
  select * into s from portal_sessions where token = p_token and expires_at > now();
  if not found then
    return json_build_object('ok', false, 'error', 'expired');
  end if;
  select name into v_name from portal_clients where id = s.client_id and not archived;
  if v_name is null then
    return json_build_object('ok', false, 'error', 'expired');
  end if;
  insert into portal_events (kind, client_id, code_id, ip, user_agent)
  values ('portal_view', s.client_id, s.code_id, portal_req('ip'), portal_req('ua'));
  return json_build_object(
    'ok', true,
    'client', v_name,
    'items', coalesce((
      select json_agg(json_build_object(
        'id', i.id, 'kind', i.kind, 'title', i.title, 'url', i.url,
        'file_path', i.file_path, 'file_name', i.file_name, 'body', i.body, 'created_at', i.created_at
      ) order by i.position, i.created_at)
      from portal_items i where i.client_id = s.client_id
    ), '[]'::json)
  );
end;
$$;

create or replace function portal_track(p_token text, p_item uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  s portal_sessions%rowtype;
  v_title text;
begin
  select * into s from portal_sessions where token = p_token and expires_at > now();
  if not found then return; end if;
  select title into v_title from portal_items where id = p_item and client_id = s.client_id;
  if v_title is null then return; end if;
  insert into portal_events (kind, client_id, code_id, item_id, detail, ip, user_agent)
  values ('item_open', s.client_id, s.code_id, p_item, v_title, portal_req('ip'), portal_req('ua'));
end;
$$;

create or replace function portal_logout(p_token text) returns void
language plpgsql security definer set search_path = public as $$
declare
  s portal_sessions%rowtype;
begin
  delete from portal_sessions where token = p_token returning * into s;
  if found then
    insert into portal_events (kind, client_id, code_id, ip, user_agent)
    values ('logout', s.client_id, s.code_id, portal_req('ip'), portal_req('ua'));
  end if;
end;
$$;

revoke all on function portal_login(text) from public;
revoke all on function portal_open(text) from public;
revoke all on function portal_track(text, uuid) from public;
revoke all on function portal_logout(text) from public;
grant execute on function portal_login(text) to anon, authenticated;
grant execute on function portal_open(text) to anon, authenticated;
grant execute on function portal_track(text, uuid) to anon, authenticated;
grant execute on function portal_logout(text) to anon, authenticated;
grant execute on function portal_is_admin() to authenticated;

-- ---------- files ----------
-- Files sit in a bucket with random folder names. A file's address is only
-- given out after a valid code; only admins can upload or delete.

insert into storage.buckets (id, name, public)
values ('portal-files', 'portal-files', true)
on conflict (id) do nothing;

drop policy if exists portal_files_admin_insert on storage.objects;
create policy portal_files_admin_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'portal-files' and portal_is_admin());

drop policy if exists portal_files_admin_update on storage.objects;
create policy portal_files_admin_update on storage.objects for update to authenticated
  using (bucket_id = 'portal-files' and portal_is_admin());

drop policy if exists portal_files_admin_delete on storage.objects;
create policy portal_files_admin_delete on storage.objects for delete to authenticated
  using (bucket_id = 'portal-files' and portal_is_admin());

drop policy if exists portal_files_admin_select on storage.objects;
create policy portal_files_admin_select on storage.objects for select to authenticated
  using (bucket_id = 'portal-files' and portal_is_admin());
