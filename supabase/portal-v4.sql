-- Gatehouse client portal, part 4: keep Gatehouse's own logins out of the activity.
-- Run after portal.sql, portal-v2.sql and portal-v3.sql, in the gridaudit project. Safe to run again.
--
-- A login counts as Gatehouse's own (not the client's) when either:
--   * the browser is also signed in to /admin (the login carries the admin sign-in), or
--   * it comes from a network address an admin used /admin from in the last 30 days.
-- Such a session is marked admin. Everything it does is logged with admin = true,
-- it doesn't count as the code's last use, and /admin doesn't show it.

alter table portal_sessions add column if not exists admin boolean not null default false;
alter table portal_events add column if not exists admin boolean not null default false;

create table if not exists portal_admin_ips (
  ip text primary key,
  last_seen timestamptz not null default now()
);
alter table portal_admin_ips enable row level security;
drop policy if exists portal_admin_ips_admin on portal_admin_ips;
create policy portal_admin_ips_admin on portal_admin_ips for select to authenticated
  using (portal_is_admin());

-- /admin calls this after sign-in so its network address is recognised.
create or replace function portal_admin_seen() returns void
language plpgsql security definer set search_path = public as $$
declare v_ip text := portal_req('ip');
begin
  if not portal_is_admin() or v_ip is null then return; end if;
  insert into portal_admin_ips (ip, last_seen) values (v_ip, now())
  on conflict (ip) do update set last_seen = now();
end;
$$;

-- /admin shows only what clients did.
drop policy if exists portal_events_admin on portal_events;
create policy portal_events_admin on portal_events for select to authenticated
  using (portal_is_admin() and not admin);

create or replace function portal_login(p_code text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_norm text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_ip text := portal_req('ip');
  v_ua text := portal_req('ua');
  v_admin boolean := portal_is_admin()
    or (v_ip is not null and exists (select 1 from portal_admin_ips where ip = v_ip and last_seen > now() - interval '30 days'));
  v_code portal_codes%rowtype;
  v_client portal_clients%rowtype;
  v_token text;
begin
  if not v_admin and v_ip is not null and (
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
    insert into portal_events (kind, detail, ip, user_agent, admin)
    values ('login_fail', 'Wrong code (' || char_length(v_norm) || ' characters)', v_ip, v_ua, v_admin);
    return json_build_object('ok', false, 'error', 'no_match');
  end if;

  select * into v_client from portal_clients where id = v_code.client_id;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into portal_sessions (token, expires_at, client_id, code_id, admin)
  values (v_token, now() + interval '12 hours', v_code.client_id, v_code.id, v_admin);
  if not v_admin then
    update portal_codes set last_used_at = now(), use_count = use_count + 1 where id = v_code.id;
  end if;
  insert into portal_events (kind, client_id, code_id, detail, ip, user_agent, admin)
  values ('login_ok', v_code.client_id, v_code.id, coalesce(v_code.label, v_code.code), v_ip, v_ua, v_admin);
  delete from portal_sessions where expires_at < now() - interval '1 day';

  return json_build_object('ok', true, 'token', v_token, 'client', v_client.name);
end;
$$;

-- Everything a session does afterwards carries its admin mark.
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
  insert into portal_events (kind, client_id, code_id, ip, user_agent, admin)
  values ('portal_view', s.client_id, s.code_id, portal_req('ip'), portal_req('ua'), s.admin);
  if not s.admin then
    update portal_messages set read_at = now() where client_id = s.client_id and from_admin and read_at is null;
  end if;
  return json_build_object(
    'ok', true,
    'client', v_name,
    'upload_key', s.upload_key,
    'preview', s.admin,
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
  insert into portal_events (kind, client_id, code_id, item_id, detail, ip, user_agent, admin)
  values ('item_open', s.client_id, s.code_id, p_item, v_title, portal_req('ip'), portal_req('ua'), s.admin);
end;
$$;

create or replace function portal_logout(p_token text) returns void
language plpgsql security definer set search_path = public as $$
declare
  s portal_sessions%rowtype;
begin
  delete from portal_sessions where token = p_token returning * into s;
  if found then
    insert into portal_events (kind, client_id, code_id, ip, user_agent, admin)
    values ('logout', s.client_id, s.code_id, portal_req('ip'), portal_req('ua'), s.admin);
  end if;
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
  if s.admin then return json_build_object('ok', false, 'error', 'preview'); end if;
  if char_length(v_body) = 0 or char_length(v_body) > 5000 then
    return json_build_object('ok', false, 'error', 'length');
  end if;
  if (select count(*) from portal_messages where client_id = s.client_id and not from_admin and created_at > now() - interval '1 hour') >= 30 then
    return json_build_object('ok', false, 'error', 'too_many');
  end if;
  insert into portal_messages (client_id, from_admin, author, body)
  values (s.client_id, false, nullif(left(trim(coalesce(p_author, '')), 120), ''), v_body);
  insert into portal_events (kind, client_id, code_id, detail, ip, user_agent, admin)
  values ('message_sent', s.client_id, s.code_id, left(v_body, 120), portal_req('ip'), portal_req('ua'), s.admin);
  return json_build_object('ok', true);
end;
$$;

create or replace function portal_register_upload(p_token text, p_path text, p_name text, p_size bigint) returns json
language plpgsql security definer set search_path = public as $$
declare
  s portal_sessions%rowtype;
  v_pos int;
begin
  select * into s from portal_sessions where token = p_token and expires_at > now();
  if not found then return json_build_object('ok', false, 'error', 'expired'); end if;
  if s.admin then return json_build_object('ok', false, 'error', 'preview'); end if;
  if p_path is null or p_path not like 'in/' || s.upload_key || '/%' or char_length(p_path) > 500 then
    return json_build_object('ok', false, 'error', 'path');
  end if;
  select coalesce(max(position), -1) + 1 into v_pos from portal_items where client_id = s.client_id;
  insert into portal_items (client_id, kind, title, file_path, file_name, file_size, uploaded_by, position)
  values (s.client_id, 'file', left(coalesce(nullif(trim(p_name), ''), 'Upload'), 200), p_path, left(p_name, 300), p_size, 'client', v_pos);
  insert into portal_events (kind, client_id, code_id, detail, ip, user_agent, admin)
  values ('file_uploaded', s.client_id, s.code_id, left(p_name, 120), portal_req('ip'), portal_req('ua'), s.admin);
  return json_build_object('ok', true);
end;
$$;

-- "View as client" from /admin: a 2-hour admin session for one client's
-- dashboard, without a code. Nothing it does shows in the activity.
create or replace function portal_admin_session(p_client uuid) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_token text;
begin
  if not portal_is_admin() then return json_build_object('ok', false, 'error', 'not_admin'); end if;
  if not exists (select 1 from portal_clients where id = p_client) then
    return json_build_object('ok', false, 'error', 'not_found');
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into portal_sessions (token, expires_at, client_id, admin)
  values (v_token, now() + interval '2 hours', p_client, true);
  return json_build_object('ok', true, 'token', v_token);
end;
$$;

revoke all on function portal_admin_seen() from public;
revoke all on function portal_admin_session(uuid) from public;
grant execute on function portal_admin_seen() to authenticated;
grant execute on function portal_admin_session(uuid) to authenticated;
