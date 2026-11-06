// The star page: pick an agent, send it a line, read the frames.
//
// The frames are not written here. They come from the library compiled to JavaScript
// (engine/a2a.js), so what the page shows is what the protocol encodes.

(async () => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const title = $("ex-title");
  const role = $("ex-role");
  const desc = $("ex-desc");
  const frames = $("frames");
  const cardJson = $("card-json");
  const cardPanel = $("card-panel");
  const composer = $("composer");
  const say = $("say");
  const mapState = $("map-state");
  const engineState = $("engine-state");
  const statesEl = $("states");

  if (!frames) return;

  let api = null;
  try {
    api = await import("../engine/a2a.js");
  } catch (err) {
    engineState.textContent = "engine not built";
    if (statesEl) statesEl.textContent = "";
    frames.innerHTML =
      '<p class="load-note">The demo engine is built by the documentation workflow into ' +
      '<code>docs/engine/</code>. Run <code>moon build --target js --release src/examples/browser</code> ' +
      "and copy the result there to try it locally.</p>";
    return;
  }

  engineState.textContent = "engine: moona2a on JS";

  const SEP = "\u001e";
  const FIELD = "\u001f";

  const agents = api
    .agents()
    .split(SEP)
    .map((row) => {
      const [id, name, kind, skill, about, tags, streaming, push] = row.split(FIELD);
      return { id, name, kind, skill, about, tags: tags.split(","), streaming: streaming === "1", push: push === "1" };
    });

  const byId = Object.fromEntries(agents.map((a) => [a.id, a]));
  const hive = window.hive;

  const labels = {
    request: "call",
    reply: "reply",
    event: "event",
    error: "refusal",
  };

  function renderFrames(id, text) {
    const raw = api.trace(id, text);
    if (!raw) {
      frames.innerHTML = "";
      return;
    }
    const records = raw.split(SEP).map((r) => {
      const at = r.indexOf(FIELD);
      return { kind: r.slice(0, at), json: r.slice(at + 1) };
    });

    frames.innerHTML = "";
    let n = 0;
    records.forEach((rec, i) => {
      if (rec.kind === "event") n += 1;
      const el = document.createElement("article");
      el.className = "frame " + rec.kind;
      el.style.animationDelay = i * 80 + "ms";
      const caption =
        rec.kind === "event" ? `event ${n}` : labels[rec.kind] || rec.kind;
      el.innerHTML =
        `<div class="fhead"><span class="kind-tag">${rec.kind}</span><span>${caption}</span></div>` +
        `<pre><code>${hive.json(rec.json)}</code></pre>`;
      frames.append(el);
    });
  }

  function select(id) {
    const agent = byId[id];
    if (!agent) return;

    for (const node of document.querySelectorAll(".node-btn")) {
      node.setAttribute("aria-pressed", String(node.dataset.agent === id));
    }
    for (const edge of document.querySelectorAll(".edge")) {
      edge.classList.toggle("lit", id === "convener" || edge.dataset.agent === id);
    }

    title.textContent = agent.name;
    role.textContent = agent.kind + " · " + agent.skill;
    desc.textContent = agent.about;
    mapState.textContent = agent.kind + " · " + agent.skill;

    renderFrames(id, say.value || "hello");
    cardJson.innerHTML = hive.json(api.card(id));
    cardPanel.open = false;

    history.replaceState(null, "", "#" + id);
  }

  for (const node of document.querySelectorAll(".node-btn")) {
    node.addEventListener("click", () => select(node.dataset.agent));
    node.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        select(node.dataset.agent);
      }
    });
  }

  composer.addEventListener("submit", (e) => {
    e.preventDefault();
    const current = document.querySelector('.node-btn[aria-pressed="true"]');
    select(current ? current.dataset.agent : "convener");
  });

  if (statesEl) {
    statesEl.innerHTML = api
      .states()
      .split(SEP)
      .map((row) => {
        const [name, meaning] = row.split(FIELD);
        return `<div class="state"><code>${name}</code><p>${meaning}</p></div>`;
      })
      .join("");
  }

  const start = location.hash.slice(1);
  select(byId[start] ? start : "convener");
})();
