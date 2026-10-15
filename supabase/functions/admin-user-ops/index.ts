// admin-user-ops: privileged user / organization management for
// OHT Accounting System (PRO).
//
// The app is a static HTML/JS client with only the Supabase anon key — it
// can never safely create another person's login or reset someone else's
// password (that needs the service-role key, which must never reach the
// browser). This function is the one place that key is used.
//
// Two kinds of callers (always verified from THEIR OWN token, never from
// anything the client sends):
//   * ORGANIZATION ADMIN / OWNER (app_users.is_admin, active, with an org):
//       create_user  { email, password, username, is_admin, is_active, perms }
//         -> a login inside the CALLER'S organization only (plan user-limit and
//            read-only/expired state are enforced by the database).
//       set_password { user_id, new_password }
//         -> reset a password of someone in the SAME organization.
//   * SUPERADMIN (platform_admins):
//       create_org   { org_name, plan_code, plan_expires_on, owner_name, owner_phone,
//                      owner_email, owner_password, notes, amount, method, reference }
//         -> a new organization + its owner login (owners are only ever created here).
//       sa_set_password    { user_id, new_password }
//       sa_set_user_active { user_id, is_active }
//       sa_create_user     { org_id, email, password, username, is_admin, perms }

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// The browser client calling this function runs on a different origin than
// *.supabase.co, and the request carries an Authorization header, so the
// browser sends a CORS preflight (OPTIONS) before the real POST. Every
// response — the preflight's and the real one's — needs these headers, or
// the browser blocks the request client-side before it ever reaches here
// ("Failed to send a request to the Edge Function", with no server-side
// error to show for it since the real request never went out).
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const authHeader = req.headers.get("Authorization") || "";

  // Identify the caller against their OWN token (never trust a client-sent
  // user id) via an anon-key client that forwards their Authorization header.
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: callerData, error: callerErr } = await callerClient.auth.getUser();
  if (callerErr || !callerData?.user) return json({ error: "Not signed in" }, 401);
  const callerId = callerData.user.id;

  // Service-role client for the privileged app_users check and the actual
  // privileged action — this key is only ever read server-side here.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const { data: platformRow } = await admin
    .from("platform_admins")
    .select("user_id")
    .eq("user_id", callerId)
    .maybeSingle();
  const isSuper = !!platformRow;

  const { data: callerProfile } = await admin
    .from("app_users")
    .select("is_admin, is_active, is_owner, org_id")
    .eq("id", callerId)
    .maybeSingle();
  const isOrgAdmin = !isSuper && !!callerProfile?.is_admin && !!callerProfile?.is_active && !!callerProfile?.org_id;

  const strong = (pw: unknown) => String(pw ?? "").length >= 8;

  // Is this organization allowed to change data right now?
  async function orgWritable(orgId: string): Promise<string | null> {
    const { data: o } = await admin.from("organizations").select("status, plan_expires_on").eq("id", orgId).maybeSingle();
    if (!o) return "Organization not found";
    if (o.status !== "active") return "This organization is suspended. Contact support.";
    if (o.plan_expires_on && o.plan_expires_on < new Date().toISOString().slice(0, 10)) {
      return "Your plan has expired — the account is read-only. Please renew to add or change users.";
    }
    return null;
  }

  async function makeUser(orgId: string, b: any, isOwner: boolean) {
    const { email, password, username, is_admin, is_active, perms } = b;
    if (!email || !password || !username) return json({ error: "email, password and username are required" }, 400);
    if (!strong(password)) return json({ error: "Password must be at least 8 characters" }, 400);
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email: String(email).trim(),
      password,
      email_confirm: true, // no invite-email flow — the password is handed over directly
    });
    if (createErr || !created?.user) {
      return json({ error: createErr?.message || "Could not create the sign-in account" }, 400);
    }
    const { data: profile, error: profileErr } = await admin
      .from("app_users")
      .insert({
        id: created.user.id,
        org_id: orgId,
        username: String(username).trim(),
        is_admin: isOwner ? true : !!is_admin,
        is_owner: isOwner,
        is_active: is_active !== false,
        perms: perms || {},
      })
      .select()
      .single();
    if (profileErr) {
      // roll back the orphaned sign-in so a rejected create (e.g. plan user-limit) leaves nothing behind
      await admin.auth.admin.deleteUser(created.user.id).catch(() => {});
      return json({ error: profileErr.message }, 400);
    }
    return json({ status: "ok", profile });
  }

  // ---------------- organization admin / owner ----------------
  if (body.action === "create_user") {
    if (!isOrgAdmin) return json({ error: "Admins only" }, 403);
    const blocked = await orgWritable(callerProfile!.org_id);
    if (blocked) return json({ error: blocked }, 403);
    return await makeUser(callerProfile!.org_id, body, false);
  }

  if (body.action === "set_password") {
    const { user_id, new_password } = body;
    if (!user_id || !new_password) return json({ error: "user_id and new_password are required" }, 400);
    if (!strong(new_password)) return json({ error: "Password must be at least 8 characters" }, 400);
    if (!isOrgAdmin && !isSuper) return json({ error: "Admins only" }, 403);
    if (!isSuper) {
      const { data: target } = await admin.from("app_users").select("org_id, is_owner").eq("id", user_id).maybeSingle();
      if (!target || target.org_id !== callerProfile!.org_id) return json({ error: "User not found in your organization" }, 404);
      if (target.is_owner && !callerProfile!.is_owner) return json({ error: "Only the owner can change the owner's password" }, 403);
    }
    const { error: pwErr } = await admin.auth.admin.updateUserById(user_id, { password: new_password });
    if (pwErr) return json({ error: pwErr.message }, 400);
    return json({ status: "ok" });
  }

  // ---------------- superadmin ----------------
  if (body.action === "create_org") {
    if (!isSuper) return json({ error: "Superadmin only" }, 403);
    const { org_name, plan_code, plan_expires_on, owner_name, owner_phone, owner_email, owner_password, notes, amount, method, reference } = body;
    if (!org_name || !owner_email || !owner_password) {
      return json({ error: "Business name, owner login email and owner password are required" }, 400);
    }
    if (!strong(owner_password)) return json({ error: "Password must be at least 8 characters" }, 400);
    const { data: plan } = await admin.from("plans").select("code").eq("code", plan_code || "basic").maybeSingle();
    if (!plan) return json({ error: "Unknown plan" }, 400);

    // 1) the owner's sign-in first (validates the email + password before anything else is created)
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email: String(owner_email).trim(), password: owner_password, email_confirm: true,
    });
    if (createErr || !created?.user) return json({ error: createErr?.message || "Could not create the owner login" }, 400);
    const ownerId = created.user.id;

    // 2) the organization (the database seeds Period Lock, a default firm and a default warehouse)
    const { data: org, error: orgErr } = await admin
      .from("organizations")
      .insert({
        name: String(org_name).trim(),
        plan_code: plan.code,
        plan_expires_on: plan_expires_on || null,
        owner_name: owner_name || null,
        owner_phone: owner_phone || null,
        owner_email: String(owner_email).trim(),
        notes: notes || null,
        created_by: callerId,
      })
      .select()
      .single();
    if (orgErr || !org) {
      await admin.auth.admin.deleteUser(ownerId).catch(() => {});
      return json({ error: orgErr?.message || "Could not create the organization" }, 400);
    }

    // 3) the owner profile
    const { error: profErr } = await admin.from("app_users").insert({
      id: ownerId, org_id: org.id, username: String(owner_name || String(owner_email).split("@")[0]).trim(),
      is_admin: true, is_owner: true, is_active: true, perms: {},
    });
    if (profErr) {
      await admin.auth.admin.deleteUser(ownerId).catch(() => {});
      for (const t of ["audit_log", "companies", "warehouses", "period_lock"]) {
        await admin.from(t).delete().eq("org_id", org.id);
      }
      await admin.from("organizations").delete().eq("id", org.id);
      return json({ error: profErr.message }, 400);
    }
    await admin.from("org_payments").insert({
      org_id: org.id, amount: Number(amount) || 0, method: method || null, reference: reference || null,
      note: "New organization", plan_code: plan.code, extended_to: plan_expires_on || null, created_by: callerId,
    });
    await admin.from("platform_audit").insert({ admin_id: callerId, action: "create_org", org_id: org.id, detail: { plan: plan.code } });
    return json({ status: "ok", org_id: org.id });
  }

  if (body.action === "sa_set_password") {
    if (!isSuper) return json({ error: "Superadmin only" }, 403);
    const { user_id, new_password } = body;
    if (!user_id || !strong(new_password)) return json({ error: "user_id and a password of 8+ characters are required" }, 400);
    const { error: pwErr } = await admin.auth.admin.updateUserById(user_id, { password: new_password });
    if (pwErr) return json({ error: pwErr.message }, 400);
    await admin.from("platform_audit").insert({ admin_id: callerId, action: "set_password", detail: { user_id } });
    return json({ status: "ok" });
  }

  if (body.action === "sa_set_user_active") {
    if (!isSuper) return json({ error: "Superadmin only" }, 403);
    const { user_id, is_active } = body;
    if (!user_id) return json({ error: "user_id required" }, 400);
    const { error: upErr } = await admin.from("app_users").update({ is_active: !!is_active }).eq("id", user_id);
    if (upErr) return json({ error: upErr.message }, 400);
    await admin.from("platform_audit").insert({ admin_id: callerId, action: "set_user_active", detail: { user_id, is_active: !!is_active } });
    return json({ status: "ok" });
  }

  if (body.action === "sa_create_user") {
    if (!isSuper) return json({ error: "Superadmin only" }, 403);
    if (!body.org_id) return json({ error: "org_id required" }, 400);
    return await makeUser(body.org_id, body, false);
  }

  return json({ error: "Unknown action" }, 400);
});
