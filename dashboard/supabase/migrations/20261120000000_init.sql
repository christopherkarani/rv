-- rv Cloud schema.
--
-- Tenancy: every row belongs to an org. Signed-in users read their orgs'
-- rows through row-level security; writes from machines (enroll, report,
-- events) go through security-definer functions callable only by the
-- service role, each in one transaction.

-- ---------------------------------------------------------------------------
-- Types

create type public.org_role as enum ('owner', 'admin', 'viewer');
create type public.org_plan as enum ('pilot', 'team', 'business', 'enterprise');
create type public.chain_status as enum ('unknown', 'ok', 'gap', 'broken');

-- ---------------------------------------------------------------------------
-- Orgs and membership

create table public.orgs (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 100),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'),
  plan public.org_plan not null default 'pilot',
  retention_days integer not null default 30 check (retention_days between 1 and 3650),
  created_at timestamptz not null default now()
);

create table public.org_members (
  org_id uuid not null references public.orgs (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.org_role not null default 'viewer',
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index org_members_user_idx on public.org_members (user_id);

create table public.org_invites (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs (id) on delete cascade,
  email text not null check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+$'),
  role public.org_role not null default 'viewer' check (role <> 'owner'),
  invited_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 days',
  accepted_at timestamptz,
  unique (org_id, email)
);

-- Membership checks used by policies. Security definer so the policy on
-- org_members does not recurse into itself; empty search_path for safety.
create function public.is_org_member(p_org uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.org_members m
    where m.org_id = p_org and m.user_id = (select auth.uid())
  )
$$;

create function public.has_org_role(p_org uuid, p_roles public.org_role[])
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.org_members m
    where m.org_id = p_org and m.user_id = (select auth.uid()) and m.role = any (p_roles)
  )
$$;

-- An org always keeps at least one owner.
create function public.keep_an_owner()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_org uuid := coalesce(old.org_id, new.org_id);
begin
  if old.role = 'owner' and (tg_op = 'DELETE' or new.role <> 'owner') then
    -- Cascading delete of the whole org is fine.
    if not exists (select 1 from public.orgs where id = v_org) then
      return old;
    end if;
    if not exists (
      select 1 from public.org_members
      where org_id = v_org and role = 'owner' and user_id <> old.user_id
    ) then
      raise exception 'an organization needs at least one owner' using errcode = 'P0001';
    end if;
  end if;
  return coalesce(new, old);
end
$$;

create trigger org_members_keep_owner
before update or delete on public.org_members
for each row execute function public.keep_an_owner();

-- ---------------------------------------------------------------------------
-- Enrollment and machines

create table public.enrollment_tokens (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs (id) on delete cascade,
  token_hash text not null unique,
  prefix text not null,
  label text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  max_uses integer not null default 100 check (max_uses between 1 and 100000),
  uses integer not null default 0,
  revoked_at timestamptz
);
create index enrollment_tokens_org_idx on public.enrollment_tokens (org_id);

create table public.machines (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 255),
  hostname text,
  os_user text,
  platform text,
  rv_version text,
  team text check (team is null or char_length(team) between 1 and 64),
  credential_hash text not null unique,
  credential_prefix text not null,
  enrolled_via uuid references public.enrollment_tokens (id) on delete set null,
  enrolled_at timestamptz not null default now(),
  revoked_at timestamptz,
  last_report_at timestamptz,
  last_event_at timestamptz,
  last_seen_at timestamptz,
  latest_report jsonb,
  compliant boolean,
  chain_head text,
  chain_status public.chain_status not null default 'unknown'
);
create index machines_org_idx on public.machines (org_id);

create table public.reports (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.orgs (id) on delete cascade,
  machine_id uuid not null references public.machines (id) on delete cascade,
  generated_at timestamptz,
  received_at timestamptz not null default now(),
  compliant boolean not null,
  body jsonb not null
);
create index reports_machine_idx on public.reports (machine_id, received_at desc);
create index reports_org_received_idx on public.reports (org_id, received_at);

create table public.events (
  org_id uuid not null references public.orgs (id) on delete cascade,
  machine_id uuid not null references public.machines (id) on delete cascade,
  uid text not null,
  time timestamptz not null,
  received_at timestamptz not null default now(),
  kind text not null,
  decision text not null,
  subject text not null,
  host text,
  tool text,
  reason text,
  source text,
  prev text,
  chain_head text,
  body jsonb not null,
  primary key (machine_id, uid)
);
create index events_org_time_idx on public.events (org_id, time desc);
create index events_org_kind_time_idx on public.events (org_id, kind, time desc);
create index events_machine_time_idx on public.events (machine_id, time desc);
create index events_org_received_idx on public.events (org_id, received_at);

