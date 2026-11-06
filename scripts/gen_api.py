#!/usr/bin/env python3
"""Generate docs/api.html from pkg.generated.mbti and the sources' /// comments.

The output is deterministic: re-running it on the same tree produces the same
bytes, so CI can assert `git diff --exit-code docs/api.html` after a rebuild.
Only the standard library is used, and the file is written with LF endings.
"""

from __future__ import annotations

import html
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "docs" / "api.html"

DERIVED = {
    "equal": "Structural equality from `Eq`.",
    "not_equal": "The negation of `equal`, from `Eq`.",
    "compare": "Three-way ordering from `Compare`: less, equal or greater.",
    "op_lt": "`self < other`, from `Compare`.",
    "op_le": "`self <= other`, from `Compare`.",
    "op_gt": "`self > other`, from `Compare`.",
    "op_ge": "`self >= other`, from `Compare`.",
    "to_repr": "The debug representation, from `Debug`.",
    "output": "Writes the text form to a logger, from `Show`.",
    "to_string": "The text form, as a `String`, from `Show`.",
}


def esc(s: str) -> str:
    return html.escape(s, quote=False)


# --------------------------------------------------------------------------
# a small Markdown subset: paragraphs, code fences, tables, lists, headings
# --------------------------------------------------------------------------

def inline(s: str) -> str:
    spans: list[str] = []

    def stash(m: re.Match) -> str:
        spans.append("<code>" + html.escape(m.group(1), quote=False) + "</code>")
        return f"\x00{len(spans) - 1}\x00"

    s = re.sub(r"`([^`\n]+)`", stash, s)
    s = html.escape(s, quote=False)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', s)
    s = re.sub(r"\x00(\d+)\x00", lambda m: spans[int(m.group(1))], s)
    return s


