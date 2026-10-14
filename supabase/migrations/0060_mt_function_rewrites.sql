-- ==========================================================
-- OHT Accounting System (PRO) — multi-tenant (3/6): every function that
-- used global state is made organization-aware.
--   * document numbers (S-0001 ... ) are counted per organization
--   * Period Lock is per organization
--   * default company / default warehouse are per organization
--   * reports (trial balance, aging) only read the caller's organization
--   * smart-merge / line-merge helpers verify organization + writable plan
--   * audit log stamps the organization
--   * plan limits: users, firms (companies), warehouses
-- Functions that already work by row id (cost engine triggers) keep working
-- because the guard trigger (0059) forbids cross-organization references.
-- ==========================================================

-- (period_lock_invalidate_snapshots and recompute_all_item_costs are patched in 0062, which the owner runs by hand)

-- helper that patches an existing function body; fails loudly if a pattern is not found
create or replace function pg_temp._patch(p_sig text, p_pairs text[]) returns void language plpgsql as $f$
declare d text; n text; i int;
begin
  d := pg_get_functiondef(p_sig::regprocedure);
  i := 1;
  while i < array_length(p_pairs, 1) loop
    n := replace(d, p_pairs[i], p_pairs[i + 1]);
    if n = d then raise exception 'patch pattern not found in %: %', p_sig, p_pairs[i]; end if;
    d := n; i := i + 2;
  end loop;
  execute d;
end $f$;

-- ---- 1. per-organization document numbers ----
do $do$
declare r record; d text;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.proname like 'assign\_%\_number' loop
    d := pg_get_functiondef(r.sig);
    if d like '%nextval(%' then
      execute regexp_replace(d, 'nextval\(''seq_([a-z_]+)''\)', 'next_doc_no(new.org_id, ''\1'')', 'g');
    end if;
  end loop;
end $do$;

-- ---- 2. Period Lock per organization ----
select pg_temp._patch(s, array['from period_lock where id = 1',
  'from period_lock where org_id = (coalesce(to_jsonb(new), to_jsonb(old)) ->> ''org_id'')::uuid'])
from unnest(array['check_period_lock_dc_mi()','check_period_lock_doc()','check_period_lock_line()',
                  'check_period_lock_srmr()','check_period_lock_vlmc()','check_period_lock_vouchers()']) s;

select pg_temp._patch('_recompute_item_cost_core(uuid,boolean)', array['from period_lock where id = 1',
  'from period_lock where org_id = (select org_id from items where id = p_item_id)']);

-- ---- 3. defaults per organization ----
select pg_temp._patch('companies_manage_default()', array[
  'not exists (select 1 from companies)', 'not exists (select 1 from companies where org_id = new.org_id)',
  'where id <> new.id and is_default = true', 'where id <> new.id and is_default = true and org_id = new.org_id']);
select pg_temp._patch('warehouses_manage_default()', array[
  'not exists (select 1 from warehouses)', 'not exists (select 1 from warehouses where org_id = new.org_id)',
  'where id <> new.id and is_default = true', 'where id <> new.id and is_default = true and org_id = new.org_id']);

