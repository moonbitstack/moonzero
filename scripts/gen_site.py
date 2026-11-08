#!/usr/bin/env python3
"""Generate the moonzero site into docs/.

The site is a control plane for the framework: the homepage is the topology, and
every package has a page shaped like a console — the request rail across the top,
the machine in the left column, the reading surface in the middle, the facts about
the package on the right.

Everything here is derived from the sources: the API rows from `///` comments and
declarations, the counts from the same parse, the guide's code from the example
programs themselves. Nothing on a page is typed twice.
"""
import html
import json
import pathlib
import re
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

from sections import SECTIONS, parse, prose, tint  # noqa: E402  (same directory)

DOCS = ROOT / "docs"
ASSETS = DOCS / "assets"

LANES = {
    "EDGE": [
        "service", "middleware", "group", "route", "hoops", "files", "gunzip",
        "signature", "rsa", "jwt", "auth", "metrics", "tracing",
    ],
    "CONTROL": [
        "config", "conf", "restconf", "logx", "logging", "refusal", "clock",
        "shutdown", "telemetry",
    ],
    "RESILIENCE": ["breaker", "shedder", "ratelimit", "limits", "limiting"],
    "ROUTING": [
        "rpc", "zrpc", "socket", "balance", "discov", "p2c", "interceptor",
        "clientinterceptors", "serverinterceptors", "rpcconf",
    ],
    "DATA": [
        "cache", "sql", "redis", "collection", "syncx", "mr", "fx", "threading",
        "services", "once",
    ],
}

LANE_OF = {key: lane for lane, keys in LANES.items() for key in keys}
ORDER = [key for lane in LANES for key in LANES[lane]]

# The rail is the request path. A package is pinned to the station it works at.
STATIONS = [
    ("client", "the call leaves"),
    ("conf", "the document is read"),
    ("middleware", "the chain wraps"),
    ("route", "the route decides"),
    ("handler", "your code runs"),
    ("breaker", "the dependency may refuse"),
    ("store", "state is read"),
    ("reply", "bytes go back"),
]
STATION_OF_LANE = {
    "ROUTING": 0,
    "CONTROL": 1,
    "EDGE": 2,
    "RESILIENCE": 5,
    "DATA": 6,
}

# The homepage topology: what is on the screen, and which page each chip opens.
SCREEN = [
    ("EDGE", [("rest :12000", "service", ""), ("middleware ×12", "middleware", "hot"),
              ("route", "route", ""), ("handler", "group", "")]),
    ("CONTROL", [("conf", "conf", ""), ("logx", "logx", ""),
                 ("telemetry", "telemetry", ""), ("proc", "shutdown", "")]),
    ("RESILIENCE", [("breaker", "breaker", ""), ("shedder", "shedder", ""),
                    ("limit", "ratelimit", "")]),
    ("ROUTING", [("balance", "balance", ""), ("discov", "discov", ""),
                 ("p2c", "p2c", ""), ("zrpc :12001", "rpc", "egress")]),
    ("DATA", [("cache", "cache", ""), ("redis", "redis", ""), ("sql", "sql", "")]),
]

TILES = [
    ("Transport", "EDGE", "REST and zRPC on one h2c, each with the interceptor chain it was configured with."),
    ("Resilience", "RESILIENCE", "A breaker, an adaptive shedder and three limiters, all reading the clock you hand them."),
    ("Routing", "ROUTING", "Round robin, weighted, or power of two choices over each instance's measured load."),
    ("Configuration", "CONTROL", "One document, checked at load, with every default written down where you can read it."),
    ("Data", "DATA", "Cache aside with one load per key, redis behind the same contract, SQL behind another."),
]