def render_table(block: list[str]) -> str:
    rows = [[c.strip() for c in ln.strip().strip("|").split("|")] for ln in block]
    aligns: list[str] = []
    if len(rows) >= 2 and all(re.fullmatch(r":?-{2,}:?", c) or c == "" for c in rows[1]):
        for c in rows[1]:
            if c.startswith(":") and c.endswith(":"):
                aligns.append("center")
            elif c.endswith(":"):
                aligns.append("right")
            else:
                aligns.append("left")
        head, body = rows[0], rows[2:]
    else:
        head, body = rows[0], rows[1:]
        aligns = ["left"] * len(head)

    def cell(tag: str, text: str, i: int) -> str:
        al = aligns[i] if i < len(aligns) else "left"
        return f'<{tag} style="text-align:{al}">{inline(text)}</{tag}>'

    out = ["<table>"]
    out.append("<thead><tr>" + "".join(cell("th", t, i) for i, t in enumerate(head)) + "</tr></thead>")
    out.append("<tbody>")
    for row in body:
        out.append("<tr>" + "".join(cell("td", t, i) for i, t in enumerate(row)) + "</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def md_to_html(text: str) -> str:
    lines = text.split("\n")
    out: list[str] = []
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        stripped = line.lstrip()

        if stripped.startswith("```"):
            lang = stripped[3:].strip()
            i += 1
            buf: list[str] = []
            while i < n and not lines[i].lstrip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            cls = f' class="language-{esc(lang)}"' if lang else ""
            out.append(f"<pre><code{cls}>{esc(chr(10).join(buf))}</code></pre>")
            continue

        if stripped.startswith("|"):
            block = []
            while i < n and lines[i].lstrip().startswith("|"):
                block.append(lines[i])
                i += 1
            out.append(render_table(block))
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            lvl = min(6, len(m.group(1)) + 2)
            out.append(f"<h{lvl}>{inline(m.group(2))}</h{lvl}>")
            i += 1
            continue

        if re.match(r"^\s*([-*]|\d+\.)\s+", line):
            ordered = bool(re.match(r"^\s*\d+\.", line))
            items = []
            while i < n and re.match(r"^\s*([-*]|\d+\.)\s+", lines[i]):
                items.append(re.sub(r"^\s*([-*]|\d+\.)\s+", "", lines[i]))
                i += 1
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>" + "".join(f"<li>{inline(x)}</li>" for x in items) + f"</{tag}>")
            continue

        if line.strip() == "":
            i += 1
            continue

        para = []
        while (
            i < n
            and lines[i].strip() != ""
            and not lines[i].lstrip().startswith(("|", "```"))
            and not re.match(r"^(#{1,6})\s", lines[i])
            and not re.match(r"^\s*([-*]|\d+\.)\s+", lines[i])
        ):
            para.append(lines[i].strip())
            i += 1
        out.append("<p>" + inline(" ".join(para)) + "</p>")

    return "\n".join(out)


# --------------------------------------------------------------------------
# sources: pull /// doc blocks and parameter lists
# --------------------------------------------------------------------------

def strip_doc(line: str) -> str | None:
    s = line.lstrip()
    if not s.startswith("///"):
        return None
    s = s[3:]
    if s.startswith("|"):
        s = s[1:]
    if s.startswith(" "):
        s = s[1:]
    return s.rstrip()


def ident_of(line: str) -> str | None:
    for pat in (
        r"^\s*pub\s+fn\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)?)",
        r"^\s*pub\s+let\s+([A-Za-z_]\w*)",
        r"^\s*pub\s+const\s+([A-Za-z_]\w*)",
        r"^\s*pub\(all\)\s+(?:struct|enum|suberror)\s+([A-Za-z_]\w*)",
        r"^\s*pub\s+typealias\s+([A-Za-z_]\w*)",
        r"^\s*pub\s+trait\s+([A-Za-z_]\w*)",
    ):
        m = re.match(pat, line)
        if m:
            return m.group(1)
    return None


def grab_params(lines: list[str], idx: int) -> str:
    text, started, depth = "", False, 0
    for k in range(idx, min(len(lines), idx + 30)):
        for ch in lines[k]:
            if not started:
                if ch == "(":
                    started, depth = True, 1
                continue
            if ch == "(":
                depth += 1
                text += ch
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return text
                text += ch
            else:
                text += ch
    return text


def split_top(s: str) -> list[str]:
    parts, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def parse_param(p: str):
    p = p.strip()
    m = re.match(r"([A-Za-z_]\w*)([~?]?)\s*:\s*(.+)$", p, re.S)
    if not m:
        return None
    name, opt, rest = m.group(1), m.group(2), m.group(3)
    has_default = "=" in rest
    typ = rest.split("=")[0].strip() if has_default else rest.strip()
    return {"name": name + opt, "type": typ, "default": has_default}


def parse_source(path: Path, docs: dict, params: dict) -> None:
    lines = path.read_text(encoding="utf-8").split("\n")
    pending: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        d = strip_doc(line)
        if d is not None:
            pending.append(d)
            i += 1
            continue
        if line.startswith("#"):
            i += 1
            continue
        if line.strip() == "":
            pending = []
            i += 1
            continue
        ident = ident_of(line)
        if ident is not None:
            if pending:
                text = "\n".join(pending).strip("\n")
                if text.strip():
                    docs[ident] = text
            if re.match(r"^\s*pub\s+fn\b", line):
                raw = grab_params(lines, i)
                ps = [x for x in (parse_param(t) for t in split_top(raw)) if x]
                params[ident] = ps
            pending = []
        else:
            pending = []
        i += 1


# --------------------------------------------------------------------------
# pkg.generated.mbti
# --------------------------------------------------------------------------

def parse_mbti(path: Path):
    lines = path.read_text(encoding="utf-8").split("\n")
    package = ""
    items = []
    section = ""
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r'^package\s+"([^"]+)"', line)
        if m:
            package = m.group(1)
        m = re.match(r"^//\s+(Values|Errors|Types and methods|Type aliases|Traits)\s*$", line)
        if m:
            section = m.group(1)
        if re.match(r"^pub\b", line):
            buf = [line]
            depth = line.count("{") - line.count("}")
            j = i + 1
            while depth > 0 and j < len(lines):
                buf.append(lines[j])
                depth += lines[j].count("{") - lines[j].count("}")
                j += 1
            items.append({"section": section, "lines": buf})
            i = j
            continue
        i += 1
    return package, items


