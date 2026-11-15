-- Campaigns for gatehousestrategic.com analytics. Run in the gridaudit
-- project after site-analytics.sql (which stores utm_source, utm_medium,
-- utm_campaign and utm_content on each page view). Safe to run again.
--
-- A campaign has a name and a tag (its utm_campaign, e.g. "fall-outreach").
-- Each campaign has links: one per post, email or ad, each with a source,
-- medium, content tag (utm_content) and landing page. The admin's Campaigns
-- tab builds the tagged address for each link.
--
-- Counting follows the Analytics tab: a visitor is one person on one day. A
-- visitor belongs to a campaign when any of their views that day carries the
-- campaign's tag, and then all their views and contact clicks that day count.
-- Only admins can read or change campaigns; nothing here is public.

create table if not exists gh_campaigns (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) between 1 and 120),
  slug        text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{0,59}$'),
  note        text check (length(note) <= 2000),
  archived_at timestamptz,
  created_at  timestamptz not null default now()
);
alter table gh_campaigns enable row level security;

create table if not exists gh_campaign_links (
  id          uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references gh_campaigns (id) on delete cascade,
  label       text not null check (length(trim(label)) between 1 and 120),
  source      text not null check (source ~ '^[a-z0-9][a-z0-9._-]{0,59}$'),
  medium      text check (medium ~ '^[a-z0-9][a-z0-9._-]{0,59}$'),
  content     text not null check (content ~ '^[a-z0-9][a-z0-9-]{0,59}$'),
  path        text not null default '/' check (path ~ '^/[a-z0-9/_-]{0,200}$'),
  created_at  timestamptz not null default now(),
  unique (campaign_id, content)
);
alter table gh_campaign_links enable row level security;
create index if not exists gh_campaign_links_campaign_idx on gh_campaign_links (campaign_id);

drop policy if exists "admins manage campaigns" on gh_campaigns;
create policy "admins manage campaigns" on gh_campaigns for all to authenticated
  using (portal_is_admin()) with check (portal_is_admin());
drop policy if exists "admins manage campaign links" on gh_campaign_links;
create policy "admins manage campaign links" on gh_campaign_links for all to authenticated
  using (portal_is_admin()) with check (portal_is_admin());

revoke all on gh_campaigns, gh_campaign_links from anon;
grant select, insert, update, delete on gh_campaigns, gh_campaign_links to authenticated;

-- Numbers for every campaign and each of its links, plus tagged visits that
-- match no campaign. p_days: the last N New York days including today;
-- null = all time.
create or replace function gh_campaign_stats(p_days integer default null)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  tz constant text := 'America/New_York';
  start_ts timestamptz := '-infinity';
  result jsonb;
begin
  if not portal_is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_days is not null then
    start_ts := ((now() at time zone tz)::date - (greatest(1, least(p_days, 760)) - 1))::timestamp at time zone tz;
  end if;

  with v_all as (
    select * from gh_page_views where created_at >= start_ts
  ),
  tagged as (
    select day, visitor, created_at, lower(utm_campaign) as camp, utm_source as source,
           utm_medium as medium, utm_content as content
      from v_all where utm_campaign is not null
  ),
  visits as (
    select day, visitor, count(*) as n, round(avg(seconds)) as secs
      from v_all group by day, visitor
  ),
  acts as (
    select day, visitor, count(*) as clicks from gh_site_actions
     where created_at >= start_ts group by day, visitor
  ),
  -- one row per campaign and visitor-day that carried its tag
  camp_visits as (
    select c.id as campaign_id, t.day, t.visitor, min(t.created_at) as first_at
      from gh_campaigns c join tagged t on t.camp = c.slug
     group by c.id, t.day, t.visitor
  ),
  link_visits as (
    select l.id as link_id, t.day, t.visitor
      from gh_campaign_links l
      join gh_campaigns c on c.id = l.campaign_id
      join tagged t on t.camp = c.slug and t.content = l.content
                   and t.source = l.source and t.medium is not distinct from l.medium
     group by l.id, t.day, t.visitor
  ),
  camp_rows as (
    select cv.campaign_id,
           count(*) as visitors,
           sum(vi.n) as views,
           count(a.visitor) as contacts,
           (count(*) filter (where vi.n = 1))::float / nullif(count(*), 0) as bounce,
           round(avg(vi.secs)) as avg_seconds,
           min(cv.first_at) as first_seen,
           max(cv.first_at) as last_seen
      from camp_visits cv
      join visits vi using (day, visitor)
      left join acts a using (day, visitor)
     group by cv.campaign_id
  ),
  link_rows as (
    select lv.link_id, count(*) as visitors, sum(vi.n) as views, count(a.visitor) as contacts
      from link_visits lv
      join visits vi using (day, visitor)
      left join acts a using (day, visitor)
     group by lv.link_id
  ),
  untracked as (
    select coalesce(lower(t.utm_campaign), '') as campaign, t.utm_source as source, t.utm_medium as medium,
           t.utm_content as content, count(distinct (t.day, t.visitor)) as visitors, count(*) as views
      from v_all t
     where (t.utm_source is not null or t.utm_campaign is not null)
       and not exists (select 1 from gh_campaigns c where c.slug = lower(t.utm_campaign))
     group by 1, 2, 3, 4
     order by 5 desc, 6 desc
     limit 50
  )
  select jsonb_build_object(
    'campaigns', (select coalesce(jsonb_object_agg(campaign_id, to_jsonb(r) - 'campaign_id'), '{}') from camp_rows r),
    'links', (select coalesce(jsonb_object_agg(link_id, to_jsonb(r) - 'link_id'), '{}') from link_rows r),
    'untracked', (select coalesce(jsonb_agg(to_jsonb(u)), '[]') from untracked u)
  ) into result;
  return result;
end;
$fn$;

revoke all on function gh_campaign_stats(integer) from public, anon;
grant execute on function gh_campaign_stats(integer) to authenticated;