GUIDE = [
    ("Install", "moonbitstack/moonzero", "src/examples/01-config",
     "One dependency, and the loader, the engine and the middlewares come with it. "
     "Every example below is a program in this repository, run from its own directory."),
    ("Read one document", "src/examples/01-config", None,
     "A service is described before it is written: a name, a host, a port, and the "
     "layers the engine should install. The loader fills what the document leaves out."),
    ("Assemble the application", "src/examples/13-http1", None,
     "The engine takes your application and the layers the config asked for and hands "
     "back one ASGI application. Nothing listens yet — the host owns the socket."),
    ("Wrap it in the chain", "src/examples/04-resilience-mw", None,
     "Recovery, the breaker, the shedder and the limiters are layers in the same onion; "
     "the config decides which of them exists."),
    ("Let tokens through", "src/examples/05-jwt-crypto", None,
     "A JWT is signed and checked under HS256, a previous secret keeps rotation "
     "seamless, and a content signature covers the body the request actually carries."),
    ("Speak zRPC", "src/examples/07-zrpc", None,
     "Both halves of the wire run through one interceptor chain. In process is a real "
     "h2c exchange; a port is one layer away."),
    ("Stop without dropping a call", "src/examples/09-shutdown", None,
     "A drain makes new calls come back Unavailable while the ones already running "
     "finish, and reports when the last one has."),
    ("Call a peer another library wrote", "src/examples/15-interop", None,
     "The same server on a real socket, meeting a gRPC peer that shares no code with "
     "this one. The example is both ends: `serve <port>` and `call <port> <message>`."),
]


# ---------------------------------------------------------------- helpers


def esc(text):
    return html.escape(text, quote=True)


def neutral(text):
    """The page is about this library: the implementation it was modelled on is
    named nowhere, and the parenthetical asides that pointed at it are dropped."""
    text = re.sub(r"\s*\(\s*(?:←|<-|&#8592;)[^)]*\)", "", text)
    text = re.sub(r"\s*\(\s*(?:the )?[^)]*go-zero[^)]*\)", "", text)
    text = text.replace("go-zero's ", "").replace("go-zero's", "")
    text = text.replace("go-zero ", "").replace("go-zero", "the reference")
    text = text.replace("(← the reference's ", "(")
    text = text.replace("the reference's ", "")
    return text


def item_count(key):
    for k, files, _title, _doc in SECTIONS:
        if k != key:
            continue
        paths = files if isinstance(files, tuple) else (files,)
        n = 0
        for rel in paths:
            path = ROOT / "src" / rel
            if path.exists():
                n += len(parse(path))
        return n
    return 0


def files_of(key):
    for k, files, _title, _doc in SECTIONS:
        if k == key:
            return list(files) if isinstance(files, tuple) else [files]
    return []


def section(key):
    for entry in SECTIONS:
        if entry[0] == key:
            return entry
    return None


SECTION_INDEX = {entry[0]: entry for entry in SECTIONS}
PALETTE = []


def page_title(key):
    entry = SECTION_INDEX.get(key)
    return entry[2] if entry else key


def palette_entry(key):
    entry = SECTION_INDEX.get(key)
    if not entry:
        return None
    return {
        "name": entry[2],
        "href": "pkg/%s.html" % key,
        "lane": LANE_OF.get(key, ""),
        "summary": entry[3].split(".")[0][:96],
    }


def head(depth, title, description):
    up = "../" if depth else ""
    # No data-theme in the markup: the stylesheet reads the system preference,
    # and this script resolves it before the first paint so nothing flashes.
    # A stored choice wins over the system, a ?theme= wins over both.
    theme_script = """<script>
(function () {
  var pick = function (v) { return v === "day" || v === "night" ? v : null; };
  var t = null;
  try { t = pick(new URLSearchParams(location.search).get("theme")); } catch (e) {}
  if (!t) { try { t = pick(localStorage.getItem("mz-theme")); } catch (e) {} }
  if (!t) t = window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches ? "night" : "day";
  document.documentElement.setAttribute("data-theme", t);
})();
</script>"""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>{esc(title)}</title>
<meta name="description" content="{esc(description)}">
<link rel="icon" href="{up}assets/favicon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600&family=Source+Serif+4:ital,opsz,wght@0,8..60,400;0,8..60,600;1,8..60,400&family=Space+Grotesk:wght@400;500;700&display=swap">
<link rel="stylesheet" href="{up}assets/site.css">
{theme_script}
</head>
<body data-up="{up}">"""


def version():
    """The module version, read from moon.mod so a page never carries a stale one."""
    text = (ROOT / "moon.mod").read_text(encoding="utf-8")
    return re.search(r'^version\s*=\s*"([^"]+)"', text, re.M).group(1)


def bar(depth, crumbs=None, facts=True):
    up = "../" if depth else ""
    crumb = ""
    if crumbs:
        parts = []
        for label, href in crumbs:
            if href:
                parts.append(f'<a href="{href}">{esc(label)}</a>')
            else:
                parts.append(f"<b>{esc(label)}</b>")
        crumb = '<span class="crumb">' + "  /  ".join(parts) + "</span>"
    middle = (
        '<span class="facts">v%s  ·  %d packages  ·  4 targets  ·  Apache-2.0</span>'
        % (esc(version()), len(SECTIONS))
        if facts
        else ""
    )
    return f"""<header class="bar">
  <a class="mark" href="{up}index.html">moonzero</a>
  <span class="mode">· control plane</span>
  {middle}
  <span class="spacer"></span>
  {crumb}
  <button class="plain" data-palette-open type="button" title="Search packages">⌘K</button>
  <button class="theme" type="button" aria-label="Colour theme — follows your system until you choose" title="Follows your system until you choose">
    <span data-theme-set="day">DAY</span><span data-theme-set="night">NIGHT</span>
  </button>
  <a href="https://github.com/moonbitstack/moonzero" title="Source on GitHub">GitHub</a>