create table public.chain_findings (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.orgs (id) on delete cascade,
  machine_id uuid not null references public.machines (id) on delete cascade,
  kind text not null check (kind in ('gap', 'broken')),
  expected text,
  got text,
  detail text,
  detected_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index chain_findings_org_idx on public.chain_findings (org_id, detected_at desc);

-- ---------------------------------------------------------------------------
-- Policy

create table public.org_signing_keys (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs (id) on delete cascade,
  public_key text not null check (public_key ~ '^[A-Za-z0-9+/]{43}=$'),
  label text,
  added_by uuid references auth.users (id) on delete set null,
  added_at timestamptz not null default now(),
  unique (org_id, public_key)
);

create table public.policy_revisions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs (id) on delete cascade,
  serial bigint not null check (serial >= 0),
  policy_text text not null,
  policy_sha256 text not null,
  signature text not null,
  signing_key_id uuid references public.org_signing_keys (id) on delete set null,
  summary text,
  uploaded_by uuid references auth.users (id) on delete set null,
  uploaded_at timestamptz not null default now(),
  unique (org_id, serial)
);

-- ---------------------------------------------------------------------------
-- Admin audit log (append-only)

create table public.admin_audit (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.orgs (id) on delete cascade,
  actor uuid references auth.users (id) on delete set null,
  action text not null,
  target text,
  detail jsonb not null default '{}'::jsonb,
  at timestamptz not null default now()
);
create index admin_audit_org_idx on public.admin_audit (org_id, at desc);

-- ---------------------------------------------------------------------------
-- Rate limiting (fixed windows, shared across serverless instances)

create table public.rate_limits (
  key text not null,
  window_start timestamptz not null,
  count integer not null default 0,
  primary key (key, window_start)
);

create function public.take_rate_limit(p_key text, p_limit integer, p_window_seconds integer)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_window timestamptz := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  v_count integer;
begin
  insert into public.rate_limits (key, window_start, count)
  values (p_key, v_window, 1)
  on conflict (key, window_start) do update set count = public.rate_limits.count + 1
  returning count into v_count;
  return v_count <= p_limit;
end
$$;

-- ---------------------------------------------------------------------------
-- Row-level security

alter table public.orgs enable row level security;
alter table public.org_members enable row level security;
alter table public.org_invites enable row level security;
alter table public.enrollment_tokens enable row level security;
alter table public.machines enable row level security;
alter table public.reports enable row level security;
alter table public.events enable row level security;
alter table public.chain_findings enable row level security;
alter table public.org_signing_keys enable row level security;
alter table public.policy_revisions enable row level security;
alter table public.admin_audit enable row level security;
alter table public.rate_limits enable row level security;

-- orgs: members read; owners and admins rename and set retention.
-- Creation goes through create_org().
create policy orgs_select on public.orgs for select to authenticated
  using (public.is_org_member(id));
create policy orgs_update on public.orgs for update to authenticated
  using (public.has_org_role(id, array['owner', 'admin']::public.org_role[]))
  with check (public.has_org_role(id, array['owner', 'admin']::public.org_role[]));

-- Only these org columns are user-editable; plan changes go through billing.
revoke update on public.orgs from authenticated, anon;
grant update (name, retention_days) on public.orgs to authenticated;

-- members: members see each other; owners manage everyone, admins manage viewers.
create policy members_select on public.org_members for select to authenticated
  using (public.is_org_member(org_id));
create policy members_update on public.org_members for update to authenticated
  using (public.has_org_role(org_id, array['owner']::public.org_role[]))
  with check (public.has_org_role(org_id, array['owner']::public.org_role[]));
create policy members_delete on public.org_members for delete to authenticated
  using (
    public.has_org_role(org_id, array['owner']::public.org_role[])
    or (role = 'viewer' and public.has_org_role(org_id, array['admin']::public.org_role[]))
    or user_id = (select auth.uid())
  );

create policy invites_select on public.org_invites for select to authenticated
  using (public.has_org_role(org_id, array['owner', 'admin']::public.org_role[]));
create policy invites_insert on public.org_invites for insert to authenticated
  with check (
    invited_by = (select auth.uid())
    and (
      public.has_org_role(org_id, array['owner']::public.org_role[])
      or (role = 'viewer' and public.has_org_role(org_id, array['admin']::public.org_role[]))
    )
  );