def classify(item: dict):
    first = item["lines"][0]
    m = re.match(r"^pub(?:\(all\))?\s+(fn|let|const|struct|enum|suberror|impl|typealias|trait)\b\s*([A-Za-z_][\w:]*)?", first)
    if not m:
        return None
    kind, name = m.group(1), m.group(2) or ""
    if kind == "fn":
        mm = re.search(r"\bfn\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)?)", first)
        name = mm.group(1) if mm else name
    elif kind in ("let", "const"):
        mm = re.search(r"\b(?:let|const)\s+([A-Za-z_]\w*)", first)
        name = mm.group(1) if mm else name
    elif kind in ("struct", "enum", "suberror"):
        mm = re.search(r"\b(?:struct|enum|suberror)\s+([A-Za-z_]\w*)", first)
        name = mm.group(1) if mm else name
        name = name.split("::")[0]
    return {"kind": kind, "name": name, "first": first, "body": item["lines"][1:-1] if len(item["lines"]) > 1 else []}


# --------------------------------------------------------------------------
# rendering helpers
# --------------------------------------------------------------------------

def sig_html(sig: str) -> str:
    e = esc(sig)
    e = re.sub(
        r"\b(pub|fn|let|const|struct|enum|suberror|impl|typealias|trait|derive|raise|for|with)\b",
        r'<span class="kw">\1</span>',
        e,
    )
    e = re.sub(
        r'(<span class="kw">(?:fn|let|const|struct|enum|suberror|typealias|trait)</span>\s+)([A-Za-z_][\w:]*)',
        r'\1<span class="name">\2</span>',
        e,
    )
    return e


def slug(name: str) -> str:
    return name.replace("::", "-")


def render_params(params: list) -> str:
    items = [p for p in params if p["name"].rstrip("~?") != "self"]
    if not items:
        return ""
    spans = []
    for p in items:
        d = ' <span class="d">= …</span>' if p["default"] else ""
        spans.append(f'<span class="p"><b>{esc(p["name"])}</b> <span class="pt">{esc(p["type"])}</span>{d}</span>')
    return '<div class="params">' + "".join(spans) + "</div>"


def render_item(kind: str, item: dict, docs: dict, params: dict, anchor: str, label: str | None = None) -> str:
    name = item["name"]
    doc = docs.get(name, "")
    if not doc and name.split("::")[-1] in DERIVED:
        doc = DERIVED[name.split("::")[-1]]
    sig = item["first"].rstrip("{").strip()
    body = f'<div class="sig">{sig_html(sig)}</div>'
    doc_html = f'<div class="doc">{md_to_html(doc)}</div>' if doc else ""
    prm = render_params(params.get(name, []))
    return f'<article class="api-item" id="{anchor}">\n{body}\n{doc_html}\n{prm}\n</article>'


def render_members(body: list[str]) -> str:
    if not body:
        return ""
    lis = []
    for raw in body:
        ln = raw.strip()
        if not ln:
            continue
        m = re.match(r"^([A-Za-z_]\w*)\s*:\s*(.+)$", ln)
        if m:
            lis.append(f'<li><b>{esc(m.group(1))}</b> : <span class="pt">{esc(m.group(2))}</span></li>')
        else:
            lis.append(f"<li>{esc(ln)}</li>")
    if not lis:
        return ""
    return '<ul class="members">' + "".join(lis) + "</ul>"


def build_package(mbti_path: Path, sources: list[Path], docs: dict, params: dict) -> dict:
    package, raw = parse_mbti(mbti_path)
    for src in sources:
        parse_source(src, docs, params)

    types: dict[str, dict] = {}
    errors: dict[str, dict] = {}
    methods: dict[str, list] = {}
    model = {"package": package, "types": {}, "errors": {}, "functions": [], "constants": []}

    classified = [classify(it) for it in raw]
    classified = [c for c in classified if c]

    for c in classified:
        if c["kind"] in ("struct", "enum"):
            types[c["name"]] = c
        elif c["kind"] == "suberror":
            errors[c["name"]] = c
        elif c["kind"] == "fn":
            if "::" in c["name"]:
                recv = c["name"].split("::")[0]
                methods.setdefault(recv, []).append(c)
            else:
                model["functions"].append(c)
        elif c["kind"] in ("let", "const"):
            model["constants"].append(c)

    def mkey(c):
        last = c["name"].split("::")[-1]
        return (0 if last == "new" else 1, last)

    for tname in sorted(types):
        t = types[tname]
        t["methods"] = sorted(methods.get(tname, []), key=mkey)
        model["types"][tname] = t
    for ename in sorted(errors):
        e = errors[ename]
        e["methods"] = sorted(methods.get(ename, []), key=mkey)
        model["errors"][ename] = e
    model["functions"].sort(key=lambda c: c["name"])
    model["constants"].sort(key=lambda c: c["name"])
    return model


