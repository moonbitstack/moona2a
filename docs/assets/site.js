// The site's behaviour: theme, the gauge that stands in for a scrollbar, reveal, and the small
// conveniences a reader expects. No framework, no build step.

(() => {
  "use strict";

  const root = document.documentElement;

  /* ---------------------------------------------------------------- theme */

  const KEY = "moona2a-theme";

  const apply = (mode) => {
    if (mode === "system") {
      root.removeAttribute("data-theme");
      localStorage.removeItem(KEY);
    } else {
      root.setAttribute("data-theme", mode);
      localStorage.setItem(KEY, mode);
    }
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) {
      const dark =
        mode === "dark" ||
        (mode !== "light" && matchMedia("(prefers-color-scheme: dark)").matches);
      meta.setAttribute("content", dark ? "#100e0b" : "#f4eee2");
    }
  };

  const stored = localStorage.getItem(KEY);
  if (stored === "light" || stored === "dark") apply(stored);

  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    if (!localStorage.getItem(KEY)) apply("system");
  });

  for (const btn of document.querySelectorAll(".theme-toggle")) {
    btn.addEventListener("click", () => {
      const dark =
        root.getAttribute("data-theme") === "dark" ||
        (!root.getAttribute("data-theme") &&
          matchMedia("(prefers-color-scheme: dark)").matches);
      apply(dark ? "light" : "dark");
      btn.setAttribute("aria-pressed", String(!dark));
    });
  }

  /* ---------------------------------------------------------------- gauge */

  // A hexagon at the right edge that fills with honey as the page is read. It is the position
  // indicator, and it is the way back to the top; the native scrollbar keeps its width but has no
  // thumb, so nothing jumps when it appears.
  const gauge = document.querySelector(".gauge");
  let gaugeFill = null;
  let gaugePct = null;

  if (gauge) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 46 54");
    svg.setAttribute("aria-hidden", "true");
    svg.innerHTML = `
      <defs>
        <clipPath id="gauge-clip">
          <path d="M23 1 L45 13.5 L45 40.5 L23 53 L1 40.5 L1 13.5 Z"/>
        </clipPath>
      </defs>
      <path class="cell-line" d="M23 1 L45 13.5 L45 40.5 L23 53 L1 40.5 L1 13.5 Z"/>
      <rect class="fill" x="1" y="52" width="44" height="0" clip-path="url(#gauge-clip)"/>
    `;
    gauge.prepend(svg);
    gaugeFill = svg.querySelector(".fill");
    gaugePct = gauge.querySelector(".pct");
    gauge.setAttribute("role", "button");
    gauge.setAttribute("tabindex", "0");
    gauge.setAttribute("aria-label", "Scroll position. Activate to return to the top.");
    const toTop = () => window.scrollTo({ top: 0, behavior: "smooth" });
    gauge.addEventListener("click", toTop);
    gauge.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        toTop();
      }
    });
  }

  let ticking = false;
  const paint = () => {
    ticking = false;
    if (gaugeFill) {
      const max = document.documentElement.scrollHeight - window.innerHeight;
      const p = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
      const h = 52 * p;
      gaugeFill.setAttribute("y", String(52 - h));
      gaugeFill.setAttribute("height", String(h));
      if (gaugePct) gaugePct.textContent = Math.round(p * 100) + "%";
    }
    spy();
  };

  const onScroll = () => {
    if (!ticking) {
      ticking = true;
      requestAnimationFrame(paint);
    }
  };

  window.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("resize", onScroll, { passive: true });

  /* ------------------------------------------------------------------ spy */

  const spyLinks = [...document.querySelectorAll(".toc a")];
  const spyTargets = spyLinks
    .map((a) => document.getElementById(a.getAttribute("href").slice(1)))
    .filter(Boolean);

  function spy() {
    if (!spyTargets.length) return;
    const line = window.scrollY + 120;
    let current = spyTargets[0];
    for (const el of spyTargets) {
      if (el.offsetTop <= line) current = el;
    }
    for (const a of spyLinks) {
      const on = a.getAttribute("href").slice(1) === current.id;
      if (on) a.setAttribute("aria-current", "true");
      else a.removeAttribute("aria-current");
    }
  }

  /* --------------------------------------------------------------- reveal */

  const reveals = document.querySelectorAll(".reveal");
  if (reveals.length) {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) {
      reveals.forEach((el) => el.classList.add("in"));
    } else {
      const io = new IntersectionObserver(
        (entries) => {
          for (const e of entries) {
            if (e.isIntersecting) {
              e.target.classList.add("in");
              io.unobserve(e.target);
            }
          }
        },
        { rootMargin: "-8% 0px -12% 0px", threshold: 0.05 }
      );
      reveals.forEach((el) => io.observe(el));
    }
  }

  /* --------------------------------------------------------------- tokens */

  const escape = (s) =>
    s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  // A JSON highlighter, and nothing more: keys, strings, numbers and literals. The page shows what
  // the library encoded, so the colouring must not touch the characters.
  function json(text) {
    const out = [];
    const re = /("(?:\\.|[^"\\])*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false|null)\b|([{}[\],])/g;
    let last = 0;
    let m;
    while ((m = re.exec(text))) {
      if (m.index > last) out.push(escape(text.slice(last, m.index)));
      if (m[1] !== undefined) {
        const cls = m[2] ? "tok-key" : "tok-str";
        out.push(`<span class="${cls}">${escape(m[1])}</span>`);
        if (m[2]) out.push(escape(m[2]));
      } else if (m[3] !== undefined) {
        out.push(`<span class="tok-num">${m[3]}</span>`);
      } else if (m[4] !== undefined) {
        out.push(`<span class="tok-bool">${m[4]}</span>`);
      } else if (m[5] !== undefined) {
        out.push(escape(m[5]));
      }
      last = re.lastIndex;
    }
    if (last < text.length) out.push(escape(text.slice(last)));
    return out.join("");
  }

  // MoonBit, highlighted from the text of the block: comments, strings, attributes, keywords,
  // package aliases and numbers. Nothing else is touched.
  const KEYWORDS =
    "pub fn let mut match with impl struct enum typealias trait guard else if for in while return " +
    "raise async import test suberror priv open extern const true false None Some ignore self " +
    "derive";

  function moonbit(text) {
    const re = new RegExp(
      "(//[^\\n]*)" +
        '|("(?:\\\\.|[^"\\\\])*")' +
        "|(#[^\\]\\n]*\\])" +
        "|(@[A-Za-z_]\\w*)" +
        "|\\b(" + KEYWORDS.split(" ").join("|") + ")\\b" +
        "|\\b(\\d+(?:\\.\\d+)?)\\b",
      "g"
    );
    const out = [];
    let last = 0;
    let m;
    while ((m = re.exec(text))) {
      if (m.index > last) out.push(escape(text.slice(last, m.index)));
      if (m[1]) out.push(`<span class="tok-comment">${escape(m[1])}</span>`);
      else if (m[2]) out.push(`<span class="tok-str">${escape(m[2])}</span>`);
      else if (m[3]) out.push(`<span class="tok-key">${escape(m[3])}</span>`);
      else if (m[4]) out.push(`<span class="tok-name">${escape(m[4])}</span>`);
      else if (m[5]) out.push(`<span class="tok-kw">${m[5]}</span>`);
      else if (m[6]) out.push(`<span class="tok-num">${m[6]}</span>`);
      last = re.lastIndex;
    }
    if (last < text.length) out.push(escape(text.slice(last)));
    return out.join("");
  }

  for (const code of document.querySelectorAll('pre[data-lang="moonbit"] code')) {
    code.innerHTML = moonbit(code.textContent);
  }

  window.hive = { json, escape, moonbit };

  /* ----------------------------------------------------------- code blocks */

  for (const block of document.querySelectorAll(".code-block[data-copy]")) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "copy";
    btn.textContent = "copy";
    btn.addEventListener("click", async () => {
      const pre = block.querySelector("pre");
      try {
        await navigator.clipboard.writeText(pre.innerText);
        btn.textContent = "copied";
        setTimeout(() => (btn.textContent = "copy"), 1400);
      } catch {
        btn.textContent = "select";
      }
    });
    block.querySelector(".cap")?.append(btn);
  }

  paint();
  spy();
})();
