// Gatehouse client portal: talks to the gridaudit Supabase project.
// This is the project's public key; the database rules (supabase/portal.sql)
// decide what it can do: try a code, and read one client's items with a session.
window.GH_PORTAL = (function () {
  var URL_ = "https://hlohdnjxemwpnnkxnhqx.supabase.co";
  var KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb2hkbmp4ZW13cG5ua3huaHF4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIxMzU5NzYsImV4cCI6MjA5NzcxMTk3Nn0.WcwZ3VpLwwo4aDUMyrz4pwQBN1jBkKQrLBLp7mKFA-U";
  var STORE = "gh_portal_session";

  function rpc(name, args) {
    return fetch(URL_ + "/rest/v1/rpc/" + name, {
      method: "POST",
      headers: { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" },
      body: JSON.stringify(args || {})
    }).then(function (r) {
      if (!r.ok) throw new Error("Request failed (" + r.status + ")");
      return r.status === 204 ? null : r.json();
    });
  }

  function fileUrl(path) {
    return URL_ + "/storage/v1/object/public/portal-files/" + path.split("/").map(encodeURIComponent).join("/");
  }

  function getToken() { try { return sessionStorage.getItem(STORE); } catch (e) { return null; } }
  function setToken(t) { try { t ? sessionStorage.setItem(STORE, t) : sessionStorage.removeItem(STORE); } catch (e) {} }

  return { url: URL_, key: KEY, rpc: rpc, fileUrl: fileUrl, getToken: getToken, setToken: setToken };
})();