</header>"""


def rail(depth, here):
    up = "../" if depth else ""
    out = []
    for i, (name, note) in enumerate(STATIONS):
        cls = ' class="here"' if i == here else ""
        out.append(
            f'<li{cls}><a href="{up}reference.html" title="{esc(note)}">{esc(name)}</a></li>'
        )
    return (
        '<nav class="rail" aria-label="Where this sits in a request"><ol>'
        + "".join(out)
        + "</ol></nav>"
    )


def foot(depth):
    up = "../" if depth else ""
    return f"""<footer class="foot">
  <span>moonzero · Apache-2.0 · generated from <code>///</code></span>
  <nav class="links">
    <a href="{up}guide.html">Guide</a>
    <a href="{up}reference.html">API</a>
    <a href="{up}lab.html">Lab</a>
    <a href="{up}skill.html">Skills</a>
  </nav>
  <a class="repo" href="https://github.com/moonbitstack/moonzero">GitHub</a>
</footer>"""


def palette_markup(depth):
    up = "../" if depth else ""
    index = [e for e in (palette_entry(k) for k in ORDER) if e]
    for entry in index:
        entry["href"] = up + entry["href"]
    return f"""<div class="palette" role="dialog" aria-label="Jump to a package">
  <div class="box">
    <input type="search" placeholder="grep packages…" autocomplete="off" spellcheck="false">
    <ul></ul>
  </div>
</div>
<script type="application/json" id="site-index">{json.dumps(index)}</script>
<script src="{up}assets/site.js" defer></script>"""


def minimap(depth, here_key, toc=None):
    up = "../" if depth else ""
    here_lane = LANE_OF.get(here_key)
    lanes = []
    for lane, keys in LANES.items():
        if lane == here_lane:
            nodes = "".join(
                f'<a class="node{" here" if k == here_key else ""}" href="{up}pkg/{k}.html">{esc(k)}</a>'
                for k in keys
            )
            lanes.append(
                f'<div class="lane open"><p class="lane-name">{esc(lane)}'
                f'<span>{len(keys)}</span></p><div class="nodes">{nodes}</div></div>'
            )
        else:
            lanes.append(
                f'<a class="lane shut" href="{up}pkg/{keys[0]}.html">'
                f'<span>{esc(lane)}</span><b>{len(keys)}</b></a>'
            )
    toc_html = ""
    if toc:
        toc_html = '<div class="toc"><p>ON THIS PAGE</p>' + "".join(
            f'<a href="#{anchor}">{esc(label)}</a>' for anchor, label in toc
        ) + "</div>"
    return (
        '<aside class="minimap"><p class="label">THE MACHINE</p>'
        + "".join(lanes)
        + toc_html
        + "</aside>"
    )


def code_block(code, caption, depth, lang="moonbit"):
    return f"""<div class="code">
  <div class="cap"><span>{esc(caption)}</span><button class="copy" type="button" data-copy="self">copy</button></div>
  <pre><code data-lang="{lang}">{code}</code></pre>
