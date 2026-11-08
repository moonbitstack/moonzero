#!/usr/bin/env python3
"""The package list and the parser that reads it out of the sources.

`gen_site.py` turns this into pages: one entry per package, each naming the files
that document it and the sentence that describes it, and a `parse()` that reads a
file's `///` comments and declarations back out so a page can never drift from the
code it documents."""

import re, html, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SECTIONS = [
    ("service", "rest/server.mbt", "Service assembly",
     "ServiceConf (typed config: name, host, port, timeout, log level) + Server "
     "tie the application and a middleware onion into one runnable ASGI "
     "application; logging is a built-in layer."),
    ("middleware", "rest/handler/middleware.mbt", "Middleware set",
     "The onion layers that wrap the app: recovery (500 instead of a panic), "
     "cors (Access-Control-* headers), and request_id (x-request-id per request)."),
    ("group", "rest/group.mbt", "Route groups",
     "Group registers a set of routes under a shared path prefix, so "
     "related endpoints are declared without repeating the prefix."),
    ("config", "conf/service.mbt", "Typed config loading",
     "Parse a JSON or YAML config string into a ServiceConf: a strict derived "
     "FromJson path plus lenient ServiceConf::from_json / from_yaml loaders that "
     "fill omitted fields from the new() defaults, so a document may name only "
     "what it changes."),
    ("jwt", "rest/handler/jwt.mbt", "JWT (HS256)",
     "base64url plus compact-JWT signing and verification under HS256: "
     "jwt_sign / jwt_verify check the signature in constant time and enforce "
     "exp/nbf, rejecting the alg:none downgrade."),
    ("auth", "rest/handler/auth.mbt", "JWT auth middleware",
     "The auth middleware requires every HTTP request to carry a valid "
     "Authorization: Bearer <jwt>, rejecting absent/malformed/tampered/expired "
     "tokens with 401 before the app runs."),
    ("rpc", "zrpc/server.mbt", "zRPC service groups",
     "An RpcServer (config-driven) registers moonrpc Method handlers by gRPC "
     "path and dispatches unary calls, returning Unimplemented for unknown "
     "methods; RpcGroup registers a set of methods under one package.Service."),
    ("zrpc", "zrpc/client.mbt", "zRPC over the h2c transport",
     "RpcServer::to_h2 exposes the registered handlers as a moonrpc H2Server, and "
     "RpcChannel drives real unary, server/client-streaming, and bidirectional "
     "calls over that transport: HPACK-coded HEADERS, length-prefixed DATA frames, "
     "and the grpc-status trailer read back off the reply. A BidiCall keeps the "
     "stream open both ways — send returns the replies produced right then, "
     "close_send runs the server's on_end and reports the final grpc-status."),
    ("socket", "zrpc/socket/net.mbt", "zRPC on a socket",
     "A Listener puts an RpcServer on TCP with the same handler table and the same "
     "interceptor chain the in-process transport runs; port 0 asks the system for a "
     "free one and bound_port answers the number it picked, so a test connects to the "
     "port it is told rather than to a number it chose. A SocketChannel multiplexes "
     "calls as HTTP/2 streams over one connection and speaks h2c to any gRPC peer."),
    ("shutdown", "proc/shutdown.mbt", "Graceful shutdown",
     "A ShutdownCoordinator that drains in-flight zRPC calls: dispatch_graceful "
     "counts each call for its duration, initiate_shutdown makes new calls come "
     "back Unavailable while in-flight ones finish, and is_drained reports when "
     "the last one has completed."),
    ("balance", "balance/balance.mbt", "Balancers & load-balanced client",
     "Balancers over moonpool's RoundRobin and Weighted, and a LoadBalancedChannel "
     "that resolves a service through the Resolve interface, picks an instance, and "
     "dials it over the h2c transport. Registries come from moonsd and the clients "
     "that implement it; a View of moonsd's is what a program resolves through."),
    ("discov", "discov/discov.mbt", "Discovery over a file",
     "A moonsd Discovery over a file: publish writes what a memory registry holds, "
     "FileDiscovery resolves from it and watches it through moonbitlang/async's fs."),
    ("clock", "clock/clock.mbt", "Clock abstraction",
     "A millisecond time source injected into the resilience middlewares so "
     "their timing is a pure function of an explicit clock; ManualClock drives "
     "them deterministically in tests."),
    ("ratelimit", "limit/ratelimit.mbt", "Rate limiting",
     "A token-bucket limiter over moonward's bucket, on the millisecond clock, and "
     "the rate_limit middleware, which answers 429 when it is empty."),
    ("breaker", "breaker/breaker.mbt", "Circuit breaker",
     "The Google SRE client-side throttling breaker over moonward's: it reads the "
     "last ten seconds of outcomes and sheds a computed fraction of calls rather "
     "than opening, and the breaker middleware answers 503 for a shed one."),
    ("limits", "rest/handler/limits.mbt", "Timeout & max-bytes",
     "The timeout middleware, which starts a moonward Deadline per request and "
     "enforces it on the response path (preemptive cancel is the async boundary), "
     "and maxbytes, which rejects an over-limit Content-Length with 413."),
    ("logging", "rest/handler/logging.mbt", "Structured logging",
     "RequestLog captures typed access-log fields (method, path, status, "
     "duration, request-id, client-ip, user-agent) and renders one JSON line "
     "per request; the structured_logging middleware emits it, timed on the clock."),
    ("limiting", ("limit/maxconns.mbt", "limit/periodlimit.mbt"), "Admission control",
     "The concurrency limiter that sheds load past a ceiling — releasing its permit "
     "with defer, so cancellation cannot wedge it shut — and the period limiter that "
     "counts requests per window."),
    ("conf", "conf/conf.mbt", "Config keys",
     "The canonical config-key form: lowercased, `_` and `-` dropped, so MaxBytes, "
     "maxBytes, max_bytes and max-bytes all name one field and a config document "
     "written in any of them loads unchanged."),
    ("restconf", "conf/rest.mbt", "Engine configuration",
     "Which built-in layers the engine installs (`MiddlewaresConf`), every flag on by "
     "default, so an etc/*.yaml that says nothing about middleware still gets the whole "
     "chain."),
    ("logx", "logx/logx.mbt", "Logging",
     "Structured logging over moonlog's sink: the four level names an etc/*.yaml "
     "carries, the @timestamp / content keys a collector indexes, the WithDuration "
     "view, and a logger whose level and destination move at runtime."),
    ("refusal", "rest/handler/refusal.mbt", "Turning a request away",
     "What a request refused by a middleware receives: 503 for an open breaker, a spent "
     "connection budget or a passed deadline, 429 for a rate limit, 413 for a body too "
     "large. Each is a parameter."),
    ("shedder", "shedder/shedder.mbt", "Load shedding",
     "The adaptive shedder over moonward's, wired from RestConf.CpuThreshold: "
     "while the CPU is above the threshold, or was within the last second, it sheds "
     "once more requests are in flight than recent throughput and latency can carry."),
    ("route", "rest/route.mbt", "Route options",
     "The settings a route carries into its own registration: a JWT with a rotation "
     "window, a signature verifier, a deadline, a body cap, the priority shedder, a "
     "prefix and server-sent events. Each is a field of RouteOptions and a hoop on "
     "the route."),
    ("hoops", "rest/hoops.mbt", "Route-level checks",
     "One hoop per option that can refuse a request, applied where the route is "
     "registered: the token, the signature, the declared body length, the deadline "
     "enforced by racing the handler, the shedder's ticket, and the event-stream "
     "headers."),
    ("gunzip", "rest/handler/gunzip.mbt", "Compressed request bodies",
     "Read a Content-Encoding: gzip body, inflate it, and hand the application the "
     "plain bytes, with an optional cap on the inflated size so a compression bomb "
     "stops at the limit rather than in memory."),
    ("signature", "rest/handler/signature.mbt", "Content security",
     "The X-Content-Security request signature: an RSA-sealed envelope carrying the "
     "MAC key, the time and the payload type; a MAC over the timestamp, method, path, "
     "query and body digest; a tolerance on the timestamp; and an AES-ECB payload when "
     "the envelope says the body is sealed."),
    ("rsa", "rest/handler/rsa.mbt", "The envelope key",
     "The RSA decrypter a content-security key set is built from: raw RSA private "
     "operation, PKCS#1 v1.5 unpadding, and a PEM or DER reader that is a pure "
     "function of the text."),
    ("files", "rest/handler/files.mbt", "Static files",
     "A file-serving layer over an in-memory set: a GET under a prefix whose remaining "
     "path names a registered file is answered with it, with a content-derived ETag and "
     "a 304 for a conditional request. The bytes live in a value, so a test serves a "
     "file it built and a deployment loads a directory once."),
    ("metrics", "rest/handler/metrics.mbt", "Request metrics",
     "Two Prometheus families over the process registry: a duration histogram and a "
     "code counter, labelled path, method and code — three labels, so a dashboard can "
     "select on any one of them."),
    ("tracing", "rest/handler/tracing.mbt", "Tracing",
     "A server span per request, joined to the trace the request arrived with and "
     "written to whatever sink the tracer was built over, plus the convenience "
     "x-trace-id header next to the standard traceparent."),
    ("telemetry", "telemetry/telemetry.mbt", "The default tracer",
     "The tracer a service runs on when nobody configured one: ids from the platform "
     "entropy source, spans to a caller-named sink, and every request sampled."),
    ("interceptor", "zrpc/interceptor.mbt", "The interceptor chain",
     "One shape for both halves of the wire: an invoker turns a call into a result, an "
     "interceptor wraps an invoker, and the transport is the innermost one."),
    ("clientinterceptors", "zrpc/client_interceptors.mbt", "Client interceptors",
     "Tracing, the duration log, the Prometheus families, the breaker and the "
     "deadline — the five layers a call passes on its way out."),
    ("serverinterceptors", "zrpc/server_interceptors.mbt", "Server interceptors",
     "Authentication, tracing, recovery, the stat log, the Prometheus families, the "
     "breaker, shedding and the deadline — the eight layers a call passes on its way "
     "in, with authentication outermost so a refused peer cannot push the breaker "
     "open."),
    ("rpcconf", "conf/rpc.mbt", "zRPC configuration",
     "The server and client blocks: the timeout, both CPU thresholds, authentication, "
     "and one flag per interceptor, all loading from a config document with their "
     "defaults."),
    ("p2c", "balance/p2c.mbt", "Power of two choices",
     "Choose two instances at random and take the less loaded: sqrt(lag + 1) * "
     "(inflight + 1), with the lag and success counts moving averages that decay over "
     "ten seconds and a one-second window after which an unpicked instance is forced."),
    ("cache", "stores/cache/cache.mbt", "Cache aside",
     "Read through a store, run the loader once per key however many callers arrive, "
     "and write the answer back with a jittered lifetime. An absent value is not "
     "cached."),
    ("sql", "stores/sql/sql.mbt", "SQL",
     "Statements, rows, single values and transactions over a database driver the "
     "caller supplies; a transaction commits when its body returns and rolls back when "
     "it raises."),
    ("syncx", "syncx/singleflight.mbt", "One call in flight per key",
     "A second caller asking for a key while the first is still running waits for that "
     "answer instead of issuing a second call, and every one of them receives the same "
     "result or the same failure."),
    ("collection", "collection/cache.mbt", "Bounded containers",
     "A cache with a size limit and an optional expiry over a doubly linked recency "
     "list, so a hit is constant work, and a fixed-size ring that keeps the newest "
     "samples."),
    ("mr", "mr/mapreduce.mbt", "Map-reduce",
     "A mapper that sees one item and emits any number of values, a finish step for "
     "the aggregate that only makes sense at the end, and a reducer over everything "
     "emitted — sequentially or across tasks, with the parallel run emitting in input "
     "order."),
    ("fx", "fx/retry.mbt", "Retrying and deadlines",
     "Call a body until it stops raising, with a predicate that stops the ladder early "
     "for a failure that will not change; the same over a backoff; and a deadline that "
     "tells a slow answer (None) from a wrong one (an error)."),
    ("threading", "threading/runner.mbt", "Tasks and queues",
     "A fan-out group that is collected first and joined at wait, a queue drained by "
     "one consumer for work that must not run on the request's own task, and a queue "
     "that keeps only the newest pending item so a burst collapses to its last value."),
    ("services", "service/group.mbt", "Running several services",
     "A group whose members share one lifetime: every service is a task that runs "
     "until it returns or is cancelled, so a failure cancels the rest instead of "
     "leaving half a process running."),
    ("redis", "stores/redis/store.mbt", "The redis store",
     "The same Store contract the memory store implements, over a redis client and a "
     "key prefix, so a cache moves from one process to a fleet by changing the value "
     "passed in — plus the counter and expiry operations a cache does not use."),
    ("once", "syncx/once.mbt", "One-time bodies and pools",
     "A body that runs at most once, for the initialisation that must not happen "
     "twice, and a pool that builds its objects on the first take and hands them back."),
]
KIND = {"struct": "struct", "enum": "enum", "fn": "fn", "type": "type", "let": "let"}


