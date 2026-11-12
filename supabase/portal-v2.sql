-- Gatehouse client portal, part 2: messages and client uploads.
-- Run after portal.sql, in the gridaudit project. Safe to run again.
--
-- Adds, for a client signed in with a valid code:
--   * sending a message to Gatehouse (portal_send), up to 30 an hour
--   * uploading files into their own area (up to 50 MB each)
-- Admins reply to messages and see client uploads in /admin.

create extension if not exists pgcrypto with schema extensions;

-- Items now record who added them.
alter table portal_items add column if not exists uploaded_by text not null default 'admin';
alter table portal_items drop constraint if exists portal_items_uploaded_by_check;
alter table portal_items add constraint portal_items_uploaded_by_check check (uploaded_by in ('admin', 'client'));
alter table portal_items add column if not exists file_size bigint;

-- Each session gets a private upload folder name.
alter table portal_sessions add column if not exists upload_key text;
update portal_sessions set upload_key = encode(extensions.gen_random_bytes(12), 'hex') where upload_key is null;
alter table portal_sessions alter column upload_key set default encode(extensions.gen_random_bytes(12), 'hex');

create table if not exists portal_messages (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  client_id uuid not null references portal_clients(id) on delete cascade,
  from_admin boolean not null default false,
  author text check (char_length(author) <= 120),
  body text not null check (char_length(body) between 1 and 5000),
  read_at timestamptz
);
create index if not exists portal_messages_client on portal_messages (client_id, created_at);

alter table portal_messages enable row level security;
drop policy if exists portal_messages_admin on portal_messages;
create policy portal_messages_admin on portal_messages for all to authenticated
  using (portal_is_admin()) with check (portal_is_admin());

-- What a signed-in client sees: items, messages, and their upload folder.
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
  update portal_messages set read_at = now() where client_id = s.client_id and from_admin and read_at is null;
  return json_build_object(
    'ok', true,
    'client', v_name,
    'upload_key', s.upload_key,
    'items', coalesce((
      select json_agg(json_build_object(
        'id', i.id, 'kind', i.kind, 'title', i.title, 'url', i.url,
        'file_path', i.file_path, 'file_name', i.file_name, 'file_size', i.file_size,
        'body', i.body, 'uploaded_by', i.uploaded_by, 'created_at', i.created_at
      ) order by i.position, i.created_at)
      from portal_items i where i.client_id = s.client_id
    ), '[]'::json),
    'messages', coalesce((
      select json_agg(json_build_object(
        'id', m.id, 'from_admin', m.from_admin, 'author', m.author, 'body', m.body, 'created_at', m.created_at
      ) order by m.created_at)
      from portal_messages m where m.client_id = s.client_id
    ), '[]'::json)
  );
end;
$$;

create or replace function portal_send(p_token text, p_body text, p_author text default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  s portal_sessions%rowtype;
  v_body text := trim(coalesce(p_body, ''));
begin
  select * into s from portal_sessions where token = p_token and expires_at > now();
  if not found then return json_build_object('ok', false, 'error', 'expired'); end if;
  if char_length(v_body) = 0 or char_length(v_body) > 5000 then
    return json_build_object('ok', false, 'error', 'length');
  end if;
  if (select count(*) from portal_messages where client_id = s.client_id and not from_admin and created_at > now() - interval '1 hour') >= 30 then
    return json_build_object('ok', false, 'error', 'too_many');
  end if;
  insert into portal_messages (client_id, from_admin, author, body)
  values (s.client_id, false, nullif(left(trim(coalesce(p_author, '')), 120), ''), v_body);
  insert into portal_events (kind, client_id, code_id, detail, ip, user_agent)
  values ('message_sent', s.client_id, s.code_id, left(v_body, 120), portal_req('ip'), portal_req('ua'));
  return json_build_object('ok', true);
end;
$$;

-- Storage rule helper: is this a live session's upload folder?
create or replace function portal_upload_ok(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from portal_sessions where upload_key = p_key and expires_at > now());
$$;

create or replace function portal_register_upload(p_token text, p_path text, p_name text, p_size bigint) returns json
language plpgsql security definer set search_path = public as $$
declare
  s portal_sessions%rowtype;
  v_pos int;
begin
  select * into s from portal_sessions where token = p_token and expires_at > now();
  if not found then return json_build_object('ok', false, 'error', 'expired'); end if;
  if p_path is null or p_path not like 'in/' || s.upload_key || '/%' or char_length(p_path) > 500 then
    return json_build_object('ok', false, 'error', 'path');
  end if;
  select coalesce(max(position), -1) + 1 into v_pos from portal_items where client_id = s.client_id;
  insert into portal_items (client_id, kind, title, file_path, file_name, file_size, uploaded_by, position)
  values (s.client_id, 'file', left(coalesce(nullif(trim(p_name), ''), 'Upload'), 200), p_path, left(p_name, 300), p_size, 'client', v_pos);
  insert into portal_events (kind, client_id, code_id, detail, ip, user_agent)
  values ('file_uploaded', s.client_id, s.code_id, left(p_name, 120), portal_req('ip'), portal_req('ua'));
  return json_build_object('ok', true);
end;
$$;

revoke all on function portal_send(text, text, text) from public;
revoke all on function portal_register_upload(text, text, text, bigint) from public;
revoke all on function portal_upload_ok(text) from public;
grant execute on function portal_send(text, text, text) to anon, authenticated;
grant execute on function portal_register_upload(text, text, text, bigint) to anon, authenticated;
grant execute on function portal_upload_ok(text) to anon, authenticated;

-- Clients may upload only into in/<their session's upload folder>/.
update storage.buckets set file_size_limit = 52428800 where id = 'portal-files';
drop policy if exists portal_files_client_insert on storage.objects;
create policy portal_files_client_insert on storage.objects for insert to anon, authenticated
  with check (
    bucket_id = 'portal-files'
    and (storage.foldername(name))[1] = 'in'
    and portal_upload_ok((storage.foldername(name))[2])
  );