</div>"""


def highlight(code):
    """A little MoonBit colour, applied after escaping: keywords, types, comments,
    strings. Enough to read by, and it never changes the characters themselves."""
    out = esc(code)
    out = re.sub(r"(//[^\n]*)", r'<span class="c">\1</span>', out)
    out = re.sub(r"&quot;([^&]*?)&quot;", r'<span class="s">&quot;\1&quot;</span>', out)
    out = re.sub(
        r"\b(fn|let|mut|if|else|while|for|in|match|try|catch|raise|async|pub|struct|enum|type|impl|guard|return|true|false)\b",
        r'<span class="k">\1</span>',
        out,
    )
    return out


# ---------------------------------------------------------------- package pages


def package_page(key):
    entry = SECTION_INDEX[key]
    _k, files, title, doc = entry
    lane = LANE_OF.get(key, "EDGE")
    lane_keys = LANES[lane]
    index_in_lane = lane_keys.index(key) + 1
    pos = ORDER.index(key)
    prev_key = ORDER[pos - 1] if pos > 0 else None
    next_key = ORDER[pos + 1] if pos + 1 < len(ORDER) else None

    paths = files if isinstance(files, tuple) else (files,)
    items = []
    for rel in paths:
        path = ROOT / "src" / rel
        if path.exists():
            items.extend(parse(path))

    kinds = {}
    for kind, _sig, _d in items:
        kinds[kind] = kinds.get(kind, 0) + 1

    rows = "".join(
        f'<div class="row"><code class="sig">{tint(neutral(sig))}</code>'
        f'<p class="doc"><span class="kind">{esc(kind)}</span>{prose(neutral(doc))}</p></div>'
        for kind, sig, doc in items
    )

    flow = "".join(
        ('<span class="arrow"></span>' if i else "")
        + f'<a class="node{" here" if k == key else ""}" href="{k}.html">{esc(k)}</a>'
        for i, k in enumerate(lane_keys)
    )

    related = "".join(
        f'<a class="node" href="{k}.html">{esc(k)}</a>' for k in lane_keys if k != key
    )

    pager = ""
    if prev_key:
        pager += f'<a href="{prev_key}.html">←  {esc(prev_key)}</a>'
    else:
        pager += "<span></span>"
    if next_key:
        pager += f'<a class="next" href="{next_key}.html">{esc(next_key)}  →</a>'

    types = [sig.split(" ")[0] for kind, sig, _ in items if kind == "type"][:6]
    deps = kinds.get("fn", 0)
    spec = f"""<aside class="signals">
  <p class="label">SPEC</p>
  <dl>
    <div class="pair"><dt>functions</dt><dd>{deps}</dd></div>
    <div class="pair"><dt>types</dt><dd>{kinds.get("type", 0)}</dd></div>
    <div class="pair"><dt>values</dt><dd>{kinds.get("let", 0)}</dd></div>
    <div class="pair"><dt>errors</dt><dd>{kinds.get("error", 0)}</dd></div>
  </dl>
  <div class="block">
    <p>SOURCE</p>
    {"".join(f"<p>{esc(p)}</p>" for p in paths)}
  </div>
  <div class="block">
    <p>STATION</p>
    <p>{esc(STATIONS[STATION_OF_LANE[lane]][0])} — {esc(STATIONS[STATION_OF_LANE[lane]][1])}</p>
  </div>
  <p class="note">Every row below is read from those files: the signature from the
  declaration, the sentence from its <code>///</code> comment.</p>
</aside>"""

    toc = [("where", "Where it sits"), ("interface", "Interface"), ("related", "Related")]
    body = f"""{bar(2, crumbs=[("docs", "../reference.html"), (lane.lower(), "../reference.html"), (key, None)])}
{rail(2, STATION_OF_LANE[lane])}
<div class="shell">
  {minimap(2, key, toc)}
  <main class="paper">
    <p class="eyebrow">{index_in_lane:02d}   /   {esc(lane)}</p>
    <h1>{esc(key)}</h1>
    <p class="lead">{prose(neutral(doc))}</p>

    <p class="section-label" id="where">WHERE IT SITS</p>
    <div class="flow">{flow}</div>

    <p class="section-label" id="interface">INTERFACE</p>
    <div class="api">{rows}</div>

    <p class="section-label" id="related">RELATED</p>
    <div class="flow">{related}</div>

    <nav class="pager">{pager}</nav>
  </main>
  {spec}
