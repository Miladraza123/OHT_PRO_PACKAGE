-- internal trigger / helper functions are never called directly by clients
revoke all on function mt_guard(), app_users_org_guard(), app_users_no_owner_delete(), enforce_plan_limit_firms(),
  enforce_plan_limit_warehouses(), organizations_seed(), _assert_doc_in_org(text, uuid) from public, anon, authenticated;
