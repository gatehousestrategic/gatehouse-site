-- Email alerts for the client portal. Run in the gridaudit project, after the
-- portal SQL (portal.sql to portal-v4.sql). Safe to run again.
--
-- When a client sends a message or uploads a file in the portal, the database
-- emails the owner through Resend (https://resend.com), using pg_net, which
-- sends the request after the client's insert has been saved. If the key is
-- missing or Resend fails, the message or file is still saved; only the email
-- is skipped. Failed sends show in net._http_response.
--
-- The Resend key lives in Supabase Vault as a secret named resend_api_key
-- (added by the owner in the dashboard; never in this repo). Resend must have
-- gatehousestrategic.com verified to send from portal@gatehousestrategic.com.

create extension if not exists pg_net;

create or replace function portal_send_alert(p_subject text, p_text text)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if v_key is null or v_key = '' then return; end if;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', 'Gatehouse portal <portal@gatehousestrategic.com>',
      'to', jsonb_build_array('os@gatehousestrategic.com'),
      'subject', left(p_subject, 200),
      'text', p_text
    )
  );
exception when others then
  -- Never let an email problem stop the client's message or upload.
  raise warning 'portal_send_alert failed: %', sqlerrm;
end;
$fn$;

create or replace function portal_alert_message() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare
  v_client text := (select name from portal_clients where id = new.client_id);
begin
  if new.from_admin then return new; end if;
  perform portal_send_alert(
    'New message from ' || coalesce(v_client, 'a client'),
    coalesce(v_client, 'A client') || coalesce(' (' || nullif(trim(new.author), '') || ')', '') || ' wrote:' || E'\n\n' ||
      left(new.body, 2000) || case when char_length(new.body) > 2000 then E'\n[...]' else '' end ||
      E'\n\nReply in the admin: https://gatehousestrategic.com/admin/'
  );
  return new;
end;
$fn$;

create or replace function portal_alert_upload() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare
  v_client text := (select name from portal_clients where id = new.client_id);
begin
  if new.uploaded_by <> 'client' then return new; end if;
  perform portal_send_alert(
    coalesce(v_client, 'A client') || ' uploaded ' || coalesce(new.file_name, new.title),
    coalesce(v_client, 'A client') || ' uploaded a file in the portal: ' || coalesce(new.file_name, new.title) ||
      E'\n\nSee it in the admin: https://gatehousestrategic.com/admin/'
  );
  return new;
end;
$fn$;

drop trigger if exists portal_messages_alert on portal_messages;
create trigger portal_messages_alert after insert on portal_messages
  for each row execute function portal_alert_message();

drop trigger if exists portal_items_alert on portal_items;
create trigger portal_items_alert after insert on portal_items
  for each row execute function portal_alert_upload();

revoke all on function portal_send_alert(text, text) from public, anon, authenticated;
revoke all on function portal_alert_message() from public, anon, authenticated;
revoke all on function portal_alert_upload() from public, anon, authenticated;