def render_package(pkg_slug: str, model: dict, docs: dict, params: dict) -> str:
    alias = model["package"].split("/")[-1]
    out = [f'<section class="api-pkg" id="pkg-{pkg_slug}">']
    out.append("<header>")
    out.append(f'<h2><span class="mono">@{esc(alias)}</span></h2>')
    out.append(f'<div class="imp">import {{ "{esc(model["package"])}" }}</div>')
    out.append("</header>")

    if model["types"]:
        out.append('<div class="api-cat"><h3>Types</h3></div>')
        for tname, t in model["types"].items():
            out.append(f'<section class="api-type" id="type-{pkg_slug}-{slug(tname)}">')
            out.append(
                f'<div class="type-head"><h3>{esc(tname)}</h3><span class="kind">{esc(t["kind"])}</span></div>'
            )
            out.append(f'<div class="sig">{sig_html(t["first"].rstrip("{").strip())}</div>')
            doc = docs.get(tname, "")
            if doc:
                out.append(f'<div class="doc">{md_to_html(doc)}</div>')
            out.append(render_members(t["body"]))
            own = [m for m in t["methods"] if m["name"] in docs]
            derived = [m for m in t["methods"] if m["name"] not in docs]
            for label, group in (("Methods", own), ("Trait methods", derived)):
                if not group:
                    continue
                out.append(f'<div class="method-list"><div class="mlabel">{label}</div>')
                for m in group:
                    out.append(render_item("fn", m, docs, params, f'm-{pkg_slug}-{slug(m["name"])}'))
                out.append("</div>")
            out.append("</section>")

    if model["errors"]:
        out.append('<div class="api-cat"><h3>Errors</h3></div>')
        for ename, e in model["errors"].items():
            out.append(f'<section class="api-type" id="err-{pkg_slug}-{slug(ename)}">')
            out.append(
                f'<div class="type-head"><h3>{esc(ename)}</h3><span class="kind">suberror</span></div>'
            )
            out.append(f'<div class="sig">{sig_html(e["first"].rstrip("{").strip())}</div>')
            doc = docs.get(ename, "")
            if doc:
                out.append(f'<div class="doc">{md_to_html(doc)}</div>')
            if e["body"]:
                out.append(render_members(e["body"]))
            derived = [m for m in e["methods"] if m["name"].split("::")[-1] in DERIVED]
            if derived:
                out.append('<div class="method-list"><div class="mlabel">Trait methods</div>')
                for m in derived:
                    out.append(render_item("fn", m, docs, params, f'm-{pkg_slug}-{slug(m["name"])}'))
                out.append("</div>")
            out.append("</section>")

    if model["functions"]:
        out.append(f'<div class="api-cat" id="fn-{pkg_slug}"><h3>Functions</h3></div>')
        for f in model["functions"]:
            out.append(render_item("fn", f, docs, params, f'fn-{pkg_slug}-{slug(f["name"])}'))

    if model["constants"]:
        out.append(f'<div class="api-cat" id="const-{pkg_slug}"><h3>Constants</h3></div>')
        for c in model["constants"]:
            out.append(render_item("let", c, docs, params, f'const-{pkg_slug}-{slug(c["name"])}'))

    out.append("</section>")
    return "\n".join(out)