</div>
{foot(2)}
{palette_markup(2)}
</body>
</html>"""
    return head(2, f"{key} — {title} — moonzero", doc or title) + body


# ---------------------------------------------------------------- home


def home_page():
    lanes_html = []
    for lane, chips in SCREEN:
        chain = []
        for i, (label, key, tone) in enumerate(chips):
            if i:
                chain.append('<span class="link"></span>')
            chain.append(
                f'<a class="chip {tone}" href="pkg/{key}.html" data-node="{key}">{esc(label)}</a>'
            )
        lanes_html.append(
            f'<div class="lane"><p class="lane-name">{esc(lane)}</p>'
            f'<div class="chain">{"".join(chain)}</div></div>'
        )

    stops = [
        ("01", "client", "your service", "one config document", "service", False),
        ("02", "config", "conf", "keys, defaults, tags", "conf", False),
        ("03", "middleware", "rest/handler", "cors · jwt · gunzip", "middleware", False),
        ("04", "route", "rest/route", "options per route", "route", False),
        ("05", "resilience", "breaker", "fails fast, sheds load", "breaker", False),
        ("06", "state", "stores", "cache · redis · sql", "cache", False),
        ("07", "answer", "rest · zrpc", "bytes on the wire", "rpc", True),
    ]
    path_html = "".join(
        f'<div class="stop"><span class="n">{n}   {label}</span>'
        f'<a class="card{" end" if end else ""}" href="pkg/{key}.html">'
        f"<b>{name}</b><span>{role}</span></a></div>"
        for n, label, name, role, key, end in stops
    )

    tiles_html = []
    for i, (name, lane, line) in enumerate(TILES):
        count = len(LANES[lane])
        tiles_html.append(
            f'<a class="tile" href="reference.html#{lane.lower()}">'
            f'<span class="idx">{i + 1:02d}</span>'
            f"<h3>{esc(name)}</h3><p>{esc(line)}</p>"
            f'<span class="figure"><b>{count}</b><small>packages</small></span></a>'
        )
    all_items = sum(item_count(k) for k in ORDER)
    tiles_html.append(
        f'<a class="tile" href="reference.html">'
        f'<span class="idx">06</span><h3>Runtime</h3>'
        f"<p>Stop and drain on a signal, log a request, trace it, and run several "
        f"services as one process.</p>"
        f'<span class="figure"><b>{all_items}</b><small>public items</small></span></a>'
    )

    yaml = """Name: orders-api
Host: 0.0.0.0
Port: 12000
Middlewares:
  Breaker: true
  Shedding: true
  Gunzip: true
Breaker:
  CpuThreshold: 800"""

    return (
        head(0, "moonzero — a service framework for MoonBit",
             "Configuration, middleware, zRPC, resilience and discovery in one place.")
        + "\n" + bar(0, facts=False).replace(
            '<span class="facts"></span>', ""
        )
        + f"""
<main class="hero">
  <div>
    <p class="eyebrow">MOONBIT  ·  SERVICE FRAMEWORK</p>
    <h1>moonzero</h1>
    <p class="lead">One config document becomes a service that is already running:
      an application, the middleware it asked for, and an answer on a port.</p>
    <div class="install"><code>moon add moonbitstack/moonzero</code>
      <button class="copy" type="button" data-copy=".install code">COPY</button></div>
    <div class="actions">
      <a class="btn primary" href="guide.html">Get started</a>
      <a class="btn" href="reference.html">Read the map</a>
    </div>
    <p class="meta">runs on wasm-gc, wasm, js and native</p>
  </div>

  <div class="screen" data-scene="healthy">
    <div class="head"><span>LIVE TOPOLOGY</span><span class="state" data-scene-state>all healthy</span></div>
    <div class="body">
      <div class="lanes">{"".join(lanes_html)}</div>
      <div class="readouts">
        <div class="readout"><span class="k">REQ / S</span><span class="v" data-scene-req>12.4k</span></div>
        <div class="readout"><span class="k">P99 LATENCY</span><span class="v" data-scene-p99>3.1 ms</span></div>
        <div class="readout"><span class="k">SHED</span><span class="v ok" data-scene-shed>0.0%</span></div>
      </div>
    </div>
    <div class="scene">
      <button class="pick" type="button" data-scene-set="healthy" aria-pressed="true">all healthy</button>
      <button class="pick bad" type="button" data-scene-set="slow" aria-pressed="false">one instance slow</button>
      <button class="pick bad" type="button" data-scene-set="down" aria-pressed="false">redis down</button>
      <span class="hint" data-scene-note>every instance answering</span>
    </div>
  </div>
</main>

<div class="trace">
  <span class="tag">TRACE</span>
  <span class="line" data-scene-trace>18:02:11.412    GET /api/v1/orders    200    2.1ms    ·    p2c chose b    ·    cache hit    ·    span 4bf9…</span>
  <span class="right">demo · the numbers are this page's, not a benchmark</span>
</div>

