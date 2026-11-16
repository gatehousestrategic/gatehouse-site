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
--
-- Emails are HTML (navy header with the logo at /img/email-logo.png, white card,
-- one button) with a plain-text copy. portal_email_html() builds the layout and
-- is also used by portal-client-emails.sql.

create extension if not exists pg_net;

create or replace function portal_html_esc(p text) returns text
language sql immutable set search_path = public as $fn$
  select replace(replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$fn$;

-- p_eyebrow, p_heading, p_button and p_footer are plain text (escaped here);
-- p_body is HTML the caller has already escaped.
create or replace function portal_email_html(p_eyebrow text, p_heading text, p_body text,
  p_button text, p_url text, p_footer text)
returns text language sql immutable set search_path = public as $fn$
  select
'<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>' || portal_html_esc(p_heading) || '</title></head>'
|| '<body style="margin:0;padding:0;background:#eef3f8;">'
|| '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef3f8;"><tr><td align="center" style="padding:32px 16px;">'
|| '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;">'
|| '<tr><td style="background:#0d2a4c;padding:22px 32px;border-radius:6px 6px 0 0;"><img src="https://gatehousestrategic.com/img/email-logo.png" width="200" height="56" alt="Gatehouse Strategic" style="display:block;border:0;color:#ffffff;font-family:Georgia,serif;font-size:22px;"></td></tr>'
|| '<tr><td style="background:#ffffff;padding:36px 32px 32px;border-radius:0 0 6px 6px;font-family:Arial,Helvetica,sans-serif;color:#33475b;font-size:16px;line-height:1.6;">'
|| case when coalesce(p_eyebrow, '') <> '' then '<p style="margin:0 0 6px;font-size:12px;font-weight:bold;letter-spacing:.12em;text-transform:uppercase;color:#3d8bd6;">' || portal_html_esc(p_eyebrow) || '</p>' else '' end
|| '<h1 style="margin:0 0 16px;font-family:Georgia,''Times New Roman'',serif;font-weight:normal;font-size:26px;line-height:1.25;color:#0d2a4c;">' || portal_html_esc(p_heading) || '</h1>'
|| p_body
|| '<table role="presentation" cellpadding="0" cellspacing="0" style="margin-top:26px;"><tr><td style="background:#0d2a4c;border-radius:4px;"><a href="' || portal_html_esc(p_url) || '" style="display:inline-block;padding:13px 26px;font-family:Arial,Helvetica,sans-serif;font-size:15px;font-weight:bold;color:#ffffff;text-decoration:none;">' || portal_html_esc(p_button) || '</a></td></tr></table>'
|| '</td></tr>'
|| '<tr><td style="padding:20px 32px;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:1.6;color:#6c7f95;text-align:center;">' || p_footer || '</td></tr>'
|| '</table></td></tr></table></body></html>';
$fn$;

drop function if exists portal_send_alert(text, text);
create or replace function portal_send_alert(p_subject text, p_text text, p_html text default null)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if v_key is null or v_key = '' then return; end if;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
    body := jsonb_strip_nulls(jsonb_build_object(
      'from', 'Gatehouse portal <portal@gatehousestrategic.com>',
      'to', jsonb_build_array('os@gatehousestrategic.com'),
      'subject', left(p_subject, 200),
      'text', p_text,
      'html', p_html
    ))
  );
exception when others then
  -- Never let an email problem stop the client's message or upload.
  raise warning 'portal_send_alert failed: %', sqlerrm;
end;
$fn$;

create or replace function portal_alert_message() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare
  v_client text := coalesce((select name from portal_clients where id = new.client_id), 'a client');
  v_author text := nullif(trim(new.author), '');
  v_body text := left(new.body, 2000) || case when char_length(new.body) > 2000 then E'\n[...]' else '' end;
begin
  if new.from_admin then return new; end if;
  perform portal_send_alert(
    'New message from ' || v_client,
    v_client || coalesce(' (' || v_author || ')', '') || ' wrote:' || E'\n\n' || v_body ||
      E'\n\nReply in the admin: https://gatehousestrategic.com/admin/',
    portal_email_html('Client portal', 'New message from ' || v_client,
      '<p style="margin:0 0 8px;font-size:14px;color:#6c7f95;">' || portal_html_esc(coalesce(v_author, v_client)) || ' wrote:</p>'
      || '<div style="padding:16px 18px;background:#f6f8fb;border-left:3px solid #3d8bd6;white-space:pre-wrap;">' || portal_html_esc(v_body) || '</div>',
      'Reply in the admin', 'https://gatehousestrategic.com/admin/', 'Portal alert for Gatehouse Strategic')
  );
  return new;
end;
$fn$;

create or replace function portal_alert_upload() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare
  v_client text := coalesce((select name from portal_clients where id = new.client_id), 'A client');
  v_file text := coalesce(new.file_name, new.title);
begin
  if new.uploaded_by <> 'client' then return new; end if;
  perform portal_send_alert(
    v_client || ' uploaded ' || v_file,
    v_client || ' uploaded a file in the portal: ' || v_file ||
      E'\n\nSee it in the admin: https://gatehousestrategic.com/admin/',
    portal_email_html('Client portal', v_client || ' uploaded a file',
      '<div style="padding:16px 18px;background:#f6f8fb;border-left:3px solid #3d8bd6;word-break:break-word;">' || portal_html_esc(v_file) || '</div>',
      'See it in the admin', 'https://gatehousestrategic.com/admin/', 'Portal alert for Gatehouse Strategic')
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

revoke all on function portal_send_alert(text, text, text) from public, anon, authenticated;
revoke all on function portal_alert_message() from public, anon, authenticated;
revoke all on function portal_alert_upload() from public, anon, authenticated;
revoke all on function portal_email_html(text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function portal_html_esc(text) from public, anon, authenticated;