def render_sidebar(packages: list[tuple[str, dict]]) -> str:
    out = ['<nav class="api-nav" aria-label="API contents">']
    for pkg_slug, model in packages:
        alias = model["package"].split("/")[-1]
        out.append('<div class="group">')
        out.append(f'<div class="pkg">@{esc(alias)}</div>')
        for tname in model["types"]:
            out.append(f'<a href="#type-{pkg_slug}-{slug(tname)}">{esc(tname)}</a>')
        for ename in model["errors"]:
            out.append(f'<a href="#err-{pkg_slug}-{slug(ename)}">{esc(ename)}</a>')
        if model["functions"]:
            out.append(f'<a href="#fn-{pkg_slug}">Functions</a>')
        if model["constants"]:
            out.append(f'<a href="#const-{pkg_slug}">Constants</a>')
        out.append("</div>")
    out.append("</nav>")
    return "\n".join(out)


# --------------------------------------------------------------------------
# page shell (matches the hand-written pages)
# --------------------------------------------------------------------------

MARK = (
    '<svg class="mark" viewBox="0 0 24 24" aria-hidden="true">'
    '<path d="M12 1.6 14.7 8.28 22.46 8.6 16.38 13.42 18.47 20.9 12 16.6 5.53 20.9 '
    '7.62 13.42 1.54 8.6 9.3 8.28Z"/></svg>'
)
GITHUB = (
    '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">'
    '<path d="M12 .5C5.7.5.5 5.7.5 12c0 5.1 3.3 9.4 7.9 10.9.6.1.8-.3.8-.6v-2c-3.2.7-3.9-1.4-3.9-1.4'
    '-.5-1.3-1.3-1.7-1.3-1.7-1.1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1 1.8 2.7 1.3 3.4 1 .1-.8.4-1.3.7-1.6'
    '-2.6-.3-5.3-1.3-5.3-5.7 0-1.3.5-2.3 1.2-3.1-.1-.3-.5-1.5.1-3.1 0 0 1-.3 3.3 1.2a11.5 11.5 0 0 1 6 0'
    'C17.3 4.7 18.3 5 18.3 5c.6 1.6.2 2.8.1 3.1.8.8 1.2 1.8 1.2 3.1 0 4.4-2.7 5.4-5.3 5.7.4.4.8 1.1.8 2.2v3.3'
    'c0 .3.2.7.8.6 4.6-1.5 7.9-5.8 7.9-10.9C23.5 5.7 18.3.5 12 .5z"/></svg>'
)
SUN = (
    '<svg class="sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" '
    'stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4.9"/>'
    '<path d="M12 1.7v2.4M12 19.9v2.4M1.7 12h2.4M19.9 12h2.4M4.75 4.75l1.7 1.7M17.55 17.55l1.7 1.7'
    'M19.25 4.75l-1.7 1.7M6.45 17.55l-1.7 1.7"/></svg>'
)
MOON = (
    '<svg class="moon" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">'
    '<path d="M22 12.88A10 10 0 1 1 11.12 2a7.78 7.78 0 0 0 10.88 10.88z"/></svg>'
)
LATTICE = """<svg class="lattice" aria-hidden="true" focusable="false">
  <defs>
    <pattern id="comb" width="34.64" height="60" patternUnits="userSpaceOnUse">
      <path d="M17.32 -20 L34.64 -10 L34.64 10 L17.32 20 L0 10 L0 -10 Z" fill="none" stroke="currentColor" stroke-width=".7"/>
      <path d="M0 10 L17.32 20 L17.32 40 L0 50 L-17.32 40 L-17.32 20 Z
               M34.64 10 L51.96 20 L51.96 40 L34.64 50 L17.32 40 L17.32 20 Z
               M17.32 40 L34.64 50 L34.64 70 L17.32 80 L0 70 L0 50 Z" fill="none" stroke="currentColor" stroke-width=".7"/>
    </pattern>
  </defs>
  <rect width="100%" height="100%" fill="url(#comb)"/>
</svg>"""


