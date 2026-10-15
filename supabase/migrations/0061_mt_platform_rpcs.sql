-- ==========================================================
-- OHT Accounting System (PRO) — multi-tenant (4/6): superadmin + owner RPCs
--   my_context()          : everything the app shell needs after login
--   sa_* functions        : superadmin only (plans, organizations, payments, support mode)
--   organizations_seed    : every new organization gets Period Lock row,
--                           a default firm and a default warehouse
-- ==========================================================

alter table app_users add column if not exists tour_seen_at timestamptz;

create or replace function organizations_seed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into period_lock (org_id, id, locked_before) values (new.id, 1, null) on conflict do nothing;
  insert into companies (org_id, name, is_default) values (new.id, new.name, true);
  insert into warehouses (org_id, name, is_default) values (new.id, 'Main Warehouse', true);
  return new;
end; $$;
create trigger organizations_seed_trg after insert on organizations for each row execute function organizations_seed();

create or replace function _sa_guard() returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then
    raise exception 'permission denied: platform admin only' using errcode = '42501';
  end if;
end; $$;

create or replace function _org_usage(p_org uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'users',      (select count(*) from app_users where org_id = p_org and is_active),
    'firms',      (select count(*) from companies where org_id = p_org and deleted_at is null),
    'warehouses', (select count(*) from warehouses where org_id = p_org and deleted_at is null));
$$;

create or replace function _org_json(p_org uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', o.id, 'name', o.name, 'status', o.status,
    'plan_code', o.plan_code, 'plan_name', p.name,
    'max_users', p.max_users, 'max_firms', p.max_firms, 'max_warehouses', p.max_warehouses,
    'plan_started_on', o.plan_started_on, 'plan_expires_on', o.plan_expires_on,
    'days_left', case when o.plan_expires_on is null then null else o.plan_expires_on - current_date end,
    'expired', (o.plan_expires_on is not null and o.plan_expires_on < current_date),
    'writable', (o.status = 'active' and (o.plan_expires_on is null or o.plan_expires_on >= current_date)),
    'owner_name', o.owner_name, 'owner_phone', o.owner_phone, 'owner_email', o.owner_email, 'notes', o.notes,
    'created_at', o.created_at, 'usage', _org_usage(o.id))
  from organizations o join plans p on p.code = o.plan_code where o.id = p_org;
$$;

-- context for the logged-in session (works for owners, employees and superadmins)
create or replace function my_context()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_pa platform_admins; v_au app_users; v_org uuid;
begin
  select * into v_pa from platform_admins where user_id = auth.uid();
  if found then
    return jsonb_build_object('role', 'superadmin', 'uid', auth.uid(),
      'support_org_id', v_pa.support_org_id,
      'org', case when v_pa.support_org_id is null then null else _org_json(v_pa.support_org_id) end);
  end if;
  select * into v_au from app_users where id = auth.uid();
  if not found or v_au.org_id is null then
    return jsonb_build_object('role', 'none', 'uid', auth.uid());
  end if;
  return jsonb_build_object('role', case when v_au.is_owner then 'owner' else 'employee' end, 'uid', auth.uid(),
    'user', jsonb_build_object('username', v_au.username, 'is_admin', v_au.is_admin, 'is_owner', v_au.is_owner,
                               'is_active', v_au.is_active, 'perms', v_au.perms, 'tour_seen_at', v_au.tour_seen_at),
    'org', _org_json(v_au.org_id));
end; $$;

create or replace function mark_tour_seen()
returns void language sql security definer set search_path = public as $$
  update app_users set tour_seen_at = now() where id = auth.uid() and tour_seen_at is null;
$$;
create or replace function reset_tour()
returns void language sql security definer set search_path = public as $$
  update app_users set tour_seen_at = null where id = auth.uid();
$$;

-- ---------- superadmin ----------
create or replace function sa_list_orgs()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform _sa_guard();
  return coalesce((select jsonb_agg(_org_json(o.id) order by o.created_at desc) from organizations o), '[]'::jsonb);
end; $$;

create or replace function sa_org_users(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform _sa_guard();
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'username', a.username, 'email', u.email,
            'is_owner', a.is_owner, 'is_admin', a.is_admin, 'is_active', a.is_active, 'created_at', a.created_at)
            order by a.is_owner desc, a.created_at)
          from app_users a join auth.users u on u.id = a.id where a.org_id = p_org), '[]'::jsonb);