create policy invites_delete on public.org_invites for delete to authenticated
  using (public.has_org_role(org_id, array['owner', 'admin']::public.org_role[]));

-- enrollment tokens: admins create, list and revoke; hashes only.
create policy tokens_select on public.enrollment_tokens for select to authenticated
  using (public.has_org_role(org_id, array['owner', 'admin']::public.org_role[]));
create policy tokens_insert on public.enrollment_tokens for insert to authenticated
  with check (
    created_by = (select auth.uid()) and uses = 0 and revoked_at is null
    and public.has_org_role(org_id, array['owner', 'admin']::public.org_role[])
  );
create policy tokens_update on public.enrollment_tokens for update to authenticated
  using (public.has_org_role(org_id, array['owner', 'admin']::public.org_role[]))
  with check (public.has_org_role(org_id, array['owner', 'admin']::public.org_role[]));
revoke update on public.enrollment_tokens from authenticated, anon;
grant update (revoked_at) on public.enrollment_tokens to authenticated;

-- machines: members read; admins set team and revoke. Machines are created by enroll_machine().
create policy machines_select on public.machines for select to authenticated
  using (public.is_org_member(org_id));
create policy machines_update on public.machines for update to authenticated
  using (public.has_org_role(org_id, array['owner', 'admin']::public.org_role[]))
  with check (public.has_org_role(org_id, array['owner', 'admin']::public.org_role[]));
revoke update on public.machines from authenticated, anon;
grant update (team, revoked_at) on public.machines to authenticated;
-- The credential hash never leaves the server.
revoke select on public.machines from authenticated, anon;
grant select (
  id, org_id, name, hostname, os_user, platform, rv_version, team, credential_prefix,
  enrolled_via, enrolled_at, revoked_at, last_report_at, last_event_at, last_seen_at,
  latest_report, compliant, chain_head, chain_status
) on public.machines to authenticated;

create policy reports_select on public.reports for select to authenticated
  using (public.is_org_member(org_id));
create policy events_select on public.events for select to authenticated
  using (public.is_org_member(org_id));
create policy findings_select on public.chain_findings for select to authenticated
  using (public.is_org_member(org_id));

create policy keys_select on public.org_signing_keys for select to authenticated
  using (public.is_org_member(org_id));
create policy keys_insert on public.org_signing_keys for insert to authenticated
  with check (added_by = (select auth.uid()) and public.has_org_role(org_id, array['owner']::public.org_role[]));
create policy keys_delete on public.org_signing_keys for delete to authenticated
  using (public.has_org_role(org_id, array['owner']::public.org_role[]));

create policy policies_select on public.policy_revisions for select to authenticated
  using (public.is_org_member(org_id));
-- Uploads go through the server, which verifies the signature first, using
-- the service role. No insert policy for users.

create policy admin_audit_select on public.admin_audit for select to authenticated
  using (public.has_org_role(org_id, array['owner', 'admin']::public.org_role[]));
create policy admin_audit_insert on public.admin_audit for insert to authenticated
  with check (actor = (select auth.uid()) and public.is_org_member(org_id));

-- Nothing for anon anywhere; rate_limits is server-only.
revoke all on public.rate_limits from anon, authenticated;

-- ---------------------------------------------------------------------------
-- User-facing functions

