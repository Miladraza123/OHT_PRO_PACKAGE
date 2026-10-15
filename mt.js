// mt.js — shared multi-tenant helpers for OHT Accounting System (PRO).
// Loaded by every module BEFORE its Supabase client is created.
//
//  * OHT_MT.load(sb)   -> who am I? (owner / employee / superadmin in support mode),
//                         which organization, which plan, and may I change data right now?
//  * read-only guard   -> when the plan has expired, the account is suspended, or a
//                         superadmin is only looking in (support mode), every write request
//                         is stopped here with a clear message. (The database enforces the
//                         same rule — this just makes the message friendly and keeps the
//                         offline queue from filling with changes that can never save.)
//  * OHT_MT.uid()      -> id of the signed-in user, so browser-stored data (offline queue,
//                         unsent ledger drafts) is kept per user and can never leak into
//                         another organization that signs in on the same device.
(function () {
  'use strict';

  var state = { ctx: null, readOnly: false, reason: '' };
  var READ_RPC = /^(trial_balance|receivable_aging|payable_aging|aging_reconcile|my_context|mark_tour_seen|reset_tour|sa_[a-z_]+)$/;

  var origFetch = window.fetch.bind(window);
  window.fetch = function (input, init) {
    try {
      if (state.readOnly) {
        var url = typeof input === 'string' ? input : ((input && input.url) || '');
        var method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
        if (method !== 'GET' && method !== 'HEAD' && method !== 'OPTIONS') {
          var m = /\/rest\/v1\/rpc\/([a-z_]+)/.exec(url);
          var blocked = (url.indexOf('/rest/v1/') >= 0 && !(m && READ_RPC.test(m[1]))) || url.indexOf('/functions/v1/') >= 0;
          if (blocked) {
            var msg = state.reason || 'This account is read-only.';
            return Promise.resolve(new Response(
              JSON.stringify({ code: '42501', message: msg, error: msg, details: null, hint: null }),
              { status: 403, headers: { 'Content-Type': 'application/json' } }));
          }
        }
      }
    } catch (e) { /* fall through to the real request */ }
    return origFetch(input, init);
  };

  function uid() {
    try {
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (/^sb-.*-auth-token$/.test(k)) {
          var v = JSON.parse(localStorage.getItem(k));
          var u = v && (v.user || (v.currentSession && v.currentSession.user));
          if (u && u.id) return u.id;
        }
      }
    } catch (e) {}
    return 'anon';
  }

  async function load(sb) {
    var out = { isAdmin: false, perms: {}, username: '', readOnly: false, reason: '', ctx: null, org: null, role: 'none' };
    var r;
    try { r = await sb.rpc('my_context'); } catch (e) { r = { error: e }; }
    var c = (r && r.data) || { role: 'none' };
    out.ctx = c; out.role = c.role; out.org = c.org || null;
    if (c.role === 'superadmin') {
      // support mode: look, don't touch
      out.username = 'Support';
      out.perms = { reports_view: true, material_cost_view: true };
      out.readOnly = true;
      out.reason = 'Support mode — view only. You cannot change this organization’s data.';
    } else if (c.role === 'owner' || c.role === 'employee') {
      var u = c.user || {};
      out.username = u.username || '';
      out.isAdmin = !!u.is_admin; out.perms = u.perms || {};
      if (c.org && !c.org.writable) {
        out.readOnly = true;
        out.reason = c.org.status === 'suspended'
          ? 'This account is suspended — view only. Please contact OHT Solutions.'
          : 'Your plan has expired — view only. Please renew your plan to add or change data.';
        var keep = {};
        if (out.isAdmin || out.perms.reports_view) keep.reports_view = true;
        if (out.isAdmin || out.perms.material_cost_view) keep.material_cost_view = true;
        out.isAdmin = false; out.perms = keep;
      }
    }
    state.ctx = c; state.readOnly = out.readOnly; state.reason = out.reason;
    if (out.readOnly) {
      // hide the buttons that only exist to create / change / delete (view and print stay)
      var st = document.createElement('style');
      st.textContent = '#addBtn,#newBtn,#saveBtn,#delBtn,#deleteBtn,#addLineBtn,#addUnitBtn,#addSpecBtn,#pl_save,#miAddBtn,' +
        '[id$="SaveBtn"],[id$="DeleteBtn"],[id$="AddLineBtn"],#rt_saveBtn,#rt_deleteBtn{display:none !important;}';
      document.head.appendChild(st);
      document.documentElement.classList.add('oht-ro');
    }
    return out;
  }

  window.OHT_MT = {
    uid: uid,
    load: load,
    get readOnly() { return state.readOnly; },
    get reason() { return state.reason; },
    get ctx() { return state.ctx; }
  };
})();