def top_level_brace(s):
    """Where the declaration's body starts: the first `{` that is not inside a
    parameter list. `len(s)` when the declaration ends before a brace."""
    depth = 0
    for at, ch in enumerate(s):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "{" and depth == 0:
            return at
    return len(s)


def parse(path):
    items, doc = [], []
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s == "///|":
            doc = []
        elif s.startswith("///"):
            doc.append(s[3:].strip())
        elif s.startswith("pub"):
            buf = s
            # A declaration runs until its parentheses close: a default value may
            # carry a `catch { … }`, so a brace alone does not end it, and a doc
            # comment or the next declaration never belongs to it.
            depth = buf.count("(") - buf.count(")")
            while depth > 0 and i + 1 < len(lines):
                nxt = lines[i + 1].strip()
                if nxt.startswith("//") or nxt.startswith("pub"):
                    break
                i += 1
                buf += " " + nxt
                depth = buf.count("(") - buf.count(")")
            core = buf[:top_level_brace(buf)]
            core = re.sub(r"^pub(?:\(all\))?\s+", "", core).strip()
            core = re.sub(r"\s+", " ", core).rstrip(",").rstrip()
            core = re.sub(r",\s*\)", ")", core)
            first = core.split(" ")[0] if core else ""
            items.append((KIND.get(first, "item"), core, " ".join(doc).strip()))
            doc = []
        elif s == "":
            pass
        else:
            doc = []
        i += 1
    return items


