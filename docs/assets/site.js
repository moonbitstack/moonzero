/* moonzero site — theme, topology scenes, palette, copy, and the lab benches.
   No dependencies: everything here runs from a static file. */
(function () {
  "use strict";

  var root = document.documentElement;
  var scheme = window.matchMedia
    ? window.matchMedia("(prefers-color-scheme: dark)")
    : null;

  /* ---------- theme ---------- */

  function normalise(value) {
    return value === "day" || value === "night" ? value : null;
  }

  function systemTheme() {
    return scheme && scheme.matches ? "night" : "day";
  }

  function storedTheme() {
    try {
      return normalise(localStorage.getItem("mz-theme"));
    } catch (e) {
      return null;
    }
  }

  function urlTheme() {
    try {
      return normalise(new URLSearchParams(location.search).get("theme"));
    } catch (e) {
      return null;
    }
  }

  function applyTheme(theme) {
    root.setAttribute("data-theme", theme);
    var btns = document.querySelectorAll("[data-theme-set]");
    for (var i = 0; i < btns.length; i++) {
      btns[i].setAttribute(
        "aria-current",
        btns[i].getAttribute("data-theme-set") === theme ? "true" : "false"
      );
    }
  }

  function setTheme(theme) {
    theme = normalise(theme);
    if (!theme) return;
    applyTheme(theme);
    try {
      localStorage.setItem("mz-theme", theme);
    } catch (e) {}
  }

  applyTheme(
    normalise(root.getAttribute("data-theme")) ||
      urlTheme() ||
      storedTheme() ||
      systemTheme()
  );

  /* Until the reader picks a side, the page keeps listening to the system. */
  if (scheme) {
    var followSystem = function () {
      if (urlTheme() || storedTheme()) return;
      applyTheme(systemTheme());
    };
    if (scheme.addEventListener) scheme.addEventListener("change", followSystem);
    else if (scheme.addListener) scheme.addListener(followSystem);
  }

  document.addEventListener("click", function (event) {
    var setter = event.target.closest && event.target.closest("[data-theme-set]");
    if (setter) {
      setTheme(setter.getAttribute("data-theme-set"));
      return;
    }
    // Keyboard activation lands on the button itself, not on a span.
    if (event.target.closest && event.target.closest(".theme")) {
      setTheme(root.getAttribute("data-theme") === "night" ? "day" : "night");
    }
  });

  /* ---------- copy buttons ---------- */

  document.addEventListener("click", function (event) {
    var btn = event.target.closest && event.target.closest("[data-copy]");
    if (!btn) return;
    var sel = btn.getAttribute("data-copy");
    var node = sel === "self" ? btn : document.querySelector(sel);
    if (!node) return;
    var text = node.innerText;
    var done = function () {
      var old = btn.textContent;
      btn.textContent = "COPIED";
      setTimeout(function () {
        btn.textContent = old;
      }, 1400);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, done);
    } else {
      var area = document.createElement("textarea");
      area.value = text;
      document.body.appendChild(area);
      area.select();
      try {
        document.execCommand("copy");
      } catch (e) {}
      document.body.removeChild(area);
      done();
    }
  });

  /* ---------- topology scenes ---------- */

  var scenes = {
    healthy: {
      state: "all healthy",
      req: "12.4k",
      p99: "3.1 ms",
      shed: "0.0%",
      shedTone: "ok",
      trace:
        "18:02:11.412    GET /api/v1/orders    200    2.1ms    ·    p2c chose b    ·    cache hit    ·    span 4bf9…",
      note: "every instance answering"
    },
    slow: {
      state: "one instance slow",
      req: "11.9k",
      p99: "41 ms",
      shed: "0.8%",
      shedTone: "warn",
      trace:
        "18:02:11.412    GET /api/v1/orders    200    41ms    ·    p2c avoided c    ·    cache hit    ·    span 4bf9…",
      note: "traffic moved off c"
    },
    down: {
      state: "redis down",
      req: "8.2k",
      p99: "6.0 ms",
      shed: "12.4%",
      shedTone: "warn",
      trace:
        "18:02:11.412    GET /api/v1/orders    429    1.2ms    ·    local bucket    ·    redis unreachable    ·    span 4bf9…",
      note: "limiters on the local bucket"
    }
  };

  function setScene(name) {
    var screen = document.querySelector(".screen");
    if (!screen || !scenes[name]) return;
    var scene = scenes[name];
    screen.setAttribute("data-scene", name);

    var picks = screen.querySelectorAll("[data-scene-set]");
    for (var i = 0; i < picks.length; i++) {
      picks[i].setAttribute(
        "aria-pressed",
        picks[i].getAttribute("data-scene-set") === name ? "true" : "false"
      );
    }

    var state = screen.querySelector("[data-scene-state]");
    if (state) state.textContent = scene.state;
    var req = screen.querySelector("[data-scene-req]");
    if (req) req.textContent = scene.req;
    var p99 = screen.querySelector("[data-scene-p99]");
    if (p99) p99.textContent = scene.p99;
    var shed = document.querySelector("[data-scene-shed]");
    if (shed) {
      shed.textContent = scene.shed;
      shed.className = "v " + scene.shedTone;
    }
    var trace = document.querySelector("[data-scene-trace]");
    if (trace) trace.textContent = scene.trace;
    var note = document.querySelector("[data-scene-note]");
    if (note) note.textContent = scene.note;

    var chips = screen.querySelectorAll("[data-node]");
    for (var j = 0; j < chips.length; j++) {
      chips[j].classList.remove("warn", "hot");
    }
    var hot = {
      healthy: [],
      slow: ["balance", "p2c", "c"],
      down: ["limit", "redis"]
    }[name];
    for (var k = 0; k < hot.length; k++) {
      var chip = screen.querySelector('[data-node="' + hot[k] + '"]');
      if (chip) chip.classList.add("warn");
    }
  }

  document.addEventListener("click", function (event) {
    var pick = event.target.closest && event.target.closest("[data-scene-set]");
    if (!pick) return;
    setScene(pick.getAttribute("data-scene-set"));
  });

  /* ---------- command palette ---------- */

  var palette = document.querySelector(".palette");
  var index = [];
  var data = document.getElementById("site-index");
  if (data) {
    try {
      index = JSON.parse(data.textContent);
    } catch (e) {
      index = [];
    }
  }

  function renderPalette(query) {
    var list = palette.querySelector("ul");
    var q = query.trim().toLowerCase();
    var out = [];
    for (var i = 0; i < index.length && out.length < 40; i++) {
      var item = index[i];
      var hay = (item.name + " " + item.lane + " " + item.summary).toLowerCase();
      if (q && hay.indexOf(q) === -1) continue;
      out.push(item);
    }
    var html = "";
    for (var j = 0; j < out.length; j++) {
      html +=
        '<li><a href="' +
        out[j].href +
        '"' +
        (j === 0 ? ' aria-selected="true"' : "") +
        "><b>" +
        out[j].name +
        "</b><span>" +
        out[j].summary +
        "</span><small>" +
        out[j].lane +
        "</small></a></li>";
    }
    list.innerHTML = html || '<li><a><span>nothing matches</span></a></li>';
  }

  function openPalette() {
    if (!palette) return;
    palette.setAttribute("open", "");
    var input = palette.querySelector("input");
    input.value = "";
    renderPalette("");
    input.focus();
  }

  function closePalette() {
    if (palette) palette.removeAttribute("open");
  }

  document.addEventListener("click", function (event) {
    if (event.target.closest && event.target.closest("[data-palette-open]")) {
      event.preventDefault();
      openPalette();
      return;
    }
    if (event.target === palette) closePalette();
  });

  document.addEventListener("keydown", function (event) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      palette && palette.hasAttribute("open") ? closePalette() : openPalette();
    } else if (event.key === "Escape") {
      closePalette();
    } else if (event.key === "Enter" && palette && palette.hasAttribute("open")) {
      var first = palette.querySelector('a[aria-selected="true"]');
      if (first) window.location.href = first.getAttribute("href");
    }
  });

  if (palette) {
    var input = palette.querySelector("input");
    input.addEventListener("input", function () {
      renderPalette(input.value);
    });
    input.addEventListener("keydown", function (event) {
      if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
      event.preventDefault();
      var links = palette.querySelectorAll("li a");
      if (!links.length) return;
      var at = 0;
      for (var i = 0; i < links.length; i++) {
        if (links[i].getAttribute("aria-selected") === "true") at = i;
      }
      var next = (at + (event.key === "ArrowDown" ? 1 : -1) + links.length) % links.length;
      for (var j = 0; j < links.length; j++) {
        if (j === next) links[j].setAttribute("aria-selected", "true");
        else links[j].removeAttribute("aria-selected");
      }
      links[next].scrollIntoView({ block: "nearest" });
    });
  }

  /* ---------- scroll spy ---------- */

  var toc = document.querySelector(".minimap .toc");
  if (toc && "IntersectionObserver" in window) {
    var anchors = [].slice.call(toc.querySelectorAll("a"));
    var targets = anchors
      .map(function (a) {
        return document.querySelector(a.getAttribute("href"));
      })
      .filter(Boolean);
    var seen = new Map();
    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          seen.set(entry.target.id, entry.isIntersecting);
        });
        var active = null;
        for (var i = 0; i < targets.length; i++) {
          if (seen.get(targets[i].id)) active = targets[i].id;
        }
        anchors.forEach(function (a) {
          a.classList.toggle("active", a.getAttribute("href") === "#" + active);
        });
      },
      { rootMargin: "-120px 0px -60% 0px" }
    );
    targets.forEach(function (t) {
      observer.observe(t);
    });
  }

  /* ---------- lab: the library, compiled to wasm ---------- */

  // Both benches are this library's own code: the docs workflow builds
  // src/examples/browser to engine/lab.wasm, and the page calls what it exports.
  // There is no JavaScript copy of either algorithm on this page.
  var benches = document.querySelectorAll("[data-bench]");
  var launch = [];
  function onEngine(fn) {
    launch.push(fn);
  }

  function explainMissingEngine() {
    for (var i = 0; i < benches.length; i++) {
      var out = benches[i].querySelector(".out");
      if (out) {
        out.innerHTML =
          '<span class="dim">this bench runs the library compiled to wasm; ' +
          "engine/lab.wasm is not here. Build it with\n\n" +
          "  moon build --target wasm --release src/examples/browser\n" +
          "  cp _build/wasm/release/build/examples/browser/browser.wasm docs/engine/lab.wasm</span>";
        out.style.whiteSpace = "pre-wrap";
      }
    }
  }

  if (benches.length) {
    // The module reads the platform clock through one import; the benches are driven
    // by a manual clock of their own, so the answer is never asked for.
    fetch("engine/lab.wasm")
      .then(function (res) {
        if (!res.ok) throw new Error(String(res.status));
        return res.arrayBuffer();
      })
      .then(function (buf) {
        return WebAssembly.instantiate(buf, {
          __moonbit_time_unstable: {
            now: function () {
              return BigInt(Date.now()) * 1000000n;
            }
          }
        });
      })
      .then(function (mod) {
        for (var i = 0; i < launch.length; i++) launch[i](mod.instance.exports);
      })
      .catch(explainMissingEngine);
  }

  /* ---------- lab: p2c ---------- */

  var bench = document.querySelector("[data-bench='p2c']");
  if (bench) {
    var latency = [
      bench.querySelector("#lat-a"),
      bench.querySelector("#lat-b"),
      bench.querySelector("#lat-c")
    ];
    var calls = bench.querySelector("#p2c-calls");
    var run = bench.querySelector("#p2c-run");

    onEngine(function (ex) {
      // One call to the library per run: it draws the pairs, takes the lighter, moves
      // the moving averages, and answers how many calls each instance received.
      function draw() {
        var lat = latency.map(function (s) {
          return Number(s.value);
        });
        var total = Number(calls.value);
        ex.mz_lab_p2c(lat[0], lat[1], lat[2], total);
        var picked = [0, 1, 2].map(function (i) {
          return ex.mz_lab_p2c_picks(i);
        });
        var loads = [0, 1, 2].map(function (i) {
          return ex.mz_lab_p2c_load(i);
        });
        var sum = picked[0] + picked[1] + picked[2];
        var bars = bench.querySelector(".bars");
        var names = ["a", "b", "c"];
        var html = "";
        for (var i = 0; i < 3; i++) {
          var share = sum ? picked[i] / sum : 0;
          html +=
            '<div class="barwrap"><div class="bar' +
            (i === 2 && share < 0.05 ? " hi" : "") +
            '" style="height:' +
            Math.max(2, Math.round(share * 80)) +
            'px" title="' +
            Math.round(share * 100) +
            '%"></div><span>' +
            names[i] +
            " · " +
            Math.round(share * 100) +
            "%</span></div>";
        }
        bars.innerHTML = html;
        bench.querySelector(".out").textContent =
          "a  " + picked[0] + " picks · load " + loads[0] + "\n" +
          "b  " + picked[1] + " picks · load " + loads[1] + "\n" +
          "c  " + picked[2] + " picks · load " + loads[2] + "\n" +
          "of " + sum + " calls · c is the slow instance";
        bench.querySelector("#lat-a-out").textContent = latency[0].value + " ms";
        bench.querySelector("#lat-b-out").textContent = latency[1].value + " ms";
        bench.querySelector("#lat-c-out").textContent = latency[2].value + " ms";
      }

      latency.forEach(function (s) {
        s.addEventListener("input", draw);
      });
      calls.addEventListener("change", draw);
      run.addEventListener("click", draw);
      draw();
    });
  }

  /* ---------- lab: token bucket ---------- */

  var bucketBench = document.querySelector("[data-bench='bucket']");
  if (bucketBench) {
    var rate = bucketBench.querySelector("#rate");
    var burst = bucketBench.querySelector("#burst");
    var demand = bucketBench.querySelector("#demand");
    var go = bucketBench.querySelector("#bucket-run");

    onEngine(function (ex) {
      // The bucket is the library's: `rate` a second, room for `burst`, one token a
      // request, and the clock handed in on each call.
      function bucket() {
        var r = Number(rate.value);
        var b = Number(burst.value);
        var d = Number(demand.value);
        var admitted = ex.mz_lab_bucket(r, b, d);
        var refused = ex.mz_lab_bucket_refused();
        var total = admitted + refused;
        bucketBench.querySelector(".out").textContent =
          "admitted  " + admitted + "\n" +
          "refused   " + refused + "\n" +
          "of " + total + " requests over 5s · " +
          Math.round((admitted / (total || 1)) * 100) + "% through";
        bucketBench.querySelector("#rate-out").textContent = r + " /s";
        bucketBench.querySelector("#burst-out").textContent = b + " tokens";
        bucketBench.querySelector("#demand-out").textContent = d + " /s";
      }

      [rate, burst, demand].forEach(function (s) {
        s.addEventListener("input", bucket);
      });
      go.addEventListener("click", bucket);
      bucket();
    });
  }
})();
