// Gatehouse client portal: a reader pane for notes and files.
// Opens beside the page so files can be read without downloading.
// PDFs, images, Word (.docx), spreadsheets (.xlsx/.xls/.csv) and text files
// are shown in place; anything else offers a download.
// File content is rendered inside a sandboxed frame with scripts disabled.
window.GH_READER = (function () {
  var MAX = 25 * 1048576;
  var LIBS = {
    mammoth: "https://cdnjs.cloudflare.com/ajax/libs/mammoth/1.6.0/mammoth.browser.min.js",
    xlsx: "https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js"
  };
  var loaded = {};
  var el, body, titleEl, metaEl, dlBtn, lastFocus, objectUrl, current;

  function loadLib(name) {
    if (loaded[name]) return loaded[name];
    loaded[name] = new Promise(function (res, rej) {
      var s = document.createElement("script");
      s.src = LIBS[name]; s.onload = res; s.onerror = function () { loaded[name] = null; rej(new Error("load")); };
      document.head.appendChild(s);
    });
    return loaded[name];
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  var DOC_CSS =
    "body{margin:0;padding:40px 48px 64px;font:16px/1.65 Georgia,'Times New Roman',serif;color:#22303f;background:#fff;max-width:820px}" +
    "h1,h2,h3,h4{font-family:'Helvetica Neue',Arial,sans-serif;color:#0d2a4c;line-height:1.25;margin:1.4em 0 .5em}" +
    "h1{font-size:26px}h2{font-size:21px}h3{font-size:18px}p{margin:0 0 1em}" +
    "table{border-collapse:collapse;margin:1em 0;font:13px/1.4 'Helvetica Neue',Arial,sans-serif}" +
    "td,th{border:1px solid #d3dde8;padding:6px 9px;vertical-align:top;text-align:left}th{background:#f3f6fa}" +
    "img{max-width:100%;height:auto}a{color:#1f5f9f}" +
    "pre{white-space:pre-wrap;word-wrap:break-word;font:14px/1.6 Consolas,'Courier New',monospace;margin:0}" +
    ".sheet{font-family:'Helvetica Neue',Arial,sans-serif;font-size:13px;font-weight:600;color:#66768a;margin:28px 0 6px}" +
    ".wide{max-width:none}" +
    "@media(max-width:700px){body{padding:24px 18px 48px}}";

  function build() {
    var css = document.createElement("style");
    css.textContent =
      ".ghr-back{position:fixed;inset:0;background:rgba(13,42,76,.35);z-index:80}" +
      ".ghr{position:fixed;top:0;right:0;bottom:0;width:min(980px,78vw);background:#fff;z-index:81;display:flex;flex-direction:column;box-shadow:-18px 0 50px rgba(13,42,76,.22);font-family:'Hanken Grotesk','Helvetica Neue',Arial,sans-serif}" +
      ".ghr-h{flex:none;display:flex;align-items:center;gap:14px;padding:16px 20px;border-bottom:1px solid #d3dde8}" +
      ".ghr-t{flex:1;min-width:0}.ghr-t b{display:block;font-size:17px;color:#0d2a4c;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}" +
      ".ghr-t span{display:block;font-size:13px;color:#66768a;margin-top:2px}" +
      ".ghr-b{display:inline-flex;align-items:center;height:38px;padding:0 14px;border-radius:2px;border:1px solid #9cbde0;background:#fff;color:#0d2a4c;font:600 13.5px/1 inherit;cursor:pointer;white-space:nowrap}" +
      ".ghr-b:hover{border-color:#0d2a4c}.ghr-b.x{width:38px;justify-content:center;padding:0;font-size:20px}" +
      ".ghr-c{flex:1;min-height:0;background:#f3f6fa;display:flex;align-items:stretch;justify-content:center;overflow:auto}" +
      ".ghr-c iframe{border:0;width:100%;height:100%;background:#fff;display:block}" +
      ".ghr-c img{max-width:100%;max-height:100%;object-fit:contain;margin:auto;display:block}" +
      ".ghr-note{background:#fff;width:100%;padding:36px 44px 64px;font:17px/1.7 Spectral,Georgia,serif;color:#34465c;white-space:pre-wrap;overflow:auto}" +
      ".ghr-msg{margin:auto;padding:40px 24px;text-align:center;color:#66768a;font-size:15px;max-width:420px}" +
      ".ghr-msg .ghr-b{margin-top:16px}" +
      "@media(max-width:760px){.ghr{width:100vw}.ghr-note{padding:22px 18px 48px}}";
    document.head.appendChild(css);

    el = document.createElement("div");
    el.hidden = true;
    el.innerHTML =
      '<div class="ghr-back" data-close></div>' +
      '<section class="ghr" role="dialog" aria-modal="true" aria-label="Reader">' +
        '<div class="ghr-h"><div class="ghr-t"><b></b><span></span></div>' +
        '<button type="button" class="ghr-b" data-dl hidden>Download</button>' +
        '<button type="button" class="ghr-b x" data-close aria-label="Close">×</button></div>' +
        '<div class="ghr-c"></div>' +
      "</section>";
    document.body.appendChild(el);
    body = el.querySelector(".ghr-c");
    titleEl = el.querySelector(".ghr-t b");
    metaEl = el.querySelector(".ghr-t span");
    dlBtn = el.querySelector("[data-dl]");
    el.addEventListener("click", function (e) {
      if (e.target.closest("[data-close]")) close();
      if (e.target.closest("[data-dl]") && current && current.download) current.download();
    });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && !el.hidden) close(); });
  }

  function message(html) { body.innerHTML = '<div class="ghr-msg">' + html + "</div>"; }

  function frame(html, wide) {
    var f = document.createElement("iframe");
    f.setAttribute("sandbox", "allow-popups allow-popups-to-escape-sandbox");
    f.setAttribute("title", "Document");
    f.srcdoc = '<!doctype html><html><head><meta charset="utf-8"><base target="_blank"><style>' + DOC_CSS + "</style></head><body" + (wide ? ' class="wide"' : "") + ">" + html + "</body></html>";
    body.innerHTML = ""; body.appendChild(f);
  }

  function close() {
    if (!el || el.hidden) return;
    el.hidden = true;
    body.innerHTML = "";
    if (objectUrl) { URL.revokeObjectURL(objectUrl); objectUrl = null; }
    document.body.style.overflow = "";
    current = null;
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  function show(opts) {
    if (!el) build();
    lastFocus = document.activeElement;
    current = opts;
    titleEl.textContent = opts.title || "";
    metaEl.textContent = opts.meta || "";
    dlBtn.hidden = !opts.download;
    el.hidden = false;
    document.body.style.overflow = "hidden";
    el.querySelector("[data-close].x").focus();
  }

  // A note: plain text, shown as written.
  function openNote(opts) {
    show(opts);
    var d = document.createElement("div");
    d.className = "ghr-note";
    d.textContent = opts.body || "";
    body.innerHTML = ""; body.appendChild(d);
  }

  // A file: opts.fileName, opts.size, opts.getUrl() -> Promise<url>, opts.download()
  async function openFile(opts) {
    show(opts);
    message("Opening…");
    var ext = (String(opts.fileName || "").split(".").pop() || "").toLowerCase();
    var canShow = /^(pdf|png|jpe?g|gif|webp|svg|txt|md|csv|tsv|json|log|docx|xlsx|xls)$/.test(ext);
    if (!canShow) return message("This type of file can't be shown here." + (opts.download ? '<br><button type="button" class="ghr-b" data-dl>Download</button>' : ""));
    if (opts.size && opts.size > MAX) return message("This file is too large to show here." + (opts.download ? '<br><button type="button" class="ghr-b" data-dl>Download</button>' : ""));
    try {
      var url = await opts.getUrl();
      if (!url) throw new Error("no url");
      if (current !== opts) return;
      if (/^(png|jpe?g|gif|webp|svg)$/.test(ext)) {
        var img = document.createElement("img"); img.alt = opts.title || ""; img.src = url;
        body.innerHTML = ""; body.appendChild(img);
        return;
      }
      var res = await fetch(url);
      if (!res.ok) throw new Error("fetch");
      if (ext === "pdf") {
        var blob = new Blob([await res.arrayBuffer()], { type: "application/pdf" });
        objectUrl = URL.createObjectURL(blob);
        var f = document.createElement("iframe"); f.title = opts.title || "PDF"; f.src = objectUrl;
        body.innerHTML = ""; body.appendChild(f);
        return;
      }
      if (ext === "docx") {
        await loadLib("mammoth");
        var out = await window.mammoth.convertToHtml({ arrayBuffer: await res.arrayBuffer() });
        if (current !== opts) return;
        return frame(out.value || "<p>(This document is empty.)</p>");
      }
      if (ext === "xlsx" || ext === "xls") {
        await loadLib("xlsx");
        var wb = window.XLSX.read(new Uint8Array(await res.arrayBuffer()), { type: "array" });
        var html = wb.SheetNames.map(function (n) {
          var t = window.XLSX.utils.sheet_to_html(wb.Sheets[n], { header: "", footer: "" });
          return (wb.SheetNames.length > 1 ? '<p class="sheet">' + esc(n) + "</p>" : "") + t;
        }).join("");
        if (current !== opts) return;
        return frame(html, true);
      }
      var text = await res.text();
      if (current !== opts) return;
      if (ext === "csv" || ext === "tsv") {
        var sep = ext === "tsv" ? "\t" : ",";
        var rows = parseCsv(text, sep).slice(0, 2000);
        return frame("<table>" + rows.map(function (r, i) {
          return "<tr>" + r.map(function (c) { return (i === 0 ? "<th>" : "<td>") + esc(c) + (i === 0 ? "</th>" : "</td>"); }).join("") + "</tr>";
        }).join("") + "</table>", true);
      }
      return frame("<pre>" + esc(text) + "</pre>");
    } catch (e) {
      if (current === opts) message("This file couldn't be shown." + (opts.download ? '<br><button type="button" class="ghr-b" data-dl>Download instead</button>' : ""));
    }
  }

  function parseCsv(text, sep) {
    var rows = [], row = [], cell = "", q = false;
    for (var i = 0; i < text.length; i++) {
      var ch = text[i];
      if (q) {
        if (ch === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; }
        else cell += ch;
      } else if (ch === '"') q = true;
      else if (ch === sep) { row.push(cell); cell = ""; }
      else if (ch === "\n") { row.push(cell); rows.push(row); row = []; cell = ""; }
      else if (ch !== "\r") cell += ch;
    }
    if (cell || row.length) { row.push(cell); rows.push(row); }
    return rows;
  }

  return { openNote: openNote, openFile: openFile, close: close };
})();
