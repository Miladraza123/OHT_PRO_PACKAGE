-- Where each client's nightly backup is emailed (defaults to nothing -> owner_email is used).
alter table organizations add column if not exists backup_email text;

create or replace function sa_set_backup_email(p_org uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _sa_guard();
  update organizations set backup_email = nullif(btrim(p_email), '') where id = p_org;
  insert into platform_audit (admin_id, action, org_id, detail)
    values (auth.uid(), 'set_backup_email', p_org, jsonb_build_object('email', nullif(btrim(p_email), '')));
end; $$;

-- _org_json now also returns backup_email (same body as 0061 plus that key)
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
    'owner_name', o.owner_name, 'owner_phone', o.owner_phone, 'owner_email', o.owner_email, 'backup_email', o.backup_email, 'notes', o.notes,
    'created_at', o.created_at, 'usage', _org_usage(o.id))
  from organizations o join plans p on p.code = o.plan_code where o.id = p_org;
$$;

revoke all on function sa_set_backup_email(uuid, text) from public, anon;
grant execute on function sa_set_backup_email(uuid, text) to authenticated;
revoke all on function _org_json(uuid) from public, anon, authenticated;
