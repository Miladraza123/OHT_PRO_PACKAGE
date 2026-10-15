-- ==========================================================
-- OHT Accounting System (PRO) — multi-tenant (5/6): CLEAR OLD DATA + FINALIZE
-- Run by the owner in the Supabase SQL editor (it removes data, so it is run by hand).
--
--   * removes all old business data (every table except app_users / auth users);
--   * org_id becomes NOT NULL everywhere;
--   * the "one number for the whole system" rules become "one per organization"
--     (each organization has its own S-0001, QT-0001, Period Lock, cash-book days);
--   * existing organizations receive their Period Lock row, default firm and warehouse;
--   * Recompute-all / Period-Lock snapshot clean-up become organization-scoped.
-- Everything runs in ONE transaction: if anything fails, nothing changes.
-- ==========================================================
begin;

truncate table
  audit_log, companies, dc_lines, delivery_challans, item_cost_snapshot, item_specs, item_units, items,
  material_issues, parties, party_kinds, party_opening_balances, period_lock, po_lines, purchase_orders,
  quotation_lines, quotations, recurring_service_templates, sales_return_lines,
  sales_return_material_restoration, sales_returns, service_invoice_lines, service_invoices,
  service_quotation_lines, service_quotations, services, sheet_rows, sheets, stock_adjustments,
  stock_transfer_lines, stock_transfers, voucher_line_material_consumption, voucher_lines, vouchers, warehouses;

-- old system-wide rules
drop index if exists purchase_orders_pono_unique_idx;
drop index if exists quotations_qno_unique_idx;
drop index if exists sales_returns_rno_unique_idx;
drop index if exists service_invoices_sino_unique_idx;
drop index if exists service_quotations_sqno_unique_idx;
drop index if exists stock_transfers_tno_unique_idx;
drop index if exists stock_adjustments_adjno_unique_idx;
drop index if exists vouchers_vno_unique_idx;
drop index if exists sheets_date_unique_live;
alter table delivery_challans drop constraint if exists delivery_challans_dcno_key;
alter table period_lock drop constraint if exists period_lock_pkey;
alter table period_lock drop constraint if exists period_lock_id_check;

-- org_id is mandatory on every business table
do $do$
declare t text;
begin
  for t in select unnest(array['audit_log','companies','dc_lines','delivery_challans','item_cost_snapshot','item_specs',
    'item_units','items','material_issues','parties','party_kinds','party_opening_balances','period_lock','po_lines',
    'purchase_orders','quotation_lines','quotations','recurring_service_templates','sales_return_lines',
    'sales_return_material_restoration','sales_returns','service_invoice_lines','service_invoices',
    'service_quotation_lines','service_quotations','services','sheet_rows','sheets','stock_adjustments',
    'stock_transfer_lines','stock_transfers','voucher_line_material_consumption','voucher_lines','vouchers','warehouses'])
  loop
    execute format('alter table %I alter column org_id set not null', t);
  end loop;
end $do$;

-- the same rules, now per organization
alter table period_lock add primary key (org_id);
create unique index vouchers_vno_unique_idx          on vouchers (org_id, vtype, vno) where deleted_at is null;
create unique index sales_returns_rno_unique_idx     on sales_returns (org_id, rno) where deleted_at is null;
create unique index quotations_qno_unique_idx        on quotations (org_id, qno) where deleted_at is null;
create unique index service_invoices_sino_unique_idx on service_invoices (org_id, sino) where deleted_at is null;
create unique index purchase_orders_pono_unique_idx  on purchase_orders (org_id, pono) where deleted_at is null;
create unique index stock_transfers_tno_unique_idx   on stock_transfers (org_id, tno) where deleted_at is null;
create unique index service_quotations_sqno_unique_idx on service_quotations (org_id, sqno) where deleted_at is null;
create unique index stock_adjustments_adjno_unique_idx on stock_adjustments (org_id, adjno) where deleted_at is null and adjno <> '';
create unique index sheets_date_unique_live          on sheets (org_id, sheet_date) where deleted_at is null;
alter table delivery_challans add constraint delivery_challans_org_dcno_key unique (org_id, dcno);

-- organization-scoped versions of the two functions that clear data
create or replace function period_lock_invalidate_snapshots()
returns trigger language plpgsql set search_path = public as $$
begin
  delete from item_cost_snapshot where org_id = new.org_id;
  delete from party_opening_balances where org_id = new.org_id;
  return new;
end; $$;

create or replace function recompute_all_item_costs(p_lock_date date default null)
returns void language plpgsql security definer set search_path = public as $$
declare item_row record; v_org uuid := current_org_id();
begin
  if not (is_app_admin() or has_perm('period_lock')) then
    raise exception 'permission denied: period_lock required' using errcode = '42501';
  end if;
  if v_org is null or not org_writable() then
    raise exception 'This organization is read-only (plan expired or suspended)' using errcode = '42501';
  end if;
  perform set_config('app.system_write', 'on', true);
  delete from item_cost_snapshot where org_id = v_org;
  if p_lock_date is not null then
    update period_lock set locked_before = p_lock_date where org_id = v_org;
  end if;
  for item_row in select id from items where org_id = v_org loop
    perform _recompute_item_cost_core(item_row.id, true);
  end loop;
  perform set_config('app.system_write', 'off', true);
exception when others then
  perform set_config('app.system_write', 'off', true);
  raise;
end; $$;

-- every existing organization: Period Lock row, default firm, default warehouse
insert into period_lock (org_id, id, locked_before) select id, 1, null from organizations;
insert into companies  (org_id, name, is_default) select id, name, true from organizations;
insert into warehouses (org_id, name, is_default) select id, 'Main Warehouse', true from organizations;

commit;

-- check (should show 3 organizations, each with 1 firm, 1 warehouse, 1 period-lock row):
select o.name, (select count(*) from companies c where c.org_id=o.id) firms,
       (select count(*) from warehouses w where w.org_id=o.id) warehouses,
       (select count(*) from period_lock p where p.org_id=o.id) period_lock,
       (select count(*) from app_users u where u.org_id=o.id) users
from organizations o order by o.name;