def nav(active: str) -> str:
    def link(href: str, key: str, label: str) -> str:
        cur = ' aria-current="page"' if key == active else ""
        return f'<a href="{href}"{cur}>{label}</a>'

    return f"""<header class="topbar">
  <div class="wrap bar">
    <a class="brand" href="index.html">
      {MARK}
      <span>moona2a</span>
    </a>
    <nav class="mainnav" aria-label="Primary">
      {link("guide.html", "guide", "Guide")}
      {link("api.html", "api", "API")}
      {link("showcase.html", "star", "The star")}
    </nav>
    <div class="tools">
      <a class="icon-btn" href="https://github.com/moonbitstack/moona2a" target="_blank" rel="noopener" aria-label="GitHub repository">
        {GITHUB}
      </a>
      <button class="icon-btn theme-toggle" type="button" aria-label="Switch between light and dark">
        {SUN}
        {MOON}
      </button>
    </div>
  </div>
</header>

<div class="gauge" aria-hidden="false"><span class="pct">0%</span>
  {MARK}
</div>"""


def footer() -> str:
    return f"""<footer class="foot">
  <div class="wrap">
    <div class="row">
      <a class="brand" href="index.html">
        {MARK}
        <span>moona2a</span>
      </a>
      <p class="tag">The Agent2Agent protocol for MoonBit: cards, tasks, streams, push. Apache-2.0.</p>
      <div class="links">
        <a href="https://github.com/moonbitstack/moona2a" target="_blank" rel="noopener">GitHub</a>
        <a href="https://mooncakes.io/docs/moonbitstack/moona2a" target="_blank" rel="noopener">mooncakes</a>
        <a href="guide.html">Guide</a>
        <a href="showcase.html">The star</a>
        <a href="index.html">Home</a>
      </div>
    </div>
    <div class="legal"><span>Apache-2.0</span><span>Built with MoonBit</span></div>
  </div>
</footer>"""


def render(packages: list[tuple[str, dict]], docs: dict, params: dict) -> str:
    body = "\n".join(render_package(slug_, model, docs, params) for slug_, model in packages)
    sidebar = render_sidebar(packages)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>API reference — moona2a</title>
<meta name="description" content="Every public type, function and constant in moona2a, generated from the package interfaces and the sources' documentation comments.">
<meta name="theme-color" content="#f4eee2">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Crect width='24' height='24' fill='%23f4eee2'/%3E%3Cpath d='M12 2.4 14.5 9 21.4 9.3 15.9 13.7 17.8 20.4 12 16.5 6.2 20.4 8.1 13.7 2.6 9.3 9.5 9Z' fill='none' stroke='%23b8721a' stroke-width='1.4' stroke-linejoin='round'/%3E%3C/svg%3E">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Bodoni+Moda:ital,opsz,wght@0,6..96,400..500;1,6..96,400..500&family=JetBrains+Mono:wght@400;500&family=Manrope:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="assets/site.css">
<script>try{{const t=localStorage.getItem("moona2a-theme");if(t==="light"||t==="dark")document.documentElement.dataset.theme=t}}catch(e){{}}</script>
<script src="assets/site.js" defer></script>
</head>
<body id="top">
<a class="skip" href="#main">Skip to content</a>
{LATTICE}
{nav("api")}
<main id="main">
  <section class="page-hero">
    <div class="wrap">
      <span class="eyebrow">API</span>
      <h1>The <em>reference</em>.</h1>
      <p class="lede">Every public type, function and constant, grouped by package. Generated from <span class="mono">pkg.generated.mbti</span> and the sources' own documentation comments, so it says what the code says.</p>
    </div>
  </section>
  <div class="wrap api-layout">
    {sidebar}
    <div class="api-body">
{body}
    </div>
  </div>
</main>
{footer()}
</body>
</html>
"""


def main() -> None:
    docs: dict = {}
    params: dict = {}

    def sources_in(directory: Path) -> list[Path]:
        return sorted(p for p in directory.glob("*.mbt") if not p.name.endswith("_test.mbt"))

    packages = []
    for key, directory in (
        ("moona2a", SRC),
        ("asgi", SRC / "asgi"),
        ("fetch", SRC / "fetch"),
    ):
        mbti = directory / "pkg.generated.mbti"
        if not mbti.exists():
            raise SystemExit(f"missing {mbti.relative_to(ROOT)}: run `moon info --target all` first")
        model = build_package(mbti, sources_in(directory), docs, params)
        packages.append((key, model))

    html_out = render(packages, docs, params)
    OUT.write_text(html_out, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
