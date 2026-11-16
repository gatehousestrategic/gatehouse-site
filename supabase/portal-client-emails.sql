-- Update emails to clients. Run in the gridaudit project, after portal-alerts.sql
-- (it uses the same Resend key in Vault, resend_api_key, and portal_email_html()
-- from that file for the HTML layout). Safe to run again.
--
-- Each client can have an "Email for updates" (one or more addresses, separated
-- by commas) set on their page in /admin. When the owner sends that client a
-- message or adds a file, link, note or shared page for them, the client gets a
-- short email saying there is something new, with a link to /login. The message
-- text itself is never in the email. At most one email per client every 15
-- minutes. No address, an archived client, a missing key or a Resend error
-- means no email; the message or item is still saved.

alter table portal_clients add column if not exists notify_email text;
alter table portal_clients drop constraint if exists portal_clients_notify_email_check;
alter table portal_clients add constraint portal_clients_notify_email_check
  check (char_length(notify_email) <= 500);
alter table portal_clients add column if not exists notify_last_at timestamptz;

create or replace function portal_notify_client(p_client uuid, p_what text)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_key text;
  v_to jsonb;
  v_claimed uuid;
begin
  -- Claim the 15-minute slot first, so a burst of inserts sends one email.
  update portal_clients set notify_last_at = now()
   where id = p_client and not archived
     and coalesce(trim(notify_email), '') <> ''
     and (notify_last_at is null or notify_last_at < now() - interval '15 minutes')
  returning id into v_claimed;
  if v_claimed is null then return; end if;

  select coalesce(jsonb_agg(a), '[]'::jsonb) into v_to from (
    select distinct lower(trim(x)) as a
    from portal_clients c, regexp_split_to_table(c.notify_email, '[,;\s]+') as x
    where c.id = p_client and trim(x) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    limit 20
  ) t;
  if jsonb_array_length(v_to) = 0 then return; end if;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if v_key is null or v_key = '' then return; end if;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', 'Gatehouse Strategic <portal@gatehousestrategic.com>',
      'to', v_to,
      'reply_to', 'os@gatehousestrategic.com',
      'subject', 'New from Gatehouse Strategic',
      'text', 'Hi,' || E'\n\n' ||
        'There''s something new for you in your Gatehouse client portal (' || p_what || ').' || E'\n\n' ||
        'Sign in with your access code: https://gatehousestrategic.com/login' || E'\n\n' ||
        'Gatehouse Strategic',
      'html', portal_email_html(null, 'There''s something new in your portal',
        '<p style="margin:0;">' || case when p_what = 'a message from us'
          then 'We''ve sent you a message. Sign in to read it and reply.'
          else 'We''ve added new files or notes for you. Sign in to see them.' end || '</p>'
        || '<p style="margin:22px 0 0;font-size:14px;color:#6c7f95;">Sign in with your access code. If you can''t find it, reply to this email and we''ll help.</p>',
        'Open your portal', 'https://gatehousestrategic.com/login',
        'Gatehouse Strategic &middot; <a href="https://gatehousestrategic.com" style="color:#6c7f95;">gatehousestrategic.com</a><br>You''re getting this because you have a client portal with Gatehouse Strategic.')
    )
  );
exception when others then
  -- Never let an email problem stop the owner's message or upload.
  raise warning 'portal_notify_client failed: %', sqlerrm;
end;
$fn$;

create or replace function portal_notify_message() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.from_admin then perform portal_notify_client(new.client_id, 'a message from us'); end if;
  return new;
end;
$fn$;

create or replace function portal_notify_item() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if new.uploaded_by = 'admin' then perform portal_notify_client(new.client_id, 'new files or notes'); end if;
  return new;
end;
$fn$;

drop trigger if exists portal_messages_notify on portal_messages;
create trigger portal_messages_notify after insert on portal_messages
  for each row execute function portal_notify_message();

drop trigger if exists portal_items_notify on portal_items;
create trigger portal_items_notify after insert on portal_items
  for each row execute function portal_notify_item();

revoke all on function portal_notify_client(uuid, text) from public, anon, authenticated;
revoke all on function portal_notify_message() from public, anon, authenticated;
revoke all on function portal_notify_item() from public, anon, authenticated;
