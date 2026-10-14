// help.js — Help guide + first-login guided tour (Roman Urdu) for OHT Accounting System (PRO).
// Used by index.html only.
//   OHT_HELP.init({ getCtx, setDrawer, onTourDone })
//   OHT_HELP.open()        -> the Help guide (always available from the sidebar / header)
//   OHT_HELP.startTour()   -> the step-by-step tour (shown automatically on a user's first login)
(function () {
  'use strict';
  var cfg = { getCtx: function () { return null; }, setDrawer: function () {}, onTourDone: function () {} };

  function esc(s) { return (s == null ? '' : String(s)).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

  var css = document.createElement('style');
  css.textContent =
    '.hp-scrim{position:fixed;inset:0;background:rgba(20,24,31,.55);z-index:900;display:flex;align-items:flex-start;justify-content:center;padding:20px 12px;overflow-y:auto;}' +
    '.hp-box{background:var(--paper,#fff);color:var(--ink,#1F2933);border-radius:16px;max-width:760px;width:100%;box-shadow:0 20px 60px rgba(0,0,0,.35);font-family:inherit;}' +
    '.hp-head{display:flex;align-items:center;gap:10px;padding:16px 18px;border-bottom:1px solid var(--hair,#E4E7EB);position:sticky;top:0;background:var(--paper,#fff);border-radius:16px 16px 0 0;}' +
    '.hp-head h2{margin:0;font-size:17px;flex:1;}' +
    '.hp-body{padding:6px 18px 18px;}' +
    '.hp-box details{border:1px solid var(--hair,#E4E7EB);border-radius:12px;margin:10px 0;padding:0 14px;background:var(--paper,#fff);}' +
    '.hp-box summary{cursor:pointer;font-weight:700;padding:12px 0;font-size:14px;}' +
    '.hp-box details[open] summary{border-bottom:1px solid var(--hair,#E4E7EB);margin-bottom:8px;}' +
    '.hp-box p,.hp-box li{font-size:13.5px;line-height:1.6;margin:6px 0;}' +
    '.hp-box ol,.hp-box ul{padding-left:20px;margin:6px 0 12px;}' +
    '.hp-plan{background:var(--panel,#F5F0E8);border-radius:12px;padding:12px 14px;margin:12px 0;font-size:13.5px;line-height:1.7;}' +
    '.hp-btn{border:1px solid var(--line,#CBD2D9);background:var(--paper,#fff);color:var(--ink,#1F2933);border-radius:10px;padding:8px 14px;font:600 13px inherit;font-family:inherit;cursor:pointer;}' +
    '.hp-btn.pri{background:var(--accent,#A67C2E);border-color:var(--accent,#A67C2E);color:#fff;}' +
    '.tour-hl{position:relative;z-index:951 !important;outline:3px solid #D2823E;outline-offset:2px;border-radius:8px;box-shadow:0 0 0 6px rgba(210,130,62,.25);}' +
    '.tour-dim{position:fixed;inset:0;background:rgba(20,24,31,.5);z-index:950;}' +
    '.tour-card{position:fixed;z-index:960;background:var(--paper,#fff);color:var(--ink,#1F2933);border-radius:14px;padding:16px 18px;width:min(360px,calc(100vw - 24px));box-shadow:0 16px 48px rgba(0,0,0,.4);font-family:inherit;}' +
    '.tour-card h4{margin:0 0 6px;font-size:15px;} .tour-card p{margin:0 0 12px;font-size:13.5px;line-height:1.6;}' +
    '.tour-card .acts{display:flex;gap:8px;align-items:center;} .tour-card .acts .grow{flex:1;font-size:12px;color:var(--mute,#7B8794);}';
  document.head.appendChild(css);

  // ---------------------------------------------------------------- Help guide
  function sectionsHtml(ctx) {
    var org = ctx && ctx.org, isOwner = ctx && (ctx.role === 'owner');
    var planBox = '';
    if (org) {
      var u = org.usage || {};
      planBox = '<div class="hp-plan"><b>Aap ka plan: ' + esc(org.plan_name) + '</b><br>' +
        'Users: ' + u.users + ' / ' + org.max_users + ' &nbsp;·&nbsp; Firms: ' + u.firms + ' / ' + org.max_firms + ' &nbsp;·&nbsp; Warehouses: ' + u.warehouses + ' / ' + org.max_warehouses + '<br>' +
        'Plan ki akhri tareekh: <b>' + (org.plan_expires_on ? esc(org.plan_expires_on) + (org.days_left != null ? (org.days_left >= 0 ? ' (' + org.days_left + ' din baqi)' : ' (expire ho chuka)') : '') : 'koi expiry nahi') + '</b><br>' +
        (org.writable ? '' : '<span style="color:#9B2C2C"><b>Abhi aap ka account sirf-dekhne (read-only) mode mein hai.</b> Naya data likhne ke liye plan renew karwayen.</span>') + '</div>';
    }
    return planBox +
      '<details open><summary>1. Shuru kahan se karein? (pehli dafa)</summary><ol>' +
      '<li><b>Masters → Firms:</b> apni firm/company ka naam, address, phone, NTN aur logo daalein (bills par yehi chhapta hai).</li>' +
      '<li><b>Masters → Warehouses:</b> stock rakhne ki jagah (godown) banayen. Ek “Main Warehouse” pehle se maujood hai.</li>' +
      '<li><b>Masters → Parties:</b> customers aur suppliers add karein. Purana baqaya ho to “Opening balance” mein likhein.</li>' +
      '<li><b>Masters → Items:</b> maal/saman add karein — unit, sale rate, buy rate, opening stock. Services (jaise labour/repair) alag “Services” mein.</li>' +
      '<li>Ab <b>Sales &amp; Billing</b> se Sale ya Purchase ka bill banayen. Stock aur hisaab khud-ba-khud update hota hai.</li></ol></details>' +

      '<details><summary>2. Masters (Parties, Items, Services, Firms, Warehouses)</summary>' +
      '<p>Yahan wo cheezein hain jo baar-baar bills mein istemal hoti hain. Kisi record par click karke edit karein. Delete karne se record <b>Recycle Bin</b> mein chala jata hai, hamesha ke liye nahi mitta.</p>' +
      '<p><b>Items:</b> ek item ki ek se zyada units (jaise piece, dozen) aur har unit ka rate set ho sakta hai. <b>Party category:</b> party form se hi nayi category bana sakte hain.</p></details>' +

      '<details><summary>3. Sales &amp; Billing</summary><ul>' +
      '<li><b>Sale / Purchase:</b> invoice. Party chunein, items likhein, discount/tax/loading wagaira lagayen, paid amount likhein.</li>' +
      '<li><b>Quotation → Delivery Challan → Sale:</b> pehle rate quote karein, maal bhejte waqt DC banayen, phir DC se invoice.</li>' +
      '<li><b>Purchase Order:</b> supplier ko order; maal aane par Purchase bill mein badal dein.</li>' +
      '<li><b>Service Invoice / Service Quotation:</b> sirf service (bina stock) ka bill.</li>' +
      '<li><b>Sales Return:</b> wapas aaya maal — stock aur customer ka hisaab dono theek ho jate hain.</li>' +
      '<li><b>Stock Transfer:</b> ek warehouse se doosre mein maal. <b>Stock Adjustment:</b> ginti mein farq/nuqsaan theek karna (P&amp;L mein bhi nazar aata hai).</li>' +
      '<li>Har bill par <b>Print</b> ka button hai — A4 par saaf chhapta hai.</li></ul></details>' +

      '<details><summary>4. Daily Ledger (roz ka cash book)</summary>' +
      '<p>Har din ka alag page: left side “Received” (paisa aaya), right side “Paid” (paisa gaya). Party link karne se uska hisaab bhi update hota hai. “Save day” dabayen (ya auto-save ka intezar karein). Pichhle din ke arrows se purane din dekh sakte hain.</p></details>' +

      '<details><summary>5. Reports</summary><ul>' +
      '<li><b>Trial Balance:</b> sab parties ka baqaya (kis se lena, kis ko dena).</li>' +
      '<li><b>Receivable / Payable Aging:</b> udhaar kitne din purana hai.</li>' +
      '<li><b>Profit &amp; Loss:</b> munafa/nuqsaan kisi bhi tareekh ke darmiyan.</li>' +
      '<li><b>Statement of Account:</b> kisi party ka poora khata, print/PDF ke saath.</li>' +
      '<li><b>Payments Due:</b> kis ne kab tak paisa dena hai / hamein kab dena hai.</li>' +
      '<li><b>Item Stock Ledger, Material reports, Pending Deliveries:</b> stock ki harkat aur baqi DC.</li></ul></details>' +

      '<details><summary>6. Tools: Backup, Recycle Bin, Period Lock</summary><ul>' +
      '<li><b>Backup / Restore:</b> poora data file mein download karein. Waqtan-fa-waqtan backup zaroor lein.</li>' +
      '<li><b>Recycle Bin:</b> delete ki hui cheez “Restore” se wapas aati hai.</li>' +
      '<li><b>Period Lock:</b> purani tareekhon ka hisaab “lock” kar dein taake koi galti se badal na sake.</li></ul></details>' +

      (isOwner || (ctx && ctx.user && ctx.user.is_admin) ?
        '<details><summary>7. Employees (users) kaise add karein?</summary><ol>' +
        '<li><b>Account → Manage Users → + New user.</b></li>' +
        '<li>Employee ka email aur password likhein (kam az kam 8 characters) — ye aap employee ko khud batayenge.</li>' +
        '<li>Username likhein aur permissions (kya kar sakta hai) chunein. “Admin” on karne se sab ijazat mil jati hai.</li>' +
        '<li>Employee aap hi ki company ka data dekhega — kisi aur ka nahi. Aap ki plan ki limit se zyada users add nahi ho sakte.</li>' +
        '<li>Employee jab chahe <b>Account → Change Password</b> se apna password khud badal sakta hai.</li></ol></details>' : '') +

      '<details><summary>8. Password badalna</summary>' +
      '<p><b>Account → Change Password</b> mein naya password do dafa likhein (kam az kam 8 characters). Password bhool jayen to apne owner (ya OHT) se naya password banwayen.</p></details>' +

      '<details><summary>9. Plan, limits aur expiry</summary>' +
      '<p>Har plan mein users, firms aur warehouses ki limit hoti hai (Basic: 2/1/1, Standard: 5/2/3, Pro: 15/5/10). Limit poori hone par naya add nahi hota — plan upgrade karwayen.</p>' +
      '<p>Plan ki akhri tareekh guzar jaye to app <b>sirf-dekhne (read-only)</b> ho jati hai: data mehfooz rehta hai, dekh aur print kar sakte hain, lekin naya bill/entry nahi ban sakti. Renew hote hi dobara normal.</p></details>' +

      '<details><summary>10. Offline / internet na ho to?</summary>' +
      '<p>Kuch entries internet na hone par is browser mein save rehti hain aur internet aate hi khud sync ho jati hain. Browser ka “site data” clear karne se pehle sync hone dein.</p></details>' +

      '<details><summary>11. Aam sawal</summary><ul>' +
      '<li><b>“Plan expired — view only” likha aa raha hai:</b> plan renew karwayen (OHT Solutions se rabta karein).</li>' +
      '<li><b>“Your plan allows N users/firms/warehouses”:</b> limit poori ho gayi — plan upgrade karwayen ya kisi ko deactivate karein.</li>' +
      '<li><b>Nayi version nahi aa rahi:</b> upar ka ⟳ (Reload) button dabayen.</li>' +
      '<li><b>Tour dobara dekhna hai:</b> neeche “Tour dobara chalayen” dabayen.</li></ul></details>';
  }

  function open() {
    close();
    var ctx = cfg.getCtx();
    var scrim = document.createElement('div');
    scrim.className = 'hp-scrim'; scrim.id = 'hpScrim';
    scrim.innerHTML = '<div class="hp-box"><div class="hp-head"><h2>Help — OHT Accounting System (PRO)</h2>' +
      '<button type="button" class="hp-btn" id="hpTour">Tour dobara chalayen</button><button type="button" class="hp-btn pri" id="hpClose">Band karein</button></div>' +
      '<div class="hp-body">' + sectionsHtml(ctx) + '</div></div>';
    document.body.appendChild(scrim);
    scrim.addEventListener('mousedown', function (e) { if (e.target === scrim) close(); });
    document.getElementById('hpClose').addEventListener('click', close);
    document.getElementById('hpTour').addEventListener('click', function () { close(); startTour(true); });
  }
  function close() { var s = document.getElementById('hpScrim'); if (s) s.remove(); }

  // ---------------------------------------------------------------- Tour
  var STEPS = [
    { title: 'Khush aamdeed!', text: 'OHT Accounting System (PRO) mein aap ka swagat hai. Ye chhota sa tour 1 minute mein dikhayega ke har cheez kahan hai.' },
    { sel: '#sidebar .cat[data-gi="0"]', drawer: true, title: 'Masters — pehla qadam', text: 'Sab se pehle yahan se Parties (customers/suppliers), Items, Services, Firms aur Warehouses banayen. Inhi ko bills mein istemal kiya jata hai.' },
    { sel: '#sidebar .cat[data-gi="1"]', drawer: true, title: 'Sales & Billing', text: 'Sale, Purchase, Quotation, Delivery Challan, Purchase Order, Service Invoice, Sales Return, Stock Transfer aur Stock Adjustment — sab bills yahan se. Har bill print bhi hota hai.' },
    { sel: '#sidebar .navitem[data-app="ledger"]', drawer: true, title: 'Daily Ledger', text: 'Roz ka cash book: kis se kitna paisa aaya aur kis ko gaya. Party link karne se uska hisaab khud update hota hai.' },
    { sel: '#sidebar .cat[data-gi="3"]', drawer: true, title: 'Reports', text: 'Trial Balance, Aging, Profit & Loss, Statement of Account, Payments Due, Stock Ledger — poore karobar ka hisaab yahan dekhein.' },
    { sel: '#navTools', drawer: true, title: 'Tools', text: 'Backup/Restore (data ki copy), Recycle Bin (delete ki hui cheez wapas) aur Period Lock (purana hisaab lock karna).' },
    { sel: '#navAccount', drawer: true, title: 'Account', text: 'Manage Users se employees add karein (owner), Change Password se apna password badlein, aur yahin se Help bhi khulti hai.' },
    { sel: '#planChip', drawer: false, title: 'Aap ka plan', text: 'Yahan aap ka plan aur uski akhri tareekh nazar aati hai. Users/firms/warehouses ki limit Help mein likhi hai. Tareekh guzarne par app sirf-dekhne mode mein chali jati hai.' },
    { sel: '#helpBtn', drawer: false, title: 'Help hamesha maujood', text: 'Kisi bhi waqt yahan “? Help” dabayen — har screen ki wazahat Roman Urdu mein hai, aur ye tour dobara bhi chal sakta hai.' },
    { title: 'Bas! Shuru karein', text: 'Pehle Masters mein Firm, Parties aur Items daalein, phir Sale/Purchase ka bill banayen. Allah aap ke karobar mein barkat dey!' }
  ];
  var tourIdx = 0, tourEls = null, tourManual = false;

  function clearHl() { Array.prototype.forEach.call(document.querySelectorAll('.tour-hl'), function (e) { e.classList.remove('tour-hl'); }); }
  function endTour(done) {
    clearHl();
    if (tourEls) { tourEls.dim.remove(); tourEls.card.remove(); tourEls = null; }
    cfg.setDrawer(false);
    if (done !== false) cfg.onTourDone(tourManual);
  }
  function showStep(i) {
    tourIdx = i;
    var s = STEPS[i];
    clearHl();
    var target = null;
    if (s.sel) {
      if (s.drawer) cfg.setDrawer(true); else cfg.setDrawer(false);
      target = document.querySelector(s.sel);
      if (target && target.offsetParent === null && !s.drawer) target = null;
    } else { cfg.setDrawer(false); }
    if (!tourEls) {
      var dim = document.createElement('div'); dim.className = 'tour-dim';
      var card = document.createElement('div'); card.className = 'tour-card';
      document.body.appendChild(dim); document.body.appendChild(card);
      tourEls = { dim: dim, card: card };
    }
    var last = i === STEPS.length - 1;
    tourEls.card.innerHTML = '<h4>' + esc(s.title) + '</h4><p>' + esc(s.text) + '</p>' +
      '<div class="acts"><span class="grow">' + (i + 1) + ' / ' + STEPS.length + '</span>' +
      (last ? '' : '<button type="button" class="hp-btn" id="tourSkip">Skip</button>') +
      (i > 0 ? '<button type="button" class="hp-btn" id="tourPrev">Peeche</button>' : '') +
      '<button type="button" class="hp-btn pri" id="tourNext">' + (last ? 'Shuru karein' : 'Aage') + '</button></div>';
    if (target) {
      target.classList.add('tour-hl');
      try { target.scrollIntoView({ block: 'nearest' }); } catch (e) {}
    }
    var wide = window.innerWidth > 860;
    var card = tourEls.card;
    card.style.left = card.style.top = card.style.bottom = card.style.transform = '';
    if (target && wide) {
      var r = target.getBoundingClientRect();
      card.style.left = Math.min(window.innerWidth - 380, Math.max(12, r.right + 16)) + 'px';
      card.style.top = Math.max(12, Math.min(window.innerHeight - 220, r.top)) + 'px';
    } else if (target) {
      card.style.left = '50%'; card.style.transform = 'translateX(-50%)'; card.style.bottom = '14px';
    } else {
      card.style.left = '50%'; card.style.top = '50%'; card.style.transform = 'translate(-50%,-50%)';
    }
    document.getElementById('tourNext').addEventListener('click', function () { last ? endTour(true) : showStep(i + 1); });
    var p = document.getElementById('tourPrev'); if (p) p.addEventListener('click', function () { showStep(i - 1); });
    var sk = document.getElementById('tourSkip'); if (sk) sk.addEventListener('click', function () { endTour(true); });
  }
  function startTour(manual) { tourManual = !!manual; endTour(false); showStep(0); }

  window.OHT_HELP = {
    init: function (c) { cfg = Object.assign(cfg, c || {}); },
    open: open,
    startTour: startTour
  };
})();