<section class="section">
  <div class="section-head">
    <p class="eyebrow">01   /   THE PATH</p>
    <h2>One request, end to end</h2>
    <p>Every hop is a package you can open. The rail on every page is this same line.</p>
  </div>
  <div class="path">{path_html}</div>
</section>

<section class="section">
  <div class="section-head">
    <p class="eyebrow">02   /   WHAT IT CARRIES</p>
    <h2>What you stop writing yourself</h2>
    <p>Six areas, one dependency, and a package behind each of them.</p>
  </div>
  <div class="tiles">{"".join(tiles_html)}</div>
</section>

<section class="section">
  <div class="section-head">
    <p class="eyebrow">03   /   CONFIGURED, NOT CODED</p>
    <h2>The service is a document</h2>
  </div>
  <div class="document">
    {code_block(highlight(yaml), "etc/orders.yaml", 0, "yaml")}
    <dl class="keys">
      <p class="lead-row">read at load · refused if wrong · defaulted if absent</p>
      <dt>Middlewares.Breaker</dt>
      <dd>The chain is assembled from these flags — a flag with nothing behind it changes no layer.</dd>
      <dt>Breaker.CpuThreshold</dt>
      <dd>A thousandth of the CPU reading: 800 is 80%. The shedder reads the same number.</dd>
      <dt>Port</dt>
      <dd>One number for the listener. The host that runs the application owns the socket.</dd>
    </dl>
  </div>
</section>
"""
        + foot(0)
        + "\n"
        + palette_markup(0)
        + "\n</body>\n</html>\n"
    )


# ---------------------------------------------------------------- reference index


def reference_page():
    blocks = []
    for lane, keys in LANES.items():
        rows = "".join(
            f'<a class="row" href="pkg/{k}.html" id="{k}">'
            f'<code class="sig">{esc(k)}</code>'
            f'<p class="doc"><span class="kind">{esc(lane)}</span>{prose(neutral(SECTION_INDEX[k][3]))}</p></a>'
            for k in keys
        )
        blocks.append(
            f'<section class="section inset" id="{lane.lower()}">'
            f'<div class="section-head"><p class="eyebrow">{esc(lane)}</p>'
            f"<h2>{len(keys)} packages</h2></div>"
            f'<div class="api">{rows}</div></section>'
        )

    style = (
        "<style>.api .row{display:grid;grid-template-columns:200px minmax(0,1fr);"
        "gap:8px 24px;padding:16px 0;border-top:1px solid var(--rule);color:inherit}"
        ".api .row:hover .sig{color:var(--accent)}"
        ".api .row:first-child{border-top-color:var(--rule-2)}</style>"
    )

    return (
        head(0, "API reference — moonzero", "Every package, every public item, generated from the sources.")
        + style
        + "\n" + bar(0, crumbs=[("docs", None)])
        + f"""
<main class="shell single">
  <div class="paper">
    <p class="eyebrow">REFERENCE</p>
    <h1>Every package, one row each</h1>
    <p class="lead">{len(SECTIONS)} packages, grouped by where they sit in a request.
      Each one opens on its own page: what it does, where it sits, and every public
      declaration with the sentence its author wrote for it.</p>
  </div>
</main>
{"".join(blocks)}
"""
        + foot(0)
        + "\n"
        + palette_markup(0)
        + "\n</body>\n</html>\n"
    )


# ---------------------------------------------------------------- guide


def guide_page():
    steps = []
    for i, (title, arg, example, blurb) in enumerate(GUIDE):
        if example:
            path = ROOT / example / "main.mbt"
            code = path.read_text(encoding="utf-8") if path.exists() else ""
            lines = [l for l in code.splitlines() if not l.startswith("// Copyright")]
            # Start at the program: the doc block above `main` describes the file,
            # and a reader following the guide wants the code that runs.
            start = 0
            for i, line in enumerate(lines):
                if re.match(r"^(async )?fn main", line.strip()):
                    start = max(0, i - 2 if i >= 2 and lines[i - 2].lstrip().startswith("#") else i)
                    break
            lines = lines[start:]
            while lines and lines[0].strip() == "":
                lines.pop(0)
            body = "\n".join(lines)
            if len(lines) > 44:
                body = "\n".join(lines[:44]) + "\n// … the rest is in the file"
            pkg = (ROOT / example / "moon.pkg").read_text(encoding="utf-8") if (ROOT / example / "moon.pkg").exists() else ""
            target = " --target native" if 'supported_targets = "native"' in pkg else ""
            cmd = f'moon run{target} {example}'
            block = code_block(highlight(body), path.relative_to(ROOT).as_posix(), 0)
            cmd_html = f'<p class="cmd"><b>$</b> {esc(cmd)}</p>'
        else:
            block = code_block(
                highlight('moon add moonbitstack/moonzero\nmoon run src/examples/01-config'),
                "shell",
                0,
                "shell",
            )
            cmd_html = ""

        steps.append(
            f'<div class="step"><h2>{esc(title)}</h2><p>{esc(blurb)}</p>'
            f"{cmd_html}{block}</div>"
        )

    return (
        head(0, "Guide — moonzero", "From one config document to a service that answers, in eight steps.")
        + "\n" + bar(0, crumbs=[("guide", None)])
        + f"""
