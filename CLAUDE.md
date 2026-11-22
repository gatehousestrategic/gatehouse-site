# gatehouse-site — notes for Claude

Static site for gatehousestrategic.com. Porkbun static hosting deploys the
repo root from `master` (GitHub Connect), so pushing to `master` deploys.
`deploy/` is a mirror of the root pages: keep the two in sync when you change a page.
Backend is the **gridaudit** Supabase project (ref `hlohdnjxemwpnnkxnhqx`);
SQL files live in `supabase/` and are run by hand in that project's SQL Editor.

The owner reviews visible site changes before they go live; deploy them yourself
(no zips to upload).

## Website analytics (added 2026-11-13, commit b87f4b0)

Copied from KosherCru's analytics (repo gatehousestrategic/koshercru:
`src/app/api/collect/route.ts`, `src/app/admin/analytics/page.tsx`,
`supabase/migrations/20261111_site_analytics.sql` and `20261112_site_analytics_today.sql`).
Because this site is static, the browser calls Supabase RPCs directly with the
public key instead of going through a server route.

- `track.js`: cookieless beacon on `/`, `/login`, `/b4c`, `/b4c/scope` and `/westwood`
  (not admin, portal or b4c/answers). It sends one view per page, then the
  time on screen when the visitor leaves, plus contact actions (`contact_form` from the
  index.html form handler via `window.ghTrack`, and `contact_email` from mailto link
  clicks). It skips Global Privacy Control, `navigator.webdriver`, and browsers
  signed in to /admin.
- `supabase/site-analytics.sql`: tables `gh_page_views`, `gh_site_actions` and
  `gh_analytics_salts` (daily salt; a visitor is hash(salt, ip, ua), counted once per day;
  760-day retention). Public RPCs: `gh_track_view`, `gh_track_time` and `gh_track_action`;
  they read the IP, UA and language from the request headers and skip bots, GPC and admin IPs
  (`portal_admin_ips`, last 30 days), capped at 300 views per visitor per day. Admin RPC:
  `gh_site_analytics(p_days)`, where 1 = Today in New York time with hourly bars.
  Country comes from `cf-ipcountry` if Supabase passes it, otherwise a time-zone fallback.
  Tested on local Postgres 16.
- `admin/index.html`: new **Analytics** tab (internally `data-tab="website"`; range picker; metrics for visitors, page views,
  contact clicks, client portal logins, time on page, bounce and live visitors; daily or
  hourly chart; top lists). Also fixed the admin top bar overflowing on phones.

### Drill-down (added 2026-11-14)
- `gh_site_analytics(p_days, p_filters jsonb default '{}', p_day date default null)`
  replaced the one-argument version (the SQL drops the old one). All days are New York days.
- Filters (`page`, `entry`, `referrer` with '' meaning direct, `campaign`, `country`,
  `language`, `device`, `browser`, `os`) pick visitors: a visitor (one person on one day)
  is kept if any of their views matches, then all their views and contact clicks count.
  With a `page` filter, time on page is for that page only. Client portal logins and
  "visitors right now" are not filtered.
- Source is now per visitor (the first outside referrer of the visit), not per view.
- `p_day` shows one day by hour (clicking a bar in the daily chart).
- In `admin/index.html`, rows in every list are buttons that add or remove a filter; the
  "Filtered:" line has × per filter and "Clear all"; lists show 10 with "Show all" (up to 100).
  The view is kept in the address as `#analytics?range=30&country=US&day=2026-11-12`, so
  Back works and views can be bookmarked; opening /admin with that hash goes straight to it.

### SQL run 2026-11-13
`supabase/site-analytics.sql` was run in gridaudit on 2026-11-13 from the SQL Editor
(safe to re-run after edits). Checked: all gh_ tables and functions exist; the live
home page's `gh_track_view` call returns 204; a simulated outside visit (rolled back)
stored country, device, browser, OS, language, referrer, time on page and a contact
click correctly. A real visit from the owner's desktop stored nothing, most likely because that
network is in `portal_admin_ips` (skipped by design; not confirmed, since this
network blocks IP-lookup sites). `gh_site_analytics` answers "permission denied" unless the caller
is signed in to /admin; that is expected.
Still to see: real visits and whether the country list fills from `cf-ipcountry`
(if not, only the time-zone fallback is in use).

