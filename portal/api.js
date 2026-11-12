// Gatehouse client portal: talks to the gridaudit Supabase project.
// This is the project's public key; the database rules (supabase/portal.sql)
// decide what it can do: try a code, and read one client's items with a session.
window.GH_PORTAL = (function () {
  var URL_ = "https://hlohdnjxemwpnnkxnhqx.supabase.co";
  var KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb2hkbmp4ZW13cG5ua3huaHF4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIxMzU5NzYsImV4cCI6MjA5NzcxMTk3Nn0.WcwZ3VpLwwo4aDUMyrz4pwQBN1jBkKQrLBLp7mKFA-U";
  var STORE = "gh_portal_session";

  // If this browser is also signed in to /admin, return that sign-in so a
  // code login from here is recorded as Gatehouse's own, not the client's.
  function adminBearer() {
    try {
      var s = JSON.parse(localStorage.getItem("sb-hlohdnjxemwpnnkxnhqx-auth-token") || "null");
      if (s && s.access_token && s.expires_at && s.expires_at * 1000 > Date.now() + 60000) return s.access_token;
    } catch (e) {}
    return null;
  }

  function rpc(name, args, bearer) {
    return fetch(URL_ + "/rest/v1/rpc/" + name, {
      method: "POST",
      headers: { apikey: KEY, Authorization: "Bearer " + (bearer || KEY), "Content-Type": "application/json" },
      body: JSON.stringify(args || {})
    }).then(function (r) {
      if (!r.ok) throw new Error("Request failed (" + r.status + ")");
      return r.status === 204 ? null : r.json();
    });
  }

  // Files are private. The portal-files function checks the session and
  // returns short-lived links for one item (a file, or a website preview).
  function access(token, itemId, mode) {
    return fetch(URL_ + "/functions/v1/portal-files", {
      method: "POST",
      headers: { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ token: token, item_id: itemId, mode: mode || "download" })
    }).then(function (r) { return r.json(); });
  }

  function getToken() { try { return sessionStorage.getItem(STORE); } catch (e) { return null; } }
  function setToken(t) { try { t ? sessionStorage.setItem(STORE, t) : sessionStorage.removeItem(STORE); } catch (e) {} }

  return { url: URL_, key: KEY, rpc: rpc, adminBearer: adminBearer, access: access, getToken: getToken, setToken: setToken };
})();