-- ---- 4. audit log carries the organization ----
create or replace function log_audit_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_org uuid := (to_jsonb(coalesce(new, old)) ->> 'org_id')::uuid;
begin
  if tg_op = 'INSERT' then
    insert into audit_log(org_id, table_name, row_id, action, changed_by, new_data)
    values (v_org, tg_table_name, new.id::text, 'insert', auth.uid(), to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    insert into audit_log(org_id, table_name, row_id, action, changed_by, old_data, new_data)
    values (v_org, tg_table_name, new.id::text, 'update', auth.uid(), to_jsonb(old), to_jsonb(new));
    return new;
  elsif tg_op = 'DELETE' then
    insert into audit_log(org_id, table_name, row_id, action, changed_by, old_data)
    values (v_org, tg_table_name, old.id::text, 'delete', auth.uid(), to_jsonb(old));
    return old;
  end if;
  return null;
end; $$;

-- ---- 6. reports read only the caller's organization ----
select pg_temp._patch('trial_balance(date)', array[
  'is_app_admin() or has_perm(''reports_view'')', 'is_app_admin() or has_perm(''reports_view'') or is_support_viewer()',
  'where p.kind in (', 'where p.org_id = current_org_id() and p.kind in (']);
select pg_temp._patch('receivable_aging(date)', array[
  'is_app_admin() or has_perm(''reports_view'')', 'is_app_admin() or has_perm(''reports_view'') or is_support_viewer()',
  'from parties where kind in', 'from parties where org_id = current_org_id() and kind in']);
select pg_temp._patch('payable_aging(date)', array[
  'is_app_admin() or has_perm(''reports_view'')', 'is_app_admin() or has_perm(''reports_view'') or is_support_viewer()',
  'from parties where kind in', 'from parties where org_id = current_org_id() and kind in']);

-- ---- 7. line-merge / smart-merge helpers: same organization, plan writable ----
create or replace function _assert_doc_in_org(p_line_table text, p_fk_id uuid)
returns void language plpgsql stable security definer set search_path = public as $$
declare v_parent text; v_org uuid;
begin
  v_parent := case p_line_table
    when 'voucher_lines' then 'vouchers' when 'sales_return_lines' then 'sales_returns'
    when 'service_invoice_lines' then 'service_invoices' when 'stock_transfer_lines' then 'stock_transfers'
    when 'quotation_lines' then 'quotations' when 'service_quotation_lines' then 'service_quotations'
    when 'po_lines' then 'purchase_orders' when 'sheet_rows' then 'sheets' end;
  if v_parent is null then
    raise exception 'line table % is not allowed', p_line_table using errcode = '42501';
  end if;
  execute format('select org_id from %I where id = $1', v_parent) into v_org using p_fk_id;
  if v_org is not null and v_org is distinct from current_org_id() then
    raise exception 'permission denied: document belongs to another organization' using errcode = '42501';
  end if;
end; $$;

select pg_temp._patch('_line_table_edit_allowed(text,uuid)', array[
  E'  if not is_active_app_user() then', E'  perform _assert_doc_in_org(p_line_table, p_fk_id);\n  if not org_writable() then\n    raise exception ''This organization is read-only (plan expired, suspended or support mode)'' using errcode = ''42501'';\n  end if;\n  if not is_active_app_user() then',
  'from period_lock where id = 1', 'from period_lock where org_id = current_org_id()']);

select pg_temp._patch('smart_merge_lines(text,text,uuid,jsonb,jsonb,text[])', array[
  E'  if not (p_line_table = any (_smart_merge_allowed_line_tables())) then',
  E'  perform _assert_doc_in_org(p_line_table, p_fk_id);\n  if not (p_line_table = any (_smart_merge_allowed_line_tables())) then']);

select pg_temp._patch('smart_merge_update(text,uuid,jsonb,jsonb,text[])', array[
  E'  if not (p_table = any (_smart_merge_allowed_tables())) then',
  E'  if not org_writable() then\n    raise exception ''This organization is read-only (plan expired, suspended or support mode)'' using errcode = ''42501'';\n  end if;\n  if not (p_table = any (_smart_merge_allowed_tables())) then',
  'from %I t where id = $1 for update', 'from %I t where id = $1 and org_id = current_org_id() for update',
  'where id = $2'', p_table', 'where id = $2 and org_id = current_org_id()'', p_table',
  'select to_jsonb(t) from %I t where id = $1'', p_table) into v_current using p_id;', 'select to_jsonb(t) from %I t where id = $1 and org_id = current_org_id()'', p_table) into v_current using p_id;']);

-- ---- 8. plan limits ----
create or replace function enforce_active_user_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_count integer; v_max integer; v_plan text;
begin
  if new.is_active and new.org_id is not null then
    select p.max_users, p.name into v_max, v_plan
      from organizations o join plans p on p.code = o.plan_code where o.id = new.org_id;
    select count(*) into v_count from app_users where is_active = true and org_id = new.org_id and id <> new.id;
    if v_count >= coalesce(v_max, 0) then
      raise exception 'Your % plan allows % active users — deactivate someone first, or ask for a plan upgrade.', v_plan, v_max
        using errcode = '23514';
    end if;
  end if;
  return new;
end; $$;

create or replace function enforce_plan_limit_firms()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_count integer; v_max integer; v_plan text;
begin
  if new.deleted_at is null and (tg_op = 'INSERT' or old.deleted_at is not null) then
    select p.max_firms, p.name into v_max, v_plan
      from organizations o join plans p on p.code = o.plan_code where o.id = new.org_id;
    select count(*) into v_count from companies where org_id = new.org_id and deleted_at is null and id <> new.id;
    if v_count >= coalesce(v_max, 0) then
      raise exception 'Your % plan allows % firm(s) — upgrade the plan to add more.', v_plan, v_max using errcode = '23514';
    end if;
  end if;
  return new;
end; $$;
create trigger companies_plan_limit before insert or update on companies for each row execute function enforce_plan_limit_firms();

create or replace function enforce_plan_limit_warehouses()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_count integer; v_max integer; v_plan text;
begin
  if new.deleted_at is null and (tg_op = 'INSERT' or old.deleted_at is not null) then
    select p.max_warehouses, p.name into v_max, v_plan
      from organizations o join plans p on p.code = o.plan_code where o.id = new.org_id;
    select count(*) into v_count from warehouses where org_id = new.org_id and deleted_at is null and id <> new.id;
    if v_count >= coalesce(v_max, 0) then
      raise exception 'Your % plan allows % warehouse(s) — upgrade the plan to add more.', v_plan, v_max using errcode = '23514';
    end if;
  end if;
  return new;
end; $$;
create trigger warehouses_plan_limit before insert or update on warehouses for each row execute function enforce_plan_limit_warehouses();
