-- Website analytics for gatehousestrategic.com, copied from koshercru.com
-- (which follows soventro.com). Run in the gridaudit project, after the
-- portal SQL (portal.sql to portal-v4.sql). Safe to run again.
--
-- No cookies and no stored address. A visitor is a hash of the day's random
-- salt, the address and the browser string; the salt is deleted the next day,
-- so yesterday's hashes can no longer be tied to anyone, and a visitor is
-- counted once per day. Views older than 760 days are deleted.
--
-- The site is static, so the page calls gh_track_view() and gh_track_time()
-- straight from the browser with the public key; they read the address,
-- browser and language from the request headers themselves. Not counted:
-- bots, browsers sending Global Privacy Control, and any network address an
-- admin used /admin from in the last 30 days (portal_admin_ips).
-- The tables are closed to every role; gh_site_analytics() is admins only.

create table if not exists gh_analytics_salts (
  day  date primary key,
  salt text not null
);
alter table gh_analytics_salts enable row level security;

create table if not exists gh_page_views (
  id           bigint generated always as identity primary key,
  day          date not null,
  visitor      text not null,
  path         text not null,
  referrer     text,
  utm_source   text,
  utm_campaign text,
  device       text,
  browser      text,
  os           text,
  country      text,
  language     text,
  view_key     text,
  seconds      integer,
  created_at   timestamptz not null default now()
);
alter table gh_page_views enable row level security;

create index if not exists gh_page_views_day_idx on gh_page_views (day);
create index if not exists gh_page_views_visit_idx on gh_page_views (day, visitor);
create index if not exists gh_page_views_key_idx on gh_page_views (day, visitor, view_key);
create index if not exists gh_page_views_created_idx on gh_page_views (created_at);

-- Contact actions: pressing Send on the form, or clicking the email address.
create table if not exists gh_site_actions (
  id         bigint generated always as identity primary key,
  day        date not null,
  visitor    text not null,
  action     text not null,
  path       text not null,
  created_at timestamptz not null default now()
);
alter table gh_site_actions enable row level security;
create index if not exists gh_site_actions_day_idx on gh_site_actions (day);

-- ---------- helpers (not callable from outside) ----------

create or replace function gh_req_header(name text) returns text
language sql stable as $fn$
  select nullif(trim(current_setting('request.headers', true)::json ->> name), '');
$fn$;

-- Today's salt, made on first use. Making it also drops older salts and
-- views past retention.
create or replace function gh_analytics_day_salt(p_day date)
returns text language plpgsql security definer set search_path = public as $fn$
declare
  s text;
begin
  select salt into s from gh_analytics_salts where day = p_day;
  if s is null then
    insert into gh_analytics_salts (day, salt)
      values (p_day, encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text || random()::text, 'UTF8')), 'base64'))
      on conflict (day) do nothing;
    select salt into s from gh_analytics_salts where day = p_day;
    delete from gh_analytics_salts where day < p_day;
    delete from gh_page_views where day < p_day - 760;
    delete from gh_site_actions where day < p_day - 760;
  end if;
  return s;
end;
$fn$;

create or replace function gh_analytics_visitor(p_ip text, p_ua text)
returns text language sql security definer set search_path = public as $fn$
  select left(encode(sha256(convert_to(
    gh_analytics_day_salt((now() at time zone 'utc')::date) || E'\n' || coalesce(p_ip, '') || E'\n' || coalesce(p_ua, ''),
    'UTF8')), 'hex'), 16);
$fn$;

-- The visitor for this request, or null when it must not be counted.
create or replace function gh_analytics_counted_visitor()
returns text language plpgsql security definer set search_path = public as $fn$
declare
  v_ip text := portal_req('ip');
  v_ua text := left(coalesce(gh_req_header('user-agent'), ''), 500);
