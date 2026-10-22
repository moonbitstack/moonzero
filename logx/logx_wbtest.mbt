///|
/// A logger writing into `lines` instead of stdout.
fn collecting(
  lines : Array[String],
  level~ : LogLevel = Info,
  clock? : @clock.Clock,
) -> Logger {
  Logger::new(
    clock.unwrap_or(@clock.ManualClock::new(start=233L).as_clock()),
    level~,
    sink=@moonlog.Lines::new(line => lines.push(line), format=entry),
  )
}

///|
/// Read a string field out of a rendered JSON log line.
fn json_str(j : Json, key : String) -> String {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// Read a numeric field out of a rendered JSON log line.
fn json_num(j : Json, key : String) -> Double {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(Number(n, ..)) => n
        _ => -1.0
      }
    _ => -1.0
  }
}

///|
test "a log call below the configured level produces nothing" {
  let lines : Array[String] = []
  let lg = collecting(lines, level=Error)
  lg.debug("emm")
  lg.info("hhh")
  assert_eq(lines.length(), 0)
  lg.error("qwq")
  lg.severe("orz")
  assert_eq(lines.length(), 2)
  assert_eq(json_str(@json.parse(lines[0]), "content"), "qwq")
  assert_eq(json_str(@json.parse(lines[1]), "level"), "severe")
}

///|
test "the threshold moves with set_level, for derived views too" {
  let lines : Array[String] = []
  let lg = collecting(lines)
  let timed = lg.with_duration(23L)
  assert_eq(lg.enabled(Info), true)
  lg.set_level(Severe)
  assert_eq(lg.enabled(Info), false)
  lg.info("hhh")
  timed.info("hhh")
  assert_eq(lines.length(), 0)
  timed.severe("orz")
  assert_eq(lines.length(), 1)
}

///|
test "an entry carries timestamp, level, content, duration and fields" {
  let lines : Array[String] = []
  let lg = collecting(lines)
  lg
  .with_duration(66L)
  .info("GET /ping", fields=[
    ("status", Json::number(200.0)),
    ("request_id", Json::string("req-233")),
  ])
  let j = @json.parse(lines[0])
  assert_eq(json_num(j, "@timestamp"), 233.0)
  assert_eq(json_str(j, "level"), "info")
  assert_eq(json_str(j, "content"), "GET /ping")
  assert_eq(json_num(j, "duration"), 66.0)
  assert_eq(json_num(j, "status"), 200.0)
  assert_eq(json_str(j, "request_id"), "req-233")
  // no duration on a plain logger
  lg.info("hhh")
  assert_eq(json_num(@json.parse(lines[1]), "duration"), -1.0)
}

///|
test "the process logger takes a level and a writer" {
  let lines : Array[String] = []
  let restore = logx.level()
  defer {
    set_log_level(restore)
    set_log_writer(line => println(line))
  }
  set_log_writer(line => lines.push(line))
  set_log_level(Error)
  logx.info("hhh")
  assert_eq(lines.length(), 0)
  logx.error("qwq")
  assert_eq(lines.length(), 1)
  assert_eq(json_str(@json.parse(lines[0]), "content"), "qwq")
}