<main class="shell single">
  <div class="paper">
    <p class="eyebrow">GUIDE</p>
    <h1>Eight stops to a running service</h1>
    <p class="lead">Every block below is a program in this repository, copied at build
      time — so the guide cannot drift from the code it teaches. Run one from the
      root and read what it prints.</p>
    <div class="steps" style="margin-top:44px">{"".join(steps)}</div>
  </div>
</main>
"""
        + foot(0)
        + "\n"
        + palette_markup(0)
        + "\n</body>\n</html>\n"
    )


# ---------------------------------------------------------------- lab


def lab_page():
    return (
        head(0, "Lab — moonzero", "Two of the framework's decisions, movable by hand.")
        + "\n" + bar(0, crumbs=[("lab", None)])
        + """
<main class="shell single">
  <div class="paper">
    <p class="eyebrow">LAB</p>
    <h1>Two decisions you can move</h1>
    <p class="lead">The picker and the bucket are the two places a service says no.
      Move the inputs and watch where the line falls.</p>
  </div>
  <div class="lab">

    <div class="bench" data-bench="p2c">
      <h2>Power of two choices</h2>
      <p class="src">src/balance/p2c.mbt — load = trunc(sqrt(lag_ms · 10⁶ + 1)) · (inflight + 1)</p>
      <div class="controls">
        <label class="control">instance a <input id="lat-a" type="range" min="1" max="200" value="2"><output id="lat-a-out">2 ms</output></label>
        <label class="control">instance b <input id="lat-b" type="range" min="1" max="200" value="2"><output id="lat-b-out">2 ms</output></label>
        <label class="control">instance c <input id="lat-c" type="range" min="1" max="200" value="120"><output id="lat-c-out">120 ms</output></label>
        <label class="control">calls <input id="p2c-calls" type="range" min="50" max="600" step="50" value="300"><output>300</output></label>
      </div>
      <button class="btn" id="p2c-run" type="button">run 300 calls</button>
      <div class="bars"></div>
      <div class="out"></div>
    </div>

    <div class="bench" data-bench="bucket">
      <h2>Token bucket</h2>
      <p class="src">src/limit/ratelimit.mbt — holds up to burst, refills at rate a second, one token a request</p>
      <div class="controls">
        <label class="control">rate <input id="rate" type="range" min="1" max="200" value="50"><output id="rate-out">50 /s</output></label>
        <label class="control">burst <input id="burst" type="range" min="1" max="100" value="20"><output id="burst-out">20 tokens</output></label>
        <label class="control">demand <input id="demand" type="range" min="1" max="300" value="80"><output id="demand-out">80 /s</output></label>
      </div>
      <button class="btn" id="bucket-run" type="button">run 5 seconds</button>
      <div class="out"></div>
    </div>

  </div>
</main>
<p class="lab-note">Both benches are the same arithmetic as the files named above, kept in
  the page so they move without a build step. The library runs the same formulas in a
  real service.</p>