def tint(sig):
    s = html.escape(sig)
    s = re.sub(r"\b(fn|struct|enum|type|let|async)\b", r'<span class="k">\1</span>', s)
    s = re.sub(r"\b([A-Z][A-Za-z0-9_]*)\b", r'<span class="ty">\1</span>', s)
    s = s.replace("-&gt;", '<span class="op">-&gt;</span>').replace("?", '<span class="op">?</span>')
    return s


def prose(t):
    t = html.escape(t)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)


CSS = r"""
:root{
  --bg:#fbfbfd; --panel:#ffffff; --panel-2:#f6f7fb; --ink:#14181f;
  --muted:#5b6675; --line:#e8ebf1; --accent:#6d5efc; --accent-soft:#efecff; --out:#0ca678;
  --code-bg:#f4f5f9; --shadow:0 1px 2px rgba(20,24,31,.04),0 8px 24px -12px rgba(20,24,31,.10);
}
@media (prefers-color-scheme:dark){:root{
  --bg:#0b0e14; --panel:#131722; --panel-2:#0f131c; --ink:#e9edf6; --muted:#96a1b5;
  --line:#212736; --accent:#9d8bff; --accent-soft:#1c1b3a; --out:#2dd4a7;
  --code-bg:#161b26; --shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -14px rgba(0,0,0,.5);
}}
:root[data-theme=light]{--bg:#fbfbfd;--panel:#fff;--panel-2:#f6f7fb;--ink:#14181f;--muted:#5b6675;--line:#e8ebf1;--accent:#6d5efc;--accent-soft:#efecff;--out:#0ca678;--code-bg:#f4f5f9;--shadow:0 1px 2px rgba(20,24,31,.04),0 8px 24px -12px rgba(20,24,31,.10)}
:root[data-theme=dark]{--bg:#0b0e14;--panel:#131722;--panel-2:#0f131c;--ink:#e9edf6;--muted:#96a1b5;--line:#212736;--accent:#9d8bff;--accent-soft:#1c1b3a;--out:#2dd4a7;--code-bg:#161b26;--shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -14px rgba(0,0,0,.5)}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{animation:none!important;transition:none!important}}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:"IBM Plex Sans",system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
  font-size:15.5px;line-height:1.6;-webkit-font-smoothing:antialiased}
code,pre,.mono{font-family:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.layout{display:grid;grid-template-columns:264px minmax(0,1fr);max-width:1180px;margin:0 auto}
.sidebar{position:sticky;top:0;align-self:start;height:100vh;overflow-y:auto;
  border-right:1px solid var(--line);padding:1.6rem 1.1rem 2rem;background:var(--panel-2)}
.brand{display:flex;align-items:center;gap:.55rem;font-family:"IBM Plex Mono";font-weight:600;
  font-size:1.35rem;letter-spacing:-.01em;color:var(--ink);margin-bottom:.15rem}
.brand .dot{width:11px;height:11px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 4px var(--accent-soft)}
.brand-sub{color:var(--muted);font-size:.8rem;margin:0 0 1.3rem;padding-left:.15rem}
.side-nav{display:flex;flex-direction:column;gap:.1rem}
.side-nav a{color:var(--muted);font-size:.9rem;padding:.32rem .6rem;border-radius:8px;
  font-family:"IBM Plex Mono";display:flex;align-items:center;gap:.4rem;border-left:2px solid transparent}
.side-nav a .at{color:var(--accent);opacity:.6}
.side-nav a:hover{background:var(--accent-soft);color:var(--ink);text-decoration:none}
.side-nav a.active{color:var(--ink);background:var(--accent-soft);border-left-color:var(--accent);font-weight:500}
.side-nav a.active .at{opacity:1}
.side-foot{margin-top:1.6rem;padding-top:1.1rem;border-top:1px solid var(--line);display:flex;flex-wrap:wrap;gap:.4rem}
.side-foot img{height:20px;display:block}
.theme-btn{margin-top:1rem;background:none;border:1px solid var(--line);color:var(--muted);
  border-radius:8px;padding:.35rem .6rem;font:inherit;font-size:.82rem;cursor:pointer;width:100%}
.theme-btn:hover{border-color:var(--accent);color:var(--ink)}
main{padding:2.6rem 2.4rem 5rem;min-width:0}
.hero h1{font-family:"IBM Plex Mono";font-weight:600;font-size:2.9rem;letter-spacing:-.02em;margin:0}
.hero .tag{color:var(--muted);font-size:1.12rem;max-width:62ch;margin:.5rem 0 1.1rem;text-wrap:balance}
.badges{display:flex;flex-wrap:wrap;gap:.45rem;margin:0 0 1.4rem}
.badges img{height:21px;display:block}
.install{display:flex;align-items:center;gap:.6rem;background:var(--panel);border:1px solid var(--line);
  border-radius:12px;padding:.65rem 1rem;box-shadow:var(--shadow);max-width:420px}
.install .prompt{color:var(--out);user-select:none;font-weight:600}
.install code{flex:1;font-size:.95rem}
.copy{background:none;border:1px solid var(--line);border-radius:7px;color:var(--muted);
  cursor:pointer;font:inherit;font-size:.72rem;padding:.2rem .5rem}
.copy:hover{border-color:var(--accent);color:var(--accent)}
.copy.ok{color:var(--out);border-color:var(--out)}
.contract{margin:2.1rem 0 .5rem;background:
   radial-gradient(120% 130% at 100% 0%, var(--accent-soft) 0%, transparent 55%), var(--panel);
  border:1px solid var(--line);border-radius:16px;padding:1.2rem 1.4rem;box-shadow:var(--shadow)}
.contract h2{margin:0 0 .6rem;font-size:1.06rem;display:flex;align-items:center;gap:.5rem}
.contract h2 .spark{color:var(--accent)}
.contract pre{margin:0;overflow-x:auto;font-size:.92rem;line-height:1.7}
.contract .k{color:#8b5cf6;font-weight:500}.contract .ty{color:var(--accent)}.contract .op{color:var(--muted)}
section.pkg{scroll-margin-top:1.2rem;padding-top:2.4rem;margin-top:2rem;border-top:1px solid var(--line)}
section.pkg > h2{font-family:"IBM Plex Mono";font-size:1.55rem;margin:0 0 .15rem;letter-spacing:-.01em}
section.pkg > h2 .at{color:var(--accent)}
.pdesc{color:var(--muted);margin:.15rem 0 1.2rem;max-width:72ch}
.item{background:var(--panel);border:1px solid var(--line);border-radius:13px;
  padding:1rem 1.2rem;margin:.85rem 0;box-shadow:var(--shadow);transition:border-color .15s,transform .15s}
.item:hover{border-color:color-mix(in oklab,var(--accent) 40%,var(--line))}
.kind{display:inline-block;font-size:.66rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;
  border-radius:6px;padding:.1rem .45rem;margin-bottom:.55rem;
  color:var(--accent);background:var(--accent-soft);border:1px solid color-mix(in oklab,var(--accent) 26%,transparent)}
.item[data-k=struct] .kind{--c:#8b5cf6}.item[data-k=fn] .kind{--c:#0ca678}.item[data-k=let] .kind{--c:#2563eb}
.item[data-k=enum] .kind{--c:#d6336c}.item[data-k=type] .kind{--c:#0891b2}
.item .kind{color:var(--c,var(--accent));background:color-mix(in oklab,var(--c,var(--accent)) 13%,transparent);
  border-color:color-mix(in oklab,var(--c,var(--accent)) 30%,transparent)}
.sig{font-size:.98rem;margin:0 0 .55rem;overflow-x:auto;white-space:pre;color:var(--ink);padding-bottom:.15rem}
.sig .k{color:#8b5cf6;font-weight:500}.sig .ty{color:var(--accent)}.sig .op{color:var(--muted)}
@media (prefers-color-scheme:dark){.sig .k,.contract .k{color:#b794ff}}
.doc{margin:0;color:var(--ink);max-width:76ch}
.doc code{background:var(--code-bg);padding:.06rem .35rem;border-radius:5px;font-size:.9em;color:var(--accent)}
footer{margin-top:3rem;padding-top:1.3rem;border-top:1px solid var(--line);color:var(--muted);font-size:.9rem}
@media (max-width:820px){
  .layout{grid-template-columns:1fr}
  .sidebar{position:static;height:auto;border-right:none;border-bottom:1px solid var(--line)}
  .side-nav{flex-flow:row wrap}.side-nav a{border-left:none}.side-nav a.active{border-left:none}
  main{padding:1.8rem 1.2rem 4rem}.hero h1{font-size:2.2rem}
}
"""