-- Create an org and make the caller its owner.
create function public.create_org(p_name text, p_slug text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
begin
  if v_user is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if (select count(*) from public.org_members where user_id = v_user and role = 'owner') >= 10 then
    raise exception 'too many organizations' using errcode = 'P0001';
  end if;
  insert into public.orgs (name, slug) values (p_name, p_slug) returning id into v_org;
  insert into public.org_members (org_id, user_id, role) values (v_org, v_user, 'owner');
  insert into public.admin_audit (org_id, actor, action, target) values (v_org, v_user, 'org.created', p_slug);
  return v_org;
end
$$;

-- Join every pending invite addressed to the caller's confirmed email.
create function public.accept_invites()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_email text;
  v_count integer := 0;
  r record;
begin
  if v_user is null then
    return 0;
  end if;
  select lower(email) into v_email from auth.users where id = v_user and email_confirmed_at is not null;
  if v_email is null then
    return 0;
  end if;
  for r in
    select * from public.org_invites
    where email = v_email and accepted_at is null and expires_at > now()
    for update
  loop
    insert into public.org_members (org_id, user_id, role)
    values (r.org_id, v_user, r.role)
    on conflict (org_id, user_id) do nothing;
    update public.org_invites set accepted_at = now() where id = r.id;
    insert into public.admin_audit (org_id, actor, action, target)
    values (r.org_id, v_user, 'member.joined', v_email);
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;

-- Members with their email, for the settings page. auth.users is not
-- readable by signed-in users, so this returns emails only to fellow members.
create function public.org_member_list(p_org uuid)
returns table (user_id uuid, email text, role public.org_role, created_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select m.user_id, u.email::text, m.role, m.created_at
  from public.org_members m
  join auth.users u on u.id = m.user_id
  where m.org_id = p_org and public.is_org_member(p_org)
  order by m.created_at
$$;

-- Admin log with actor emails, for owners and admins.
create function public.org_admin_audit(p_org uuid, p_limit integer default 50)
returns table (id bigint, actor_email text, action text, target text, detail jsonb, at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select a.id, u.email::text, a.action, a.target, a.detail, a.at
  from public.admin_audit a
  left join auth.users u on u.id = a.actor
  where a.org_id = p_org
    and public.has_org_role(p_org, array['owner', 'admin']::public.org_role[])
  order by a.at desc
  limit least(p_limit, 500)
$$;

-- Dashboard aggregates. Security invoker, so RLS on events applies.
create function public.org_daily_activity(p_org uuid, p_days integer default 14)
returns table (day date, denied bigint, observed bigint, overrides bigint)
language sql stable
as $$
  with days as (
    select generate_series(
      (now() at time zone 'utc')::date - (p_days - 1),
      (now() at time zone 'utc')::date,
      interval '1 day'
    )::date as day
  )
  select
    d.day,
    count(e.uid) filter (where e.kind = 'command.denied'),
    count(e.uid) filter (where e.kind = 'command.observed'),
    count(e.uid) filter (where e.kind = 'command.override')
  from days d
  left join public.events e
    on e.org_id = p_org
    and e.time >= d.day::timestamp at time zone 'utc'
    and e.time < (d.day + 1)::timestamp at time zone 'utc'
    and e.kind in ('command.denied', 'command.observed', 'command.override')
  group by d.day
  order by d.day
$$;

create function public.org_top_rules(p_org uuid, p_kind text, p_since timestamptz, p_limit integer default 10, p_host text default null)
returns table (subject text, hits bigint, machines bigint, hosts text[], would_deny bigint, would_ask bigint)
language sql stable
as $$
  select
    e.subject,
    count(*),
    count(distinct e.machine_id),
    array_remove(array_agg(distinct e.host), null),
    count(*) filter (where e.body #>> '{detail,would_be}' = 'deny' or e.body #>> '{unmapped,rv_detail,would_be}' = 'deny'),
    count(*) filter (where e.body #>> '{detail,would_be}' = 'ask' or e.body #>> '{unmapped,rv_detail,would_be}' = 'ask')
  from public.events e
  where e.org_id = p_org and e.kind = p_kind and e.time >= p_since
    and (p_host is null or e.host = p_host)
  group by e.subject
  order by count(*) desc
  limit p_limit
$$;

create function public.org_override_counts(p_org uuid, p_since timestamptz)
returns table (subject text, overrides bigint)
language sql stable
as $$
  select e.subject, count(*)
  from public.events e
  where e.org_id = p_org and e.kind = 'command.override' and e.time >= p_since
  group by e.subject
$$;

create function public.org_observed_by_host(p_org uuid, p_since timestamptz)
returns table (host text, would_deny bigint, would_ask bigint, machines bigint)
language sql stable
as $$
  select
    coalesce(e.host, 'unknown'),
    count(*) filter (where coalesce(e.body #>> '{detail,would_be}', e.body #>> '{unmapped,rv_detail,would_be}') = 'deny'),
    count(*) filter (where coalesce(e.body #>> '{detail,would_be}', e.body #>> '{unmapped,rv_detail,would_be}') = 'ask'),
    count(distinct e.machine_id)
  from public.events e
  where e.org_id = p_org and e.kind = 'command.observed' and e.time >= p_since
  group by 1
$$;

-- ---------------------------------------------------------------------------
-- Machine-facing functions (service role only)

create function public.enroll_machine(
  p_token_hash text,
  p_credential_hash text,
  p_credential_prefix text,
  p_name text,
  p_platform text,
  p_rv_version text
)
returns table (machine_id uuid, org_id uuid)
language plpgsql security definer set search_path = ''
as $$
declare
  t public.enrollment_tokens%rowtype;
  v_machine uuid;
begin
  select * into t from public.enrollment_tokens where token_hash = p_token_hash for update;
  if not found or t.revoked_at is not null or t.expires_at <= now() or t.uses >= t.max_uses then
    return;
  end if;
  update public.enrollment_tokens set uses = uses + 1 where id = t.id;
  insert into public.machines (org_id, name, platform, rv_version, credential_hash, credential_prefix, enrolled_via, last_seen_at)
  values (t.org_id, p_name, p_platform, p_rv_version, p_credential_hash, p_credential_prefix, t.id, now())
  returning id into v_machine;
  insert into public.admin_audit (org_id, actor, action, target, detail)
  values (t.org_id, null, 'machine.enrolled', p_name, jsonb_build_object('machine_id', v_machine, 'token', t.prefix));
  machine_id := v_machine;
  org_id := t.org_id;
  return next;
end
$$;

-- Store one rv.report.v1 document. Compliance is computed by the caller with
-- the same rule as rv's ReportRun.Report.compliant.
create function public.ingest_report(p_machine uuid, p_report jsonb, p_compliant boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  m public.machines%rowtype;
  v_generated timestamptz;
begin
  select * into m from public.machines where id = p_machine and revoked_at is null for update;
  if not found then
    raise exception 'unknown machine' using errcode = 'P0002';
  end if;
  begin
    v_generated := (p_report ->> 'generatedAt')::timestamptz;
  exception when others then
    v_generated := null;
  end;
  insert into public.reports (org_id, machine_id, generated_at, compliant, body)
  values (m.org_id, m.id, v_generated, p_compliant, p_report);
  update public.machines set
    latest_report = p_report,
    compliant = p_compliant,
    rv_version = coalesce(p_report #>> '{rv,version}', rv_version),
    platform = coalesce(p_report #>> '{rv,platform}', platform),
    hostname = coalesce(p_report #>> '{host,name}', hostname),
    os_user = coalesce(p_report #>> '{host,user}', os_user),
    last_report_at = now(),
    last_seen_at = now(),
    chain_status = case
      when p_report #>> '{audit,chainIntact}' = 'false' then 'broken'::public.chain_status
      when chain_status = 'broken' and p_report #>> '{audit,chainIntact}' = 'true' then 'ok'::public.chain_status
      else chain_status
    end
  where id = m.id;
  if p_report #>> '{audit,chainIntact}' = 'false' and m.chain_status <> 'broken' then
    insert into public.chain_findings (org_id, machine_id, kind, detail)
    values (m.org_id, m.id, 'broken', 'rv report says audit.jsonl fails rv audit verify');
  end if;
end
$$;

-- Store a batch of normalized events. Idempotent on (machine, uid): rv's
-- forwarder is at-least-once. For new events that carry a chain head, the
-- first `prev` must continue the last head seen; anything else is a gap.
create function public.ingest_events(p_machine uuid, p_events jsonb)
returns table (inserted integer, duplicates integer, gaps integer)
language plpgsql security definer set search_path = ''
as $$
declare
  m public.machines%rowtype;
  v_head text;
  v_gaps integer := 0;
  v_inserted integer := 0;
  v_total integer := jsonb_array_length(p_events);
  v_last timestamptz;
  v_first timestamptz;
  v_new jsonb;
  r record;
begin
  select * into m from public.machines where id = p_machine and revoked_at is null for update;
  if not found then
    raise exception 'unknown machine' using errcode = 'P0002';
  end if;
  v_head := m.chain_head;

  with incoming as (
    select distinct on (value ->> 'uid') value as e, ordinality as pos
    from jsonb_array_elements(p_events) with ordinality
    order by value ->> 'uid', ordinality
  ),
  ins as (
    insert into public.events (org_id, machine_id, uid, time, kind, decision, subject, host, tool, reason, source, prev, chain_head, body)
    select
      m.org_id, m.id,
      i.e ->> 'uid',
      (i.e ->> 'time')::timestamptz,
      i.e ->> 'kind',
      i.e ->> 'decision',
      i.e ->> 'subject',
      i.e ->> 'host',
      i.e ->> 'tool',
      i.e ->> 'reason',
      i.e ->> 'source',
      i.e ->> 'prev',
      i.e ->> 'chainHead',
      i.e -> 'body'
    from incoming i
    on conflict (machine_id, uid) do nothing
    returning uid, prev, chain_head, time
  )
  select coalesce(
    jsonb_agg(jsonb_build_object('prev', ins.prev, 'head', ins.chain_head, 'time', ins.time) order by i.pos),
    '[]'::jsonb
  )
  into v_new
  from ins join incoming i on i.e ->> 'uid' = ins.uid;

  for r in select value as e from jsonb_array_elements(v_new) loop
    v_inserted := v_inserted + 1;
    v_last := greatest(v_last, (r.e ->> 'time')::timestamptz);
    v_first := least(v_first, (r.e ->> 'time')::timestamptz);
    if r.e ->> 'head' is not null then
      if v_head is not null and (r.e ->> 'prev') is distinct from v_head then
        v_gaps := v_gaps + 1;
        insert into public.chain_findings (org_id, machine_id, kind, expected, got, detail)
        values (m.org_id, m.id, 'gap', v_head, r.e ->> 'prev', 'forwarded event does not continue the last chain head');
      end if;
      v_head := r.e ->> 'head';
    end if;
  end loop;

  -- rvd writes each deny to both blocks.jsonl and the chained audit.jsonl.
  -- rv drops the blocks copy within one batch; across batches both can
  -- arrive. Keep the chained copy, matching rv's key: kind, whole second,
  -- rule and host (AuditLedger.droppingLedgerDuplicates).
  if v_inserted > 0 then
    delete from public.events b
    using public.events a
    where b.machine_id = m.id and a.machine_id = m.id
      and b.source = 'blocks.jsonl' and a.source = 'audit.jsonl'
      and b.kind in ('command.denied', 'command.observed') and a.kind = b.kind
      and date_trunc('second', a.time) = date_trunc('second', b.time)
      and a.subject = b.subject
      and coalesce(a.host, '') = coalesce(b.host, '')
      and b.time >= v_first - interval '1 second' and b.time <= v_last + interval '1 second';
  end if;

  update public.machines set
    chain_head = v_head,
    chain_status = case
      when v_gaps > 0 then 'gap'::public.chain_status
      when chain_status = 'unknown' and v_head is not null then 'ok'::public.chain_status
      else chain_status
    end,
    last_event_at = greatest(last_event_at, v_last),
    last_seen_at = now()
  where id = m.id;

  inserted := v_inserted;
  duplicates := v_total - v_inserted;
  gaps := v_gaps;
  return next;
end
$$;

-- Delete events and reports past each org's retention, and old rate-limit windows.
create function public.prune_expired()
returns table (events_deleted bigint, reports_deleted bigint)
language plpgsql security definer set search_path = ''
as $$
declare
  v_events bigint;
  v_reports bigint;
begin
  delete from public.events e using public.orgs o
  where e.org_id = o.id and e.received_at < now() - make_interval(days => o.retention_days);
  get diagnostics v_events = row_count;
  -- Keep each machine's latest report regardless of age.
  delete from public.reports r using public.orgs o
  where r.org_id = o.id and r.received_at < now() - make_interval(days => o.retention_days)
    and r.id <> (select max(id) from public.reports r2 where r2.machine_id = r.machine_id);
  get diagnostics v_reports = row_count;
  delete from public.rate_limits where window_start < now() - interval '1 day';
  events_deleted := v_events;
  reports_deleted := v_reports;
  return next;
end
$$;

-- ---------------------------------------------------------------------------
-- Function privileges

revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.is_org_member(uuid) to authenticated;
grant execute on function public.has_org_role(uuid, public.org_role[]) to authenticated;
grant execute on function public.create_org(text, text) to authenticated;
grant execute on function public.accept_invites() to authenticated;
grant execute on function public.org_member_list(uuid) to authenticated;
grant execute on function public.org_admin_audit(uuid, integer) to authenticated;
grant execute on function public.org_daily_activity(uuid, integer) to authenticated;
grant execute on function public.org_top_rules(uuid, text, timestamptz, integer, text) to authenticated;
grant execute on function public.org_override_counts(uuid, timestamptz) to authenticated;
grant execute on function public.org_observed_by_host(uuid, timestamptz) to authenticated;

grant execute on function public.enroll_machine(text, text, text, text, text, text) to service_role;
grant execute on function public.ingest_report(uuid, jsonb, boolean) to service_role;
grant execute on function public.ingest_events(uuid, jsonb) to service_role;
grant execute on function public.prune_expired() to service_role;
grant execute on function public.take_rate_limit(text, integer, integer) to service_role;

-- New functions are not executable by default.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