"""
        + foot(0)
        + "\n"
        + palette_markup(0)
        + "\n</body>\n</html>\n"
    )


# ---------------------------------------------------------------- skill


def md_to_html(text):
    out = []
    in_code = False
    in_list = False
    para = []

    def flush():
        if para:
            out.append(f"<p>{inline(' '.join(para))}</p>")
            para.clear()

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for line in text.splitlines():
        if line.startswith("```"):
            flush()
            close_list()
            if in_code:
                out.append("</code></pre></div>")
                in_code = False
            else:
                out.append('<div class="code"><pre><code>')
                in_code = True
            continue
        if in_code:
            out.append(esc(line))
            continue
        if line.startswith("# "):
            flush()
            close_list()
            out.append(f"<h1>{esc(line[2:])}</h1>")
        elif line.startswith("## "):
            flush()
            close_list()
            out.append(f'<h2>{esc(line[3:])}</h2>')
        elif line.startswith("- "):
            flush()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
        elif line.strip() == "":
            flush()
            close_list()
        else:
            close_list()
            para.append(line.strip())
    flush()
    close_list()
    if in_code:
        out.append("</code></pre></div>")
    return "\n".join(out)


def inline(text):
    text = esc(text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return text


def skill_page():
    path = DOCS / "skills" / "moonzero" / "SKILL.md"
    text = path.read_text(encoding="utf-8")
    if text.startswith("---"):
        end = text.find("\n---", 4)
        text = text[end + 4:] if end != -1 else text
    body = md_to_html(text)
    return (
        head(0, "Skill — moonzero", "The skill an agent reads to use this library.")
        + "\n" + bar(0, crumbs=[("skills", None)])
        + f"""
<main class="shell single">
  <div class="paper">
    <p class="eyebrow">SKILL</p>
    <p class="lead">The same instructions an agent gets from
      <code>docs/skills/moonzero/SKILL.md</code>, published with every release.</p>
    <div class="skill-body" style="margin-top:32px">{body}</div>
  </div>
</main>
<style>
  .skill-body h1{{font-family:var(--grotesk);font-size:30px;margin:0 0 16px}}
  .skill-body h2{{font-family:var(--grotesk);font-size:20px;font-weight:500;margin:34px 0 10px}}
  .skill-body p{{margin:0 0 12px;color:var(--ink-2);max-width:70ch}}
  .skill-body li{{margin:0 0 6px;color:var(--ink-2)}}
  .skill-body code{{font-family:var(--mono);font-size:12px;background:var(--paper-2);
    border:1px solid var(--rule);border-radius:2px;padding:1px 4px;overflow-wrap:anywhere}}
  .skill-body .code code{{background:none;border:0;padding:0;color:var(--code-ink)}}
</style>
"""
        + foot(0)
        + "\n"
        + palette_markup(0)
        + "\n</body>\n</html>\n"
    )


def not_found():
    return (
        head(0, "Not here — moonzero", "That page is not part of the control plane.")
        + "\n" + bar(0, facts=False)
        + """
<main class="shell single error">
  <div class="paper">
    <p class="eyebrow">404</p>
    <h1>Nothing listens at that path</h1>
    <p class="lead">No route matched. The map is the place to start.</p>
    <p style="margin-top:28px"><a class="btn primary" href="/moonzero/">Back to the control plane</a></p>
  </div>
</main>
"""
        + foot(0)
        + "\n"
        + palette_markup(0)
        + "\n</body>\n</html>\n"
    )


# ---------------------------------------------------------------- main


def main():
    (DOCS / "pkg").mkdir(parents=True, exist_ok=True)
    (ASSETS).mkdir(parents=True, exist_ok=True)

    (DOCS / "index.html").write_text(home_page(), encoding="utf-8", newline="\n")
    (DOCS / "reference.html").write_text(reference_page(), encoding="utf-8", newline="\n")
    (DOCS / "guide.html").write_text(guide_page(), encoding="utf-8", newline="\n")
    (DOCS / "lab.html").write_text(lab_page(), encoding="utf-8", newline="\n")
    (DOCS / "skill.html").write_text(skill_page(), encoding="utf-8", newline="\n")
    (DOCS / "404.html").write_text(not_found(), encoding="utf-8", newline="\n")

    (ASSETS / "favicon.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">'
        '<rect width="32" height="32" rx="6" fill="#0c1116"/>'
        '<path d="M8 22V10l8 7 8-7v12" fill="none" stroke="#6d5efc" stroke-width="2.2" '
        'stroke-linecap="square" stroke-linejoin="miter"/></svg>',
        encoding="utf-8",
        newline="\n",
    )

    for key in ORDER:
        (DOCS / "pkg" / f"{key}.html").write_text(
            package_page(key), encoding="utf-8", newline="\n"
        )

    stale = DOCS / "api.html"
    if stale.exists():
        stale.unlink()

    total = len(ORDER) + 6
    print(f"wrote {total} pages into {DOCS}")


if __name__ == "__main__":
    main()
