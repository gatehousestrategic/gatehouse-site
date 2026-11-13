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
