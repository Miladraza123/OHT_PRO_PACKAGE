-- ==========================================================
-- OHT Accounting System (PRO) — multi-tenant foundation (1/6)
--
-- Every customer ("owner") gets an ORGANIZATION. All business rows carry an
-- org_id and can only be seen/changed by users of that organization.
-- Superadmins live in platform_admins (outside any organization) and can
-- enter an organization in read-only "support mode".
-- This file only ADDS things (plans, organizations, helper functions).
-- ==========================================================

create table if not exists plans (
  code            text primary key,
  name            text not null,
  max_users       integer not null check (max_users > 0),
  max_firms       integer not null check (max_firms > 0),
  max_warehouses  integer not null check (max_warehouses > 0),
  price_pkr       numeric not null default 0,
  sort_order      integer not null default 0
);
insert into plans (code, name, max_users, max_firms, max_warehouses, sort_order) values
  ('basic',    'Basic',     2, 1,  1, 1),
  ('standard', 'Standard',  5, 2,  3, 2),
  ('pro',      'Pro',      15, 5, 10, 3)
on conflict (code) do nothing;

create table if not exists organizations (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (btrim(name) <> ''),
  plan_code      text not null references plans(code),
  plan_started_on date not null default current_date,
  plan_expires_on date,                       -- null = never expires
  status         text not null default 'active' check (status in ('active', 'suspended')),
  owner_name     text,
  owner_phone    text,
  owner_email    text,
  notes          text,
  created_at     timestamptz not null default now(),
  created_by     uuid
);

create table if not exists org_payments (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references organizations(id) on delete cascade,
  amount       numeric not null default 0,
  paid_on      date not null default current_date,
  method       text,
  reference    text,
  note         text,
  plan_code    text,
  extended_to  date,
  created_by   uuid,
  created_at   timestamptz not null default now()
);

create table if not exists platform_admins (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  support_org_id uuid references organizations(id) on delete set null,
  support_since  timestamptz,
  created_at     timestamptz not null default now()
);

create table if not exists platform_audit (
  id        uuid primary key default gen_random_uuid(),
  at        timestamptz not null default now(),
  admin_id  uuid,
  action    text not null,
  org_id    uuid,
  detail    jsonb
);

create table if not exists org_counters (
  org_id  uuid not null references organizations(id) on delete cascade,
  kind    text not null,
  last_no bigint not null default 0,
  primary key (org_id, kind)
);

alter table plans            enable row level security;
alter table organizations    enable row level security;
alter table org_payments     enable row level security;
alter table platform_admins  enable row level security;
alter table platform_audit   enable row level security;
alter table org_counters     enable row level security;

-- ---------- app_users: which organization a login belongs to ----------
alter table app_users add column if not exists org_id   uuid references organizations(id);
alter table app_users add column if not exists is_owner boolean not null default false;
create index if not exists app_users_org_idx on app_users (org_id);

-- ---------- identity helpers (all SECURITY DEFINER, read-only) ----------
create or replace function is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid());
$$;

create or replace function current_org_id()
returns uuid language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from platform_admins where user_id = auth.uid())
      then (select support_org_id from platform_admins where user_id = auth.uid())
    else (select org_id from app_users where id = auth.uid() and is_active)
  end;
$$;

-- superadmin currently looking inside an organization (read-only)
create or replace function is_support_viewer()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select support_org_id is not null from platform_admins where user_id = auth.uid()), false);
$$;

-- may the current session WRITE business data? (not a superadmin, org active, plan not expired)
create or replace function org_writable()
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from platform_admins where user_id = auth.uid())
     and coalesce((
       select o.status = 'active' and (o.plan_expires_on is null or o.plan_expires_on >= current_date)
       from organizations o where o.id = current_org_id()
     ), false);
$$;

create or replace function is_active_app_user()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_active and org_id is not null from app_users where id = auth.uid()), false)
      or (is_support_viewer() and current_org_id() is not null);
$$;

create or replace function is_app_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_active and is_admin and org_id is not null from app_users where id = auth.uid()), false);
$$;

create or replace function has_perm(key text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select is_active and org_id is not null and (is_admin or coalesce((perms->>key)::boolean, false))
       from app_users where id = auth.uid()),
    false);
$$;

create or replace function is_org_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_active and is_owner and org_id is not null from app_users where id = auth.uid()), false);
$$;

-- per-organization document numbers (S-0001, QT-0001 ... restart for every organization)
create or replace function next_doc_no(p_org uuid, p_kind text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if auth.uid() is not null and p_org is distinct from current_org_id() then
    raise exception 'Not allowed for this organization' using errcode = '42501';
  end if;
  insert into org_counters (org_id, kind, last_no) values (p_org, p_kind, 1)
    on conflict (org_id, kind) do update set last_no = org_counters.last_no + 1
    returning last_no into v;
  return v;
end; $$;

-- ---------- policies on the platform tables ----------
create policy plans_select on plans for select to authenticated using (true);
create policy organizations_select on organizations for select to authenticated
  using (id = current_org_id() or is_platform_admin());
create policy org_payments_select on org_payments for select to authenticated using (is_platform_admin());
create policy platform_admins_select on platform_admins for select to authenticated using (user_id = auth.uid());
create policy platform_audit_select on platform_audit for select to authenticated using (is_platform_admin());
-- org_counters: no direct access (functions only)

revoke all on function next_doc_no(uuid, text) from public, anon;
grant execute on function next_doc_no(uuid, text) to authenticated;
revoke all on function is_platform_admin(), current_org_id(), is_support_viewer(), org_writable(), is_org_owner() from public, anon;
grant execute on function is_platform_admin(), current_org_id(), is_support_viewer(), org_writable(), is_org_owner() to authenticated;