begin
  if v_ip is null or v_ua = '' then return null; end if;
  if gh_req_header('sec-gpc') = '1' then return null; end if;
  if v_ua ~* 'bot|crawl|spider|slurp|headless|lighthouse|pagespeed|preview|facebookexternalhit|embedly|monitor|uptime|curl|wget|python|axios|node-fetch|go-http|java/' then
    return null;
  end if;
  -- Gatehouse's own visits: a network address an admin used /admin from.
  if exists (select 1 from portal_admin_ips where ip = v_ip and last_seen >= now() - interval '30 days') then
    return null;
  end if;
  return gh_analytics_visitor(v_ip, v_ua);
end;
$fn$;

-- The public page as stored, or null for anything not counted.
create or replace function gh_analytics_path(p text)
returns text language sql immutable as $fn$
  select case
    when q is null or q !~* '^[a-z0-9/_-]{1,200}$' then null
    when q ~* '^/(admin|portal|b4c/answers)(/|$)' then null
    else lower(q)
  end
  from (select coalesce(nullif(regexp_replace(split_part(split_part(coalesce(p, ''), '?', 1), '#', 1), '(/index\.html)?/*$', ''), ''), '/') as q) x;
$fn$;

-- Country: Cloudflare's header when the request carries it, otherwise the
-- browser's time zone for the common ones.
create or replace function gh_analytics_country(p_tz text)
returns text language sql stable as $fn$
  select coalesce(
    (select c from (select upper(gh_req_header('cf-ipcountry')) as c) h
      where c ~ '^[A-Z]{2}$' and c not in ('XX', 'T1')),
    case
      when p_tz ~ '^America/(New_York|Detroit|Chicago|Denver|Phoenix|Los_Angeles|Anchorage|Boise|Indiana/|Kentucky/|North_Dakota/|Juneau|Sitka|Adak|Menominee|Nome)' or p_tz = 'Pacific/Honolulu' then 'US'
      when p_tz ~ '^America/(Toronto|Vancouver|Edmonton|Winnipeg|Halifax|St_Johns|Regina|Montreal|Moncton)' then 'CA'
      when p_tz = 'America/Mexico_City' then 'MX'
      when p_tz = 'America/Sao_Paulo' then 'BR'
      when p_tz = 'America/Argentina/Buenos_Aires' then 'AR'
      when p_tz in ('Asia/Jerusalem', 'Asia/Tel_Aviv') then 'IL'
      when p_tz = 'Europe/London' then 'GB'
      when p_tz = 'Europe/Dublin' then 'IE'
      when p_tz = 'Europe/Paris' then 'FR'
      when p_tz = 'Europe/Berlin' then 'DE'
      when p_tz = 'Europe/Amsterdam' then 'NL'
      when p_tz = 'Europe/Brussels' then 'BE'
      when p_tz = 'Europe/Zurich' then 'CH'
      when p_tz = 'Europe/Madrid' then 'ES'
      when p_tz = 'Europe/Rome' then 'IT'
      when p_tz = 'Europe/Kiev' or p_tz = 'Europe/Kyiv' then 'UA'
      when p_tz = 'Europe/Moscow' then 'RU'
      when p_tz in ('Asia/Kolkata', 'Asia/Calcutta') then 'IN'
      when p_tz = 'Asia/Dubai' then 'AE'
      when p_tz = 'Asia/Singapore' then 'SG'
      when p_tz = 'Asia/Shanghai' then 'CN'
      when p_tz = 'Asia/Tokyo' then 'JP'
      when p_tz ~ '^Australia/' then 'AU'
      when p_tz = 'Pacific/Auckland' then 'NZ'
      when p_tz = 'Africa/Johannesburg' then 'ZA'
    end);
$fn$;

-- ---------- what the public key may call ----------

create or replace function gh_track_view(
  p_path text, p_referrer text, p_utm_source text, p_utm_campaign text, p_key text, p_tz text
) returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_visitor text;
  v_path text := gh_analytics_path(left(p_path, 500));
  v_ua text := left(coalesce(gh_req_header('user-agent'), ''), 500);
  v_lang text := lower(split_part(split_part(split_part(coalesce(gh_req_header('accept-language'), ''), ',', 1), ';', 1), '-', 1));
  v_ref text := lower(regexp_replace(trim(coalesce(p_referrer, '')), '^www\.', ''));
  v_day date := (now() at time zone 'utc')::date;
