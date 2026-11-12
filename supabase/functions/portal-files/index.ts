// Gatehouse client portal: hands out short-lived links to private files.
// Deployed to the gridaudit project as the Edge Function "portal-files".
//
// POST { token, item_id }
//   token   = the client's portal session (from portal_login)
//   item_id = one of that client's items
// Returns a signed link (5 minutes) for a file, or signed links (1 hour)
// for every file of a website preview. Each request is logged as item_open.
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  try {
    // mode "view" returns a link the reader pane can show; anything else downloads.
    const { token, item_id, mode } = await req.json();
    const viewing = mode === "view";
    if (typeof token !== "string" || typeof item_id !== "string") return json({ ok: false, error: "bad_request" }, 400);

    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: s } = await db.from("portal_sessions").select("client_id, code_id, admin")
      .eq("token", token).gt("expires_at", new Date().toISOString()).maybeSingle();
    if (!s) return json({ ok: false, error: "expired" }, 401);

    const { data: client } = await db.from("portal_clients").select("archived").eq("id", s.client_id).maybeSingle();
    if (!client || client.archived) return json({ ok: false, error: "expired" }, 401);

    const { data: it } = await db.from("portal_items").select("*")
      .eq("id", item_id).eq("client_id", s.client_id).maybeSingle();
    if (!it) return json({ ok: false, error: "not_found" }, 404);

    await db.from("portal_events").insert({
      kind: "item_open", client_id: s.client_id, code_id: s.code_id, item_id: it.id, admin: !!s.admin,
      detail: (it.kind === "file" ? (viewing ? "Viewed: " : "Downloaded: ") : "") + it.title,
      ip: (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || null,
      user_agent: (req.headers.get("user-agent") || "").slice(0, 300),
    });

    if (it.kind === "file") {
      const { data, error } = await db.storage.from("portal-files")
        .createSignedUrl(it.file_path, 300, viewing ? undefined : { download: it.file_name || true });
      if (error) throw error;
      return json({ ok: true, url: data.signedUrl });
    }

    if (it.kind === "site") {
      const files: string[] = JSON.parse(it.body || "[]");
      const { data, error } = await db.storage.from("portal-files")
        .createSignedUrls(files.map((f) => it.file_path + f), 3600);
      if (error) throw error;
      const map: Record<string, string> = {};
      files.forEach((f, i) => { if (data[i]?.signedUrl) map[f] = data[i].signedUrl; });
      return json({ ok: true, title: it.title, entry: it.url || "index.html", files: map });
    }

    return json({ ok: false, error: "not_a_file" }, 400);
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
