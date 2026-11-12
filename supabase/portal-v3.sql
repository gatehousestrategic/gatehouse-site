-- Gatehouse client portal, part 3: nothing is reachable without a code.
-- Run after portal.sql and portal-v2.sql, in the gridaudit project. Safe to run again.
--
-- * The file bucket becomes private. Files open only through short-lived
--   links handed out by the portal-files function (supabase/functions/portal-files)
--   to a signed-in client, or to an admin.
-- * New item type "site": a website preview stored in the private bucket and
--   shown inside the client dashboard, so previews no longer live on the
--   public website.

update storage.buckets set public = false where id = 'portal-files';

alter table portal_items drop constraint if exists portal_items_kind_check;
alter table portal_items add constraint portal_items_kind_check
  check (kind in ('link', 'file', 'note', 'site'));