begin
  if v_path is null then return; end if;
  v_visitor := gh_analytics_counted_visitor();
  if v_visitor is null then return; end if;
  -- One visitor can't flood the numbers.
  if (select count(*) from gh_page_views where day = v_day and visitor = v_visitor) >= 300 then return; end if;

  insert into gh_page_views (day, visitor, path, referrer, utm_source, utm_campaign,
                             device, browser, os, country, language, view_key)
  values (
    v_day, v_visitor, v_path,
    case when v_ref ~ '^[a-z0-9.-]{1,200}$' and v_ref <> 'gatehousestrategic.com' then v_ref end,
    nullif(lower(left(trim(p_utm_source), 100)), ''),
    nullif(left(trim(p_utm_campaign), 100), ''),
    case
      when v_ua ~* 'iPad|Tablet|PlayBook|Silk' or (v_ua ~* 'Android' and v_ua !~* 'Mobile') then 'tablet'
      when v_ua ~* 'Mobi|iPhone|iPod|Android|Opera Mini|IEMobile' then 'mobile'
      else 'desktop'
    end,
    case
      when v_ua ~ 'Edg(A|iOS)?/' then 'Edge'
      when v_ua ~ 'OPR/|Opera' then 'Opera'
      when v_ua ~ 'SamsungBrowser/' then 'Samsung Internet'
      when v_ua ~ 'Firefox/|FxiOS/' then 'Firefox'
      when v_ua ~ 'Chrome/|CriOS/' then 'Chrome'
      when v_ua ~ 'Safari/' and v_ua ~ 'Version/' then 'Safari'
      else 'Other'
    end,
    case
      when v_ua ~ 'iPhone|iPad|iPod' then 'iOS'
      when v_ua ~ 'Android' then 'Android'
      when v_ua ~ 'CrOS' then 'ChromeOS'
      when v_ua ~ 'Windows' then 'Windows'
      when v_ua ~ 'Mac OS X|Macintosh' then 'macOS'
      when v_ua ~ 'Linux' then 'Linux'
      else 'Other'
    end,
    gh_analytics_country(left(p_tz, 64)),
    case when v_lang ~ '^[a-z]{2,3}$' then v_lang end,
    case when p_key ~* '^[a-z0-9]{8,32}$' then p_key end
  );
end;
$fn$;

-- Adds the time spent to today's view with that key, once, and only from the
-- same visitor, so nobody can change another visitor's numbers.
create or replace function gh_track_time(p_key text, p_seconds integer)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_visitor text;
begin
  if p_key !~* '^[a-z0-9]{8,32}$' or p_seconds is null or p_seconds < 1 or p_seconds > 86400 then return; end if;
  v_visitor := gh_analytics_counted_visitor();
  if v_visitor is null then return; end if;
  update gh_page_views
     set seconds = least(1800, p_seconds)
   where day = (now() at time zone 'utc')::date
     and visitor = v_visitor
     and view_key = p_key
     and seconds is null;
end;
$fn$;

create or replace function gh_track_action(p_action text, p_path text)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_visitor text;
  v_path text := gh_analytics_path(left(p_path, 500));
  v_day date := (now() at time zone 'utc')::date;
begin
  if p_action not in ('contact_form', 'contact_email') or v_path is null then return; end if;
  v_visitor := gh_analytics_counted_visitor();
  if v_visitor is null then return; end if;
  if (select count(*) from gh_site_actions where day = v_day and visitor = v_visitor) >= 20 then return; end if;
  insert into gh_site_actions (day, visitor, action, path) values (v_day, v_visitor, p_action, v_path);
end;
$fn$;

