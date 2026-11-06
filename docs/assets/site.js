// The site's behaviour: theme, the top-of-page scrollbar state, reveal, and the small conveniences a
// reader expects. No framework, no build step.

(() => {
  "use strict";

  const root = document.documentElement;

  /* ---------------------------------------------------------------- theme */

  // The page opens on the system setting, and the toggle is a light/dark switch for this visit
  // only: nothing is stored, so a reload hands the decision back to the system.
  const PAPER = { light: "#fbfaf6", dark: "#12100d" };
  const media = matchMedia("(prefers-color-scheme: dark)");

  const current = () => root.getAttribute("data-theme") || (media.matches ? "dark" : "light");

  const paint = () => {
    const dark = current() === "dark";
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", dark ? PAPER.dark : PAPER.light);
    for (const btn of document.querySelectorAll(".theme-toggle")) {
      btn.setAttribute("aria-label", dark ? "Switch to light" : "Switch to dark");
      btn.setAttribute("data-tip", dark ? "Light" : "Dark");
    }
  };

  for (const btn of document.querySelectorAll(".theme-toggle")) {
    btn.addEventListener("click", () => {
      root.setAttribute("data-theme", current() === "dark" ? "light" : "dark");
      paint();
    });
  }

  media.addEventListener("change", () => {
    if (!root.hasAttribute("data-theme")) paint();
  });

  paint();

  /* ------------------------------------------------------------- scrollbar */

  // The page scrollbar is the position indicator. Its thumb is transparent while the page sits at
  // the top and appears once the reader moves, which is the one place this site hides it.
  const markTop = () => {
    root.classList.toggle("at-top", window.scrollY <= 0);
    const max = document.documentElement.scrollHeight - window.innerHeight;
    const p = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
    root.style.setProperty("--progress", p.toFixed(4));
  };
  window.addEventListener("scroll", markTop, { passive: true });
  window.addEventListener("resize", markTop, { passive: true });
  markTop();

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

  let ticking = false;
  window.addEventListener(
    "scroll",
    () => {
      if (ticking) return;
      ticking = true;
      requestAnimationFrame(() => {
        ticking = false;
        spy();
      });
    },
    { passive: true }
  );

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
        { rootMargin: "-6% 0px -10% 0px", threshold: 0.04 }
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

  spy();
})();
