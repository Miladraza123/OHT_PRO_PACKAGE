-- Costing engine: events on the SAME date were replayed in random order (line_id is a random uuid),
-- so a sale entered before a same-day purchase could be costed at a different average than the
-- Delivery Challan / Material Issue of that day -> wrong COGS.
-- Within one date the order is now: purchases first, then everything that takes stock out
-- (sale, DC, material issue, adjustment, raw-material consumption), then returns / restorations.
do $m$
declare
  v_def text := pg_get_functiondef('public._recompute_item_cost_core(uuid,boolean)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
    'select * from events order by evt_date, line_id',
    'select * from events order by evt_date, (case when kind = ''purchase'' then 0 when kind in (''return'',''material_restoration'') then 2 else 1 end), line_id');
  if v_new = v_def then raise exception 'costing function text not found'; end if;
  execute v_new;
end
$m$;

-- Re-stamp every item with the corrected order. A return's cost is copied from the sale line's cost
-- (trigger sales_return_lines_stamp_cost), so touch the returns after the first pass and replay once more.
select public.recompute_item_cost(id, true) from public.items where deleted_at is null;
update public.sales_return_lines set qty = qty;
select public.recompute_item_cost(id, true) from public.items where deleted_at is null;