-- ---------- the analytics page (admins only) ----------
-- Days are New York days. p_days: 1 is Today (since midnight, by hour);
-- longer ranges are the last N days, including today.
-- p_day: one day, shown by hour (drill-down from the daily chart).
-- p_filters: drill-down filters, any of page, entry, referrer ('' = direct),
-- campaign, country, language, device, browser, os. Filters pick visitors
-- (one visitor = one person on one day): a visitor is kept when any of their
-- views matches, and then all their views and contact clicks are counted.
drop function if exists gh_site_analytics(integer);
create or replace function gh_site_analytics(p_days integer, p_filters jsonb default '{}', p_day date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  tz constant text := 'America/New_York';
  is_hourly boolean := p_days = 1 or p_day is not null;
  f jsonb := coalesce(p_filters, '{}');
  today date := (now() at time zone tz)::date;
  first_day date;
  since date;
  start_ts timestamptz;
  end_ts timestamptz := 'infinity';
  result jsonb;
begin
  if not portal_is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if jsonb_typeof(f) <> 'object' then f := '{}'; end if;

  if p_day is not null then
    first_day := p_day;
    end_ts := (p_day + 1)::timestamp at time zone tz;
  else
    first_day := today - (greatest(1, least(p_days, 366)) - 1);
  end if;
  start_ts := first_day::timestamp at time zone tz;
  since := (start_ts at time zone 'utc')::date;  -- the stored day is a UTC day; this only narrows the scan

  with v_all as (
    select * from gh_page_views where day >= since and created_at >= start_ts and created_at < end_ts
  ),
  visits_all as (
    select day, visitor, count(*) as n,
           (array_agg(path order by created_at))[1] as entry,
           (array_agg(referrer order by created_at) filter (where referrer is not null))[1] as ref,
           bool_or(path = f->>'page') as m_page,
           bool_or(utm_source || coalesce(' / ' || utm_campaign, '') = f->>'campaign') as m_campaign,
           bool_or(country = f->>'country') as m_country,
           bool_or(language = f->>'language') as m_language,
           bool_or(device = f->>'device') as m_device,
           bool_or(browser = f->>'browser') as m_browser,
           bool_or(os = f->>'os') as m_os
      from v_all group by day, visitor
  ),
  visits as (
    select * from visits_all
     where (not f ? 'page' or m_page)
       and (not f ? 'entry' or entry = f->>'entry')
       and (not f ? 'referrer' or coalesce(ref, '') = f->>'referrer')
       and (not f ? 'campaign' or m_campaign)
       and (not f ? 'country' or m_country)
       and (not f ? 'language' or m_language)
       and (not f ? 'device' or m_device)
       and (not f ? 'browser' or m_browser)
       and (not f ? 'os' or m_os)
  ),
  v as (
    select v_all.* from v_all join visits using (day, visitor)
  ),
  days as (
    select d::date as day from generate_series(first_day, today, interval '1 day') d
     where not is_hourly
  ),
  hours as (
    select h as hour_start from generate_series(start_ts, least(now(), end_ts - interval '1 microsecond'), interval '1 hour') h
     where is_hourly
  ),
  acts as (
    select a.* from gh_site_actions a join visits using (day, visitor)
     where a.created_at >= start_ts and a.created_at < end_ts
  )
  select jsonb_build_object(
    'since', first_day,
    'filters', f,
    'day', p_day,
    'visitors', (select count(*) from visits),
    'views', (select count(*) from v),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object(
                 'day', days.day,
                 'visitors', (select count(distinct (v.day, v.visitor)) from v where (v.created_at at time zone tz)::date = days.day),
                 'views', (select count(*) from v where (v.created_at at time zone tz)::date = days.day)) order by days.day), '[]')
              from days),
    'hourly', (select coalesce(jsonb_agg(jsonb_build_object(
                 'hour', extract(hour from hours.hour_start at time zone tz)::int,
                 'visitors', (select count(distinct (v.day, v.visitor)) from v
                               where v.created_at >= hours.hour_start and v.created_at < hours.hour_start + interval '1 hour'),
                 'views', (select count(*) from v
                               where v.created_at >= hours.hour_start and v.created_at < hours.hour_start + interval '1 hour'))
                 order by hours.hour_start), '[]')
              from hours),
    'pages', (select coalesce(jsonb_agg(r), '[]') from (
                select path as label, count(distinct (day, visitor)) as visitors, count(*) as views
                  from v group by path order by 2 desc, 3 desc limit 100) r),
    'entryPages', (select coalesce(jsonb_agg(r), '[]') from (
                select entry as label, count(*) as visitors, sum(n) as views
                  from visits group by entry order by 2 desc, 3 desc limit 100) r),
    'referrers', (select coalesce(jsonb_agg(r), '[]') from (
                select coalesce(ref, '') as label, count(*) as visitors, sum(n) as views
                  from visits group by 1 order by 2 desc, 3 desc limit 100) r),
    'campaigns', (select coalesce(jsonb_agg(r), '[]') from (
                select utm_source || coalesce(' / ' || utm_campaign, '') as label, count(distinct (day, visitor)) as visitors, count(*) as views
                  from v where utm_source is not null group by 1 order by 2 desc, 3 desc limit 100) r),
    'countries', (select coalesce(jsonb_agg(r), '[]') from (
                select country as label, count(distinct (day, visitor)) as visitors, count(*) as views
                  from v where country is not null group by 1 order by 2 desc, 3 desc limit 100) r),
    'languages', (select coalesce(jsonb_agg(r), '[]') from (
                select language as label, count(distinct (day, visitor)) as visitors, count(*) as views
                  from v where language is not null group by 1 order by 2 desc, 3 desc limit 100) r),
    'devices', (select coalesce(jsonb_agg(r), '[]') from (
                select device as label, count(distinct (day, visitor)) as visitors, count(*) as views
                  from v where device is not null group by 1 order by 2 desc, 3 desc limit 100) r),
    'browsers', (select coalesce(jsonb_agg(r), '[]') from (
                select browser as label, count(distinct (day, visitor)) as visitors, count(*) as views
                  from v where browser is not null group by 1 order by 2 desc, 3 desc limit 100) r),
    'operatingSystems', (select coalesce(jsonb_agg(r), '[]') from (
                select os as label, count(distinct (day, visitor)) as visitors, count(*) as views
                  from v where os is not null group by 1 order by 2 desc, 3 desc limit 100) r),
    -- With a page filter, time on page is for that page only.
    'avgSeconds', (select round(avg(seconds)) from v where seconds is not null
                      and (not f ? 'page' or path = f->>'page')),
    'bounceRate', (select case when count(*) = 0 then null
                               else (count(*) filter (where n = 1))::float / count(*) end from visits),
    'liveNow', (select count(distinct visitor) from gh_page_views where created_at >= now() - interval '5 minutes'),
    'contacts', (select count(distinct (day, visitor)) from acts),
    'contactForm', (select count(*) from acts where action = 'contact_form'),
    'contactEmail', (select count(*) from acts where action = 'contact_email'),
    'portalLogins', (select count(*) from portal_events where kind = 'login_ok' and not admin
                        and created_at >= start_ts and created_at < end_ts)
  ) into result;

  return result;
end;
$fn$;

revoke all on function gh_req_header(text) from public, anon, authenticated;
revoke all on function gh_analytics_day_salt(date) from public, anon, authenticated;
revoke all on function gh_analytics_visitor(text, text) from public, anon, authenticated;
revoke all on function gh_analytics_counted_visitor() from public, anon, authenticated;
revoke all on function gh_analytics_path(text) from public, anon, authenticated;
revoke all on function gh_analytics_country(text) from public, anon, authenticated;

revoke all on function gh_track_view(text, text, text, text, text, text) from public;
revoke all on function gh_track_time(text, integer) from public;
revoke all on function gh_track_action(text, text) from public;
grant execute on function gh_track_view(text, text, text, text, text, text) to anon, authenticated;
grant execute on function gh_track_time(text, integer) to anon, authenticated;
grant execute on function gh_track_action(text, text) to anon, authenticated;

revoke all on function gh_site_analytics(integer, jsonb, date) from public, anon;
grant execute on function gh_site_analytics(integer, jsonb, date) to authenticated;
