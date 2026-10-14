-- The owner login of an organization can only be changed by the owner themself
-- (never disabled / demoted / edited by another admin of the same organization).
create or replace function app_users_org_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and auth.uid() is not null then
    if new.org_id is distinct from old.org_id or new.is_owner is distinct from old.is_owner then
      raise exception 'Organization / owner can only be changed by the platform' using errcode = '42501';
    end if;
    if old.is_owner and auth.uid() <> old.id and not is_platform_admin() then
      raise exception 'Only the owner can change the owner account' using errcode = '42501';
    end if;
    if old.is_owner and (new.is_active is not true or new.is_admin is not true) then
      raise exception 'The owner account must stay active and admin' using errcode = '42501';
    end if;
  end if;
  return new;
end; $$;

create or replace function app_users_no_owner_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.is_owner and auth.uid() is not null then
    raise exception 'The owner account cannot be deleted' using errcode = '42501';
  end if;
  return old;
end; $$;
create trigger aa_app_users_no_owner_delete before delete on app_users for each row execute function app_users_no_owner_delete();
