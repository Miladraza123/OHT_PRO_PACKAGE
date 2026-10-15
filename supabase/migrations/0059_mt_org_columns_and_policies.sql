-- ==========================================================
-- OHT Accounting System (PRO) — multi-tenant (2/6): org_id on every table,
-- RESTRICTIVE row-level-security (a row is visible/changeable only inside the
-- user's own organization, and only while the plan is active), and a guard
-- trigger that (a) stamps org_id, (b) forbids moving a row to another
-- organization, (c) blocks references to another organization's rows.
-- org_id becomes NOT NULL once the old data is cleared (0063).
-- ==========================================================

create or replace function mt_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pair text; v_col text; v_tbl text; v_val uuid; v_ok boolean;
begin
  if tg_op = 'INSERT' then
    if new.org_id is null then new.org_id := current_org_id(); end if;
    if new.org_id is null then
      raise exception 'No organization for this user' using errcode = '42501';
    end if;
    if auth.uid() is not null and new.org_id is distinct from current_org_id() then
      raise exception 'Not allowed for this organization' using errcode = '42501';
    end if;
  else
    if new.org_id is distinct from old.org_id then
      raise exception 'A record cannot be moved to another organization' using errcode = '42501';
    end if;
  end if;
  if tg_nargs > 0 then
    foreach v_pair in array tg_argv loop
      v_col := split_part(v_pair, ':', 1); v_tbl := split_part(v_pair, ':', 2);
      v_val := nullif(to_jsonb(new) ->> v_col, '')::uuid;
      if v_val is null then continue; end if;
      if tg_op = 'UPDATE' and v_val is not distinct from nullif(to_jsonb(old) ->> v_col, '')::uuid then continue; end if;
      execute format('select exists (select 1 from %I where id = $1 and org_id = $2)', v_tbl) into v_ok using v_val, new.org_id;
      if not v_ok then
        raise exception 'Invalid reference (%): not part of this organization', v_col using errcode = '42501';
      end if;
    end loop;
  end if;
  return new;
end; $$;

do $mt$
declare
  -- table => list of "column:parent_table" references that must stay inside the organization
  spec jsonb := '{
   "audit_log":[], "companies":[], "party_kinds":[], "services":[], "sheets":[], "warehouses":[], "period_lock":[],
   "items":["opening_warehouse_id:warehouses"],
   "item_units":["item_id:items"], "item_specs":["item_id:items"],
   "parties":["party_kind_id:party_kinds"],
   "delivery_challans":["party_id:parties","company_id:companies","quotation_id:quotations"],
   "dc_lines":["dc_id:delivery_challans","item_id:items","warehouse_id:warehouses","quotation_line_id:quotation_lines"],
   "material_issues":["quotation_id:quotations","item_id:items","warehouse_id:warehouses","dc_id:delivery_challans"],
   "vouchers":["party_id:parties","company_id:companies"],
   "voucher_lines":["voucher_id:vouchers","item_id:items","warehouse_id:warehouses","dc_line_id:dc_lines"],
   "voucher_line_material_consumption":["voucher_line_id:voucher_lines","raw_item_id:items","warehouse_id:warehouses"],
   "sales_returns":["sale_id:vouchers","party_id:parties"],
   "sales_return_lines":["return_id:sales_returns","sale_line_id:voucher_lines","item_id:items","warehouse_id:warehouses"],
   "sales_return_material_restoration":["return_line_id:sales_return_lines","consumption_id:voucher_line_material_consumption","warehouse_id:warehouses"],
   "quotations":["party_id:parties","company_id:companies"], "quotation_lines":["quotation_id:quotations","item_id:items"],
   "purchase_orders":["party_id:parties","company_id:companies"], "po_lines":["po_id:purchase_orders","item_id:items"],
   "service_invoices":["party_id:parties","company_id:companies"], "service_invoice_lines":["invoice_id:service_invoices","service_id:services"],
   "service_quotations":["party_id:parties","company_id:companies"], "service_quotation_lines":["quotation_id:service_quotations","service_id:services"],
   "recurring_service_templates":["party_id:parties","company_id:companies"],
   "stock_transfers":["from_warehouse:warehouses","to_warehouse:warehouses"], "stock_transfer_lines":["transfer_id:stock_transfers","item_id:items"],
   "stock_adjustments":["item_id:items"],
   "sheet_rows":["sheet_id:sheets","d_party:parties","c_party:parties"],
   "item_cost_snapshot":["item_id:items"], "party_opening_balances":["party_id:parties"]
  }';
  t text; args text;
begin
  for t in select jsonb_object_keys(spec) loop
    select coalesce(string_agg(quote_literal(x), ', '), '') into args from jsonb_array_elements_text(spec -> t) x;
    execute format('alter table %I add column if not exists org_id uuid references organizations(id) default current_org_id()', t);
    execute format('create index if not exists %I on %I (org_id)', t || '_org_idx', t);
    execute format('create policy mt_sel on %I as restrictive for select to authenticated using (org_id = (select current_org_id()))', t);
    execute format('create policy mt_ins on %I as restrictive for insert to authenticated with check (org_id = (select current_org_id()) and (select org_writable()))', t);
    execute format('create policy mt_upd on %I as restrictive for update to authenticated using (org_id = (select current_org_id()) and (select org_writable())) with check (org_id = (select current_org_id()) and (select org_writable()))', t);
    execute format('create policy mt_del on %I as restrictive for delete to authenticated using (org_id = (select current_org_id()) and (select org_writable()))', t);
    execute format('create trigger aa_mt_guard before insert or update on %I for each row execute function mt_guard(%s)', t, args);
  end loop;
end $mt$;

-- app_users: a login only sees / manages people of its own organization
create policy mt_sel on app_users as restrictive for select to authenticated
  using (id = auth.uid() or org_id = (select current_org_id()));
create policy mt_ins on app_users as restrictive for insert to authenticated
  with check (org_id = (select current_org_id()) and (select org_writable()));
create policy mt_upd on app_users as restrictive for update to authenticated
  using (org_id = (select current_org_id()) and (select org_writable()))
  with check (org_id = (select current_org_id()) and (select org_writable()));
create policy mt_del on app_users as restrictive for delete to authenticated
  using (org_id = (select current_org_id()) and (select org_writable()));

create or replace function app_users_org_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and auth.uid() is not null then
    if new.org_id is distinct from old.org_id or new.is_owner is distinct from old.is_owner then
      raise exception 'Organization / owner can only be changed by the platform' using errcode = '42501';
    end if;
  end if;
  return new;
end; $$;
create trigger aa_app_users_org_guard before update on app_users for each row execute function app_users_org_guard();

-- superadmin may read the audit log of the organization it is supporting
create policy audit_log_support_select on audit_log for select to authenticated using (is_support_viewer());

-- views must honour the caller's row-level security
alter view dc_line_costs set (security_invoker = on);
