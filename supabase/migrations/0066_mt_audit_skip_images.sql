-- Firm logo / signature / stamp are big base64 pictures; they are no longer copied into the audit log
-- (copying them on every save made firm edits slow and could hit the statement timeout).
create or replace function log_audit_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := (to_jsonb(coalesce(new, old)) ->> 'org_id')::uuid;
  v_skip text[] := array['logo', 'signature', 'stamp'];
begin
  if tg_op = 'INSERT' then
    insert into audit_log(org_id, table_name, row_id, action, changed_by, new_data)
    values (v_org, tg_table_name, new.id::text, 'insert', auth.uid(), to_jsonb(new) - v_skip);
    return new;
  elsif tg_op = 'UPDATE' then
    insert into audit_log(org_id, table_name, row_id, action, changed_by, old_data, new_data)
    values (v_org, tg_table_name, new.id::text, 'update', auth.uid(), to_jsonb(old) - v_skip, to_jsonb(new) - v_skip);
    return new;
  elsif tg_op = 'DELETE' then
    insert into audit_log(org_id, table_name, row_id, action, changed_by, old_data)
    values (v_org, tg_table_name, old.id::text, 'delete', auth.uid(), to_jsonb(old) - v_skip);
    return old;
  end if;
  return null;
end; $$;
