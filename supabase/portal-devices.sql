-- Device tags for the client portal. Run in the gridaudit project after portal-v4.sql.
-- Safe to run again. Run this BEFORE pushing the login page that sends p_device.
--
-- The login page gives each browser a random ID the first time it signs in
-- (kept in that browser's localStorage) and sends it with every sign-in. It is
-- stored on the sign-in event, so /admin can count how many different devices
-- have used each code. It identifies a browser, not a person: one person on a
-- phone and a laptop counts as two, and clearing the browser makes a new one.

alter table portal_events add column if not exists device_id text;
alter table portal_events drop constraint if exists portal_events_device_id_check;
alter table portal_events add constraint portal_events_device_id_check
  check (device_id ~ '^[A-Za-z0-9-]{8,64}$');
create index if not exists portal_events_code_device on portal_events (code_id, device_id) where kind = 'login_ok';

drop function if exists portal_login(text);
create or replace function portal_login(p_code text, p_device text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_norm text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_device text := case when p_device ~ '^[A-Za-z0-9-]{8,64}$' then p_device end;
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
    insert into portal_events (kind, detail, ip, user_agent, device_id) values ('login_blocked', 'Too many wrong codes', v_ip, v_ua, v_device);
    return json_build_object('ok', false, 'error', 'too_many');
  end if;

  select c.* into v_code
  from portal_codes c join portal_clients cl on cl.id = c.client_id
  where c.code_norm = v_norm and c.active and not cl.archived
    and (c.expires_at is null or c.expires_at > now());

  if not found then
    insert into portal_events (kind, detail, ip, user_agent, admin, device_id)
    values ('login_fail', 'Wrong code (' || char_length(v_norm) || ' characters)', v_ip, v_ua, v_admin, v_device);
    return json_build_object('ok', false, 'error', 'no_match');
  end if;

  select * into v_client from portal_clients where id = v_code.client_id;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into portal_sessions (token, expires_at, client_id, code_id, admin)
  values (v_token, now() + interval '12 hours', v_code.client_id, v_code.id, v_admin);
  if not v_admin then
    update portal_codes set last_used_at = now(), use_count = use_count + 1 where id = v_code.id;
  end if;
  insert into portal_events (kind, client_id, code_id, detail, ip, user_agent, admin, device_id)
  values ('login_ok', v_code.client_id, v_code.id, coalesce(v_code.label, v_code.code), v_ip, v_ua, v_admin, v_device);
  delete from portal_sessions where expires_at < now() - interval '1 day';

  return json_build_object('ok', true, 'token', v_token, 'client', v_client.name);
end;
$$;

revoke all on function portal_login(text, text) from public;
grant execute on function portal_login(text, text) to anon, authenticated;
