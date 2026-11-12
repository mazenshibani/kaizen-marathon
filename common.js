/* PIO Kaizen Marathon - Evaluation Portal : shared helpers */
(function () {
  "use strict";

  var cfg = window.KZ_CONFIG || {};
  var URL_ = String(cfg.SUPABASE_URL || "").replace(/\/+$/, "");
  var KEY = String(cfg.SUPABASE_KEY || "");

  var MESSAGES = {
    KZ_SESSION: "Your session has ended. Please sign in again.",
    KZ_FORBIDDEN: "This account is not allowed to do that.",
    KZ_JUDGING_CLOSED: "Judging is closed. Scores can no longer be changed.",
    KZ_LOCKED: "This evaluation was already submitted and is locked.",
    KZ_INCOMPLETE: "Score every criterion before submitting.",
    KZ_BAD_SCORES: "One of the scores is not valid. Each score must be a whole number from 1 to 10.",
    KZ_NO_PROJECT: "That project no longer exists. Refresh the page.",
    KZ_WEAK_PASSWORD: "The password must be 8 to 72 characters long.",
    KZ_WRONG_PASSWORD: "The current password is not correct.",
    KZ_USERNAME_TAKEN: "That username is already in use.",
    KZ_BAD_INPUT: "Please check the values you entered.",
    KZ_SELF: "You cannot disable your own account or change your own role.",
    KZ_HAS_EVALUATIONS: "This cannot be changed because evaluations already exist for it.",
    KZ_REASON_REQUIRED: "Please give a reason.",
    KZ_NOT_SUBMITTED: "That evaluation is not in a submitted state.",
    KZ_CODE_TAKEN: "A project with that code already exists.",
    KZ_SETUP_CLOSED: "Setup is already complete. Please sign in.",
    NETWORK: "Could not reach the server. Check your internet connection and try again.",
    NOT_CONFIGURED: "The portal is not connected to a database yet (config.js)."
  };

  function KzError(code, raw) {
    this.code = code;
    this.message = MESSAGES[code] || raw || "Something went wrong. Please try again.";
  }

  function isConfigured() {
    if (cfg.DEMO && window.KZ_DEMO) return true;
    return /^https:\/\/|^http:\/\/(localhost|127\.0\.0\.1)/.test(URL_) &&
      URL_.indexOf("YOUR-PROJECT-REF") === -1 && KEY && KEY.indexOf("YOUR-") !== 0;
  }

  // Calls one of the kz_* database functions.
  function rpc(fn, args) {
    if (cfg.DEMO && window.KZ_DEMO) {      // demo build only: an in-browser stand-in for the database
      return window.KZ_DEMO.rpc(fn, args || {}).then(null, function (e) { throw new KzError(e && e.code ? e.code : "SERVER"); });
    }
    if (!isConfigured()) return Promise.reject(new KzError("NOT_CONFIGURED"));
    var ctrl = new AbortController();
    var timer = setTimeout(function () { ctrl.abort(); }, 25000);
    return fetch(URL_ + "/rest/v1/rpc/" + fn, {
      method: "POST",
      headers: { "apikey": KEY, "Authorization": "Bearer " + KEY, "Content-Type": "application/json" },
      body: JSON.stringify(args || {}),
      signal: ctrl.signal
    }).then(function (res) {
      clearTimeout(timer);
      return res.text().then(function (text) {
        var data = null;
        try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
        if (res.ok) return data;
        var msg = data && data.message ? String(data.message) : "";
        var code = /^KZ_[A-Z_]+$/.test(msg) ? msg : "SERVER";
        throw new KzError(code, code === "SERVER" ? "The server rejected the request (" + res.status + "). " + msg : msg);
      });
    }, function () {
      clearTimeout(timer);
      throw new KzError("NETWORK");
    });
  }

  // ---- session (kept for this browser tab only) ----
  function sessionApi(portal) {
    var k = "kz_session_" + portal;
    return {
      get: function () {
        try {
          var s = JSON.parse(sessionStorage.getItem(k) || "null");
          if (s && s.token && new Date(s.expires_at) > new Date()) return s;
        } catch (e) { /* ignore */ }
        return null;
      },
      set: function (s) { try { sessionStorage.setItem(k, JSON.stringify(s)); } catch (e) { /* ignore */ } },
      clear: function () { try { sessionStorage.removeItem(k); } catch (e) { /* ignore */ } }
    };
  }

  // ---- small utilities ----
  function esc(v) {
    return String(v === null || v === undefined ? "" : v)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
  function num(n) { return Number(n || 0).toLocaleString("en-US"); }
  function pct(n) {
    return Number(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
  function dt(iso) {
    if (!iso) return "";
    var d = new Date(iso);
    return d.toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" }) + " " +
      d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  }
  function time(d) { return (d || new Date()).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" }); }
  function $(sel, root) { return (root || document).querySelector(sel); }
  function $all(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  // Label of a rating on a form's scale ("Very Good", "Clearly Demonstrated", ...).
  function band(form, score) {
    var sc = (form && form.scale) || [];
    for (var i = 0; i < sc.length; i++) if (score >= sc[i].from && score <= sc[i].to) return sc[i].label;
    return "";
  }

  // The criteria of one evaluation form.
  function criteriaFor(criteria, form) {
    return criteria.filter(function (c) { return c.form === form; });
  }
  // Same formula as the database: SUM(weight x rating) x 100 / (SUM(weight) x highest rating)
  function weightedTotal(criteria, scores, scaleMax) {
    var sw = 0, s = 0;
    criteria.forEach(function (c) {
      sw += Number(c.weight);
      if (scores[c.id]) s += Number(c.weight) * Number(scores[c.id]);
    });
    return sw && scaleMax ? (s * 100) / (sw * scaleMax) : 0;
  }

  // ---- toast ----
  var toastTimer = null;
  function toast(msg, kind) {
    var el = $("#toast");
    if (!el) { el = document.createElement("div"); el.id = "toast"; el.setAttribute("role", "status"); document.body.appendChild(el); }
    el.textContent = msg;
    el.className = "toast show " + (kind || "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.className = "toast"; }, kind === "error" ? 6000 : 3200);
  }

  // ---- modal ----
  // opts: {title, body (html), okText, cancelText, danger, wide, onOpen(root), onOk(root) -> false|Promise to keep open}
  function modal(opts) {
    closeModal();
    var wrap = document.createElement("div");
    wrap.className = "modal-wrap";
    wrap.id = "modalWrap";
    wrap.innerHTML =
      '<div class="modal' + (opts.wide ? " wide" : "") + '" role="dialog" aria-modal="true" aria-labelledby="modalTitle">' +
      '<div class="modal-head"><h2 id="modalTitle">' + esc(opts.title) + '</h2>' +
      '<button type="button" class="icon-btn" data-modal-close aria-label="Close">&times;</button></div>' +
      '<div class="modal-body">' + (opts.body || "") + '</div>' +
      '<div class="modal-foot"><span class="modal-error" id="modalError"></span>' +
      (opts.cancelText === null ? "" : '<button type="button" class="btn" data-modal-close>' + esc(opts.cancelText || "Cancel") + '</button>') +
      (opts.okText ? '<button type="button" class="btn ' + (opts.danger ? "danger" : "primary") + '" id="modalOk">' + esc(opts.okText) + '</button>' : "") +
      '</div></div>';
    document.body.appendChild(wrap);
    document.body.classList.add("modal-open");
    wrap.addEventListener("mousedown", function (e) { if (e.target === wrap) closeModal(); });
    $all("[data-modal-close]", wrap).forEach(function (b) { b.addEventListener("click", closeModal); });
    var okBtn = $("#modalOk", wrap);
    if (okBtn) {
      okBtn.addEventListener("click", function () {
        var errEl = $("#modalError", wrap);
        errEl.textContent = "";
        var out;
        try { out = opts.onOk ? opts.onOk(wrap) : true; } catch (e) { errEl.textContent = e.message; return; }
        if (out === false) return;
        if (out && typeof out.then === "function") {
          okBtn.disabled = true;
          out.then(function (r) { if (r !== false) closeModal(); else okBtn.disabled = false; },
            function (e) { okBtn.disabled = false; errEl.textContent = e.message || "Failed."; });
        } else { closeModal(); }
      });
    }
    if (opts.onOpen) opts.onOpen(wrap);
    var first = $("input, select, textarea", wrap) || okBtn;
    if (first) first.focus();
  }
  function closeModal() {
    var w = $("#modalWrap");
    if (w) w.parentNode.removeChild(w);
    document.body.classList.remove("modal-open");
  }
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") closeModal(); });

  // ---- CSV download (opens cleanly in Excel) ----
  function downloadCsv(filename, rows) {
    var csv = rows.map(function (r) {
      return r.map(function (v) {
        var s = v === null || v === undefined ? "" : String(v);
        return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
      }).join(",");
    }).join("\r\n");
    if (cfg.DEMO && window.KZ_DEMO) return window.KZ_DEMO.download(filename, csv);
    var blob = new Blob(["\uFEFF" + csv], { type: "text/csv;charset=utf-8" });
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.parentNode.removeChild(a); }, 500);
  }

  // ---- change password dialog (both portals) ----
  function changePasswordDialog(getToken) {
    modal({
      title: "Change password",
      okText: "Update password",
      body:
        '<label class="field"><span>Current password</span><input type="password" id="cpOld" autocomplete="current-password"></label>' +
        '<label class="field"><span>New password (8 characters or more)</span><input type="password" id="cpNew" autocomplete="new-password"></label>' +
        '<label class="field"><span>Repeat new password</span><input type="password" id="cpNew2" autocomplete="new-password"></label>',
      onOk: function (root) {
        var o = $("#cpOld", root).value, n = $("#cpNew", root).value, n2 = $("#cpNew2", root).value;
        if (n !== n2) throw new Error("The two new passwords do not match.");
        if (n.length < 8) throw new Error(MESSAGES.KZ_WEAK_PASSWORD);
        return rpc("kz_change_password", { p_token: getToken(), p_old: o, p_new: n })
          .then(function () { toast("Password updated."); });
      }
    });
  }

  window.KZ = {
    rpc: rpc, isConfigured: isConfigured, session: sessionApi, KzError: KzError, MESSAGES: MESSAGES,
    esc: esc, num: num, pct: pct, dt: dt, time: time, $: $, $all: $all, band: band,
    criteriaFor: criteriaFor, weightedTotal: weightedTotal,
    toast: toast, modal: modal, closeModal: closeModal, downloadCsv: downloadCsv,
    changePasswordDialog: changePasswordDialog
  };
})();