### Campaigns (added 2026-11-15)
- `supabase/campaigns.sql`: tables `gh_campaigns` (name, slug = the utm_campaign tag, note,
  archived_at) and `gh_campaign_links` (label, source, medium, content = utm_content, landing path),
  admin-only through RLS with `portal_is_admin()`. Admin RPC `gh_campaign_stats(p_days)` (null = all
  time) returns numbers per campaign and per link, plus tagged visits that match no campaign.
  Same counting as Analytics: a visitor-day joins a campaign if any view carries its tag.
- `site-analytics.sql` now stores `utm_medium` and `utm_content` too, lowercases all tags, and
  `gh_track_view` takes them as two extra arguments with defaults (old 6-argument calls still work).
  The Analytics "Campaigns" list and `campaign` filter are by tag (`''` = tagged link without one).
- `track.js` sends medium and content; pages load it as `track.js?v=2`.
- `admin/index.html`: **Campaigns** tab (create, archive, delete; links with a live preview and
  Copy; per-link numbers; "Make a campaign" from an unmatched tag; "Open in Analytics").
  Links always point at https://gatehousestrategic.com.
- Run order: site-analytics.sql, then campaigns.sql, then push (the new track.js needs the new
  gh_track_view). Tested 2026-11-15 in gridaudit inside a rolled-back transaction.

## Portal email alerts (added 2026-11-16)
`supabase/portal-alerts.sql` (run in gridaudit 2026-11-16): triggers on `portal_messages`
(client messages, not `from_admin`) and `portal_items` (`uploaded_by = 'client'`) call
`portal_send_alert()`, which posts to the Resend API with pg_net. From
portal@gatehousestrategic.com to os@gatehousestrategic.com (domain verified in Resend).
The key is the Vault secret `resend_api_key`, added by the owner; never put it in this repo.
A missing key or a Resend error only skips the email; the message or upload still saves.
Send results are in `net._http_response`. A test alert on 2026-11-16 returned 200.

## Client update emails (added 2026-11-16)
`supabase/portal-client-emails.sql` (run in gridaudit 2026-11-16): `portal_clients.notify_email`
(comma-separated, set as "Email for updates" on the client page in /admin) and `notify_last_at`.
Triggers on `portal_messages` (`from_admin`) and `portal_items` (`uploaded_by = 'admin'`) call
`portal_notify_client()`: a short "something new, sign in at /login" email from
portal@gatehousestrategic.com, reply-to os@gatehousestrategic.com, never the message text.
At most one per client per 15 minutes; no email for archived clients or an empty address.
Same Resend key and failure behavior as the owner alerts. Tested 2026-11-16: rolled-back run
(one email for a message plus a note, bad address dropped, client without address skipped)
and one real send to the owner's address (Resend 200).

### Branded emails (2026-11-16)
Both email types are HTML with a plain-text copy. `portal_email_html()` in portal-alerts.sql
builds the layout (navy header with `img/email-logo.png`, white card, one square-cornered button,
no pills); `portal_html_esc()` escapes client text. The logo PNG is rendered from the site's mark
plus "Gatehouse / Strategic" in Spectral (email apps don't load SVG or web fonts); don't delete or
rename it. Run order: portal-alerts.sql, then portal-client-emails.sql. Sent one of each to the
owner on 2026-11-16 (Resend 200).

## Portal device count (added 2026-11-21)
`supabase/portal-devices.sql` (run in gridaudit 2026-11-21 by the owner): `portal_events.device_id`
and `portal_login(p_code, p_device default null)` (the one-argument version is dropped; calls
without p_device still work). `login/index.html` keeps a random tag per browser in localStorage
(`gh_portal_device`) and sends it. On a client's page in /admin the Access codes table has a
**Devices** column (different browsers per code, from `login_ok` events); clicking it lists each
device with first/last sign-in and count. It counts browsers, not people. Sign-ins before
2026-11-21 have no tag and are shown as "earlier sign-ins". Checked 2026-11-21: wrong codes with,
without and with a malformed tag all answer no_match; a rolled-back test showed a correct code
signs in with and without p_device and stores the tag.