end; $$;

create or replace function sa_update_org(p_org uuid, p_name text, p_owner_name text, p_owner_phone text,
                                         p_owner_email text, p_notes text, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform _sa_guard();
  if p_status not in ('active', 'suspended') then raise exception 'invalid status'; end if;
  update organizations set name = coalesce(nullif(btrim(p_name), ''), name), owner_name = p_owner_name,
         owner_phone = p_owner_phone, owner_email = p_owner_email, notes = p_notes, status = p_status
   where id = p_org;
  insert into platform_audit (admin_id, action, org_id, detail)
    values (auth.uid(), 'update_org', p_org, jsonb_build_object('status', p_status));
  return _org_json(p_org);
end; $$;

-- sell / renew / change a plan (manual payment). p_expires_on = the new expiry date (null = no expiry)
create or replace function sa_set_plan(p_org uuid, p_plan_code text, p_expires_on date,
                                       p_amount numeric default 0, p_method text default null,
                                       p_reference text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_users int; v_firms int; v_wh int; p plans;
begin
  perform _sa_guard();
  select * into p from plans where code = p_plan_code;
  if not found then raise exception 'unknown plan %', p_plan_code; end if;
  select count(*) into v_users from app_users where org_id = p_org and is_active;
  select count(*) into v_firms from companies where org_id = p_org and deleted_at is null;
  select count(*) into v_wh from warehouses where org_id = p_org and deleted_at is null;
  if v_users > p.max_users or v_firms > p.max_firms or v_wh > p.max_warehouses then
    raise exception 'This organization already uses % users / % firms / % warehouses — more than the % plan allows. Ask the owner to reduce first.',
      v_users, v_firms, v_wh, p.name using errcode = '23514';
  end if;
  update organizations set plan_code = p_plan_code, plan_expires_on = p_expires_on,
         plan_started_on = current_date, status = 'active' where id = p_org;
  insert into org_payments (org_id, amount, method, reference, note, plan_code, extended_to, created_by)
    values (p_org, coalesce(p_amount, 0), p_method, p_reference, p_note, p_plan_code, p_expires_on, auth.uid());
  insert into platform_audit (admin_id, action, org_id, detail)
    values (auth.uid(), 'set_plan', p_org, jsonb_build_object('plan', p_plan_code, 'expires_on', p_expires_on, 'amount', p_amount));
  return _org_json(p_org);
end; $$;

create or replace function sa_update_plan(p_code text, p_name text, p_max_users int, p_max_firms int,
                                          p_max_warehouses int, p_price numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _sa_guard();
  update plans set name = p_name, max_users = p_max_users, max_firms = p_max_firms,
         max_warehouses = p_max_warehouses, price_pkr = coalesce(p_price, 0) where code = p_code;
  insert into platform_audit (admin_id, action, detail)
    values (auth.uid(), 'update_plan', jsonb_build_object('plan', p_code, 'users', p_max_users, 'firms', p_max_firms, 'warehouses', p_max_warehouses));
end; $$;

-- support mode: look inside an organization (read-only). p_org null = leave
create or replace function sa_set_support(p_org uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform _sa_guard();
  if p_org is not null and not exists (select 1 from organizations where id = p_org) then
    raise exception 'organization not found';
  end if;
  update platform_admins set support_org_id = p_org, support_since = case when p_org is null then null else now() end
   where user_id = auth.uid();
  insert into platform_audit (admin_id, action, org_id)
    values (auth.uid(), case when p_org is null then 'support_exit' else 'support_enter' end, p_org);
  return my_context();
end; $$;

revoke all on function _sa_guard(), _org_usage(uuid), _org_json(uuid) from public, anon, authenticated;
revoke all on function my_context(), mark_tour_seen(), reset_tour(), sa_list_orgs(), sa_org_users(uuid),
  sa_update_org(uuid,text,text,text,text,text,text), sa_set_plan(uuid,text,date,numeric,text,text,text),
  sa_update_plan(text,text,int,int,int,numeric), sa_set_support(uuid) from public, anon;
grant execute on function my_context(), mark_tour_seen(), reset_tour(), sa_list_orgs(), sa_org_users(uuid),
  sa_update_org(uuid,text,text,text,text,text,text), sa_set_plan(uuid,text,date,numeric,text,text,text),
  sa_update_plan(text,text,int,int,int,numeric), sa_set_support(uuid) to authenticated;
