// Website analytics for gatehousestrategic.com, after koshercru.com's beacon.
// One page view per page shown, then how long it was on screen when the
// visitor leaves, plus contact actions. No cookies, no storage. Not counted:
// browsers sending Global Privacy Control, automated browsers, and this
// browser while it is signed in to /admin. See supabase/site-analytics.sql.
(function () {
  var URL_ = "https://hlohdnjxemwpnnkxnhqx.supabase.co/rest/v1/rpc/";
  var KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb2hkbmp4ZW13cG5ua3huaHF4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIxMzU5NzYsImV4cCI6MjA5NzcxMTk3Nn0.WcwZ3VpLwwo4aDUMyrz4pwQBN1jBkKQrLBLp7mKFA-U";

  function adminHere() {
    try { return !!localStorage.getItem("sb-hlohdnjxemwpnnkxnhqx-auth-token"); } catch (e) { return false; }
  }
  if (navigator.webdriver || navigator.globalPrivacyControl === true || adminHere()) {
    window.ghTrack = function () {};
    return;
  }

  function call(fn, args) {
    try {
      fetch(URL_ + fn, {
        method: "POST",
        keepalive: true,
        headers: { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" },
        body: JSON.stringify(args)
      }).catch(function () {});
    } catch (e) {}
  }

  function refHost() {
    try {
      if (!document.referrer) return null;
      var u = new URL(document.referrer);
      if (u.protocol !== "http:" && u.protocol !== "https:") return null;
      var h = u.hostname.toLowerCase().replace(/^www\./, "");
      return h && h !== location.hostname.toLowerCase().replace(/^www\./, "") ? h : null;
    } catch (e) { return null; }
  }

  var q = new URLSearchParams(location.search);
  var key = Array.from(crypto.getRandomValues(new Uint8Array(12)), function (b) { return b.toString(36).padStart(2, "0"); }).join("").slice(0, 20);
  var tz = null;
  try { tz = Intl.DateTimeFormat().resolvedOptions().timeZone || null; } catch (e) {}

  call("gh_track_view", {
    p_path: location.pathname,
    p_referrer: refHost(),
    p_utm_source: q.get("utm_source"),
    p_utm_campaign: q.get("utm_campaign"),
    p_key: key,
    p_tz: tz
  });

  // Time on screen: counted only while the tab is visible, sent on leaving.
  var visibleMs = 0, since = document.visibilityState === "visible" ? Date.now() : null, flushed = false;
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") {
      if (since !== null) visibleMs += Date.now() - since;
      since = null;
    } else if (since === null) since = Date.now();
  });
  window.addEventListener("pagehide", function () {
    if (flushed) return;
    var ms = visibleMs + (since !== null ? Date.now() - since : 0);
    flushed = true;
    if (ms >= 1000) call("gh_track_time", { p_key: key, p_seconds: Math.round(ms / 1000) });
  });

  // Contact actions: "contact_form" is sent by the page's form; email links here.
  window.ghTrack = function (action) { call("gh_track_action", { p_action: action, p_path: location.pathname }); };
  document.addEventListener("click", function (e) {
    var a = e.target && e.target.closest && e.target.closest('a[href^="mailto:"]');
    if (a) window.ghTrack("contact_email");
  }, true);
})();
