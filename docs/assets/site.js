// Bubble's website: the moving nav, scroll reveals, the demo video's sound button, the right
// download message for the visitor's device and the latest release details.
// Runs entirely in the browser: nothing is sent anywhere, no cookies are set.
(function () {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ── Nav: always there; it tightens up once you scroll, and turns dark over dark sections.
  const shell = document.querySelector(".nav-shell");
  const darks = document.querySelectorAll(".page-head, .dark");
  function onScroll() {
    shell.classList.toggle("scrolled", window.scrollY > 24);
    const mid = 40;
    shell.classList.toggle("on-dark", [...darks].some((d) => { const r = d.getBoundingClientRect(); return r.top <= mid && r.bottom >= mid; }));
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // A soft highlight glides under the link you point at.
  const links = document.querySelector(".links");
  if (links) {
    const glide = links.querySelector(".glide");
    const place = (a) => { glide.style.left = a.offsetLeft + "px"; glide.style.width = a.offsetWidth + "px"; glide.classList.add("show"); };
    links.querySelectorAll("a").forEach((a) => a.addEventListener("mouseenter", () => place(a)));
    links.addEventListener("mouseleave", () => {
      const cur = links.querySelector('a[aria-current="page"]');
      cur ? place(cur) : glide.classList.remove("show");
    });
    const cur = links.querySelector('a[aria-current="page"]');
    if (cur) requestAnimationFrame(() => place(cur));
  }

  // Phone menu.
  const menu = document.querySelector(".menu-btn");
  if (menu) menu.addEventListener("click", () => {
    const open = shell.classList.toggle("open");
    menu.setAttribute("aria-expanded", open);
  });
  document.querySelectorAll(".drawer a").forEach((a) => a.addEventListener("click", () => shell.classList.remove("open")));

  // ── Things fade up as they come into view.
  const items = document.querySelectorAll(".reveal");
  if (reduce || !("IntersectionObserver" in window)) items.forEach((el) => el.classList.add("in"));
  else {
    const io = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
    }), { rootMargin: "0px 0px -10% 0px" });
    items.forEach((el) => io.observe(el));
  }

  // Screenshots tilt a little toward the pointer.
  if (!reduce && window.matchMedia("(pointer: fine)").matches) {
    document.querySelectorAll(".shot").forEach((s) => {
      s.addEventListener("mousemove", (e) => {
        const r = s.getBoundingClientRect();
        s.style.setProperty("--ry", ((e.clientX - r.left) / r.width - 0.5) * 6 + "deg");
        s.style.setProperty("--rx", -((e.clientY - r.top) / r.height - 0.5) * 6 + "deg");
      });
      s.addEventListener("mouseleave", () => { s.style.setProperty("--ry", "0deg"); s.style.setProperty("--rx", "0deg"); });
    });
  }

  // ── The demo video plays muted; this button turns the music on.
  const video = document.querySelector(".frame video");
  const sound = document.querySelector(".sound");
  if (video && sound) {
    if (reduce) { video.removeAttribute("autoplay"); video.pause(); video.controls = true; }
    sound.addEventListener("click", () => {
      video.muted = !video.muted;
      if (!video.muted) { video.currentTime = video.currentTime; video.play(); }
      sound.querySelector("span").textContent = video.muted ? "Sound on" : "Sound off";
    });
  }

  // ── The right download message for this device.
  const ua = navigator.userAgent || "";
  const plat = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
  let os = "other";
  if (/iPhone|iPad|iPod/.test(ua) || (/Mac/.test(plat) && navigator.maxTouchPoints > 1)) os = "ios";
  else if (/Android/.test(ua)) os = "android";
  else if (/Mac/.test(plat) || /Macintosh/.test(ua)) os = "mac";
  else if (/Win/.test(plat) || /Windows/.test(ua)) os = "windows";
  else if (/CrOS/.test(ua)) os = "chromeos";
  else if (/Linux/.test(plat) || /Linux/.test(ua)) os = "linux";
  document.querySelectorAll("[data-os]").forEach((el) => {
    const list = el.getAttribute("data-os").split(" ");
    el.hidden = !(list.includes(os) || (list.includes("not-mac") && os !== "mac"));
  });

  fetch("release.json", { cache: "no-store" })
    .then((r) => (r.ok ? r.json() : null))
    .then((rel) => {
      if (!rel) return;
      document.querySelectorAll("[data-release]").forEach((el) => {
        const key = el.getAttribute("data-release");
        if (key === "url") el.setAttribute("href", rel.url);
        else if (key === "size") el.textContent = (rel.size / 1048576).toFixed(1) + " MB";
        else if (rel[key] !== undefined) el.textContent = rel[key];
      });
      // Until a release is public, the download area shows the beta message instead.
      document.querySelectorAll("[data-available]").forEach((el) => {
        el.hidden = String(rel.available !== false) !== el.getAttribute("data-available");
      });
      document.querySelectorAll("[data-notarized]").forEach((el) => {
        el.hidden = String(rel.notarized) !== el.getAttribute("data-notarized");
      });
    })
    .catch(() => {});

  document.querySelectorAll("[data-copy]").forEach((b) => {
    b.addEventListener("click", () => {
      const t = document.querySelector(b.getAttribute("data-copy"));
      if (!t) return;
      navigator.clipboard.writeText(t.textContent.trim()).then(() => {
        const old = b.textContent;
        b.textContent = "Copied";
        setTimeout(() => (b.textContent = old), 1400);
      });
    });
  });
})();