JS = r"""
document.addEventListener("DOMContentLoaded",()=>{
  document.querySelectorAll("[data-copy]").forEach(btn=>btn.addEventListener("click",()=>{
    navigator.clipboard.writeText(btn.getAttribute("data-copy")).then(()=>{
      const t=btn.textContent;btn.textContent="copied";btn.classList.add("ok");
      setTimeout(()=>{btn.textContent=t;btn.classList.remove("ok");},1100);});}));
  const links=[...document.querySelectorAll(".side-nav a")];
  const map=Object.fromEntries(links.map(a=>[a.getAttribute("href").slice(1),a]));
  const spy=new IntersectionObserver(es=>{es.forEach(e=>{if(e.isIntersecting){
    links.forEach(a=>a.classList.remove("active"));const a=map[e.target.id];if(a)a.classList.add("active");}});},
    {rootMargin:"-10% 0px -80% 0px"});
  document.querySelectorAll("section.pkg").forEach(s=>spy.observe(s));
  const tb=document.getElementById("theme");if(tb)tb.addEventListener("click",()=>{
    const cur=document.documentElement.getAttribute("data-theme")
      ||(matchMedia("(prefers-color-scheme:dark)").matches?"dark":"light");
    document.documentElement.setAttribute("data-theme",cur==="dark"?"light":"dark");});
});
"""
