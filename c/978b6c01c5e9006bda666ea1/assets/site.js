(function () {
  var toggle = document.querySelector(".menu-toggle");
  var nav = document.getElementById("nav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
      toggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
    });
  }

  var here = location.pathname.split("/").pop() || "index.html";
  document.querySelectorAll(".nav a").forEach(function (a) {
    if (a.getAttribute("href") === here) a.setAttribute("aria-current", "page");
  });

  document.querySelectorAll("[data-year]").forEach(function (el) {
    el.textContent = new Date().getFullYear();
  });

  // Contact form: no backend yet, so hand the message to the visitor's mail app.
  var form = document.getElementById("contact-form");
  if (form) {
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var d = new FormData(form);
      var lines = [
        "Name: " + d.get("name"),
        "Organization: " + d.get("org"),
        "Email: " + d.get("email"),
        "Phone: " + d.get("phone"),
        "Programs: " + d.get("care"),
        "",
        d.get("message")
      ];
      location.href =
        "mailto:info@clearstreambilling.com?subject=" +
        encodeURIComponent("Billing inquiry from " + d.get("org")) +
        "&body=" + encodeURIComponent(lines.join("\n"));
    });
  }
})();

(function () {
  document.documentElement.classList.add("js");
  var els = document.querySelectorAll("[data-reveal]");
  if (!("IntersectionObserver" in window)) {
    els.forEach(function (el) { el.classList.add("in"); });
    return;
  }
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
    });
  }, { rootMargin: "0px 0px -8% 0px" });
  els.forEach(function (el) { io.observe(el); });
})();
