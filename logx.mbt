// go-zero's `logx`, over `moonlog`'s sink.
//
// What stays here is go-zero's: the four level names its `etc/*.yaml` carries,
// the `@timestamp`/`content` keys its collectors index, the `WithDuration`
// view, and a process-wide logger whose level and destination move at runtime.
// What a record is, and where one goes, is `moonlog`'s — so a service can point
// moonzero, mooncat and anything else in the family at one sink.

///|
/// The bits of a logger that are shared by every view derived from it, so
/// `set_level` on the process logger is seen by a `with_duration` view taken
/// before it (← logx's package-level level and writer).
struct LogState {
  mut level : LogLevel
  mut sink : &@moonlog.Sink
}

///|
/// A leveled, structured logger (← go-zero's `logx`): entries below the
/// configured level are dropped without being rendered, and everything else
/// reaches the sink as one record carrying `@timestamp`, `level`, `content`, an
/// optional `duration`, and any extra fields.
///
/// The timestamp is milliseconds from the injected `Clock`, not a formatted
/// calendar time: MoonBit has no portable date formatter, and the clock is
/// already how every other timed layer here reads the time.
pub struct Logger {
  state : LogState
  clock : Clock
  duration_ms : Int64?
}

///|
/// The key the entry's time is written under (← go-zero's `logx`, which names
/// it for Elasticsearch's own field).
pub let stamp_key : String = "@timestamp"

///|
/// The key the message is written under (← go-zero's `logx.content`, where zap
/// and `slog` would write `msg`).
pub let message_key : String = "content"

///|
/// The key the elapsed time is written under.
pub let duration_key : String = "duration"

///|
/// One entry as the single-line JSON object go-zero emits: `@timestamp`,
/// `level`, `content`, then whatever else the entry carries.
///
/// This is the default sink's format, not a rule — hand `Logger::new` another
/// `moonlog` sink and the same records are rendered that sink's way.
pub fn entry(record : @moonlog.Record) -> String {
  let out : Map[String, Json] = Map([])
  for field in record.fields {
    if field.0 == stamp_key {
      out[stamp_key] = field.1
    }
  }
  out[@moonlog.level_key] = Json::string(level_name(record.level))
  out[message_key] = Json::string(record.message)
  for field in record.fields {
    if field.0 != stamp_key {
      out[field.0] = field.1
    }
  }
  Json::object(out).stringify()
}

///|
/// go-zero's name for a level. `Fatal` reads as `severe`, which is what go-zero
/// calls its top level and what its collectors filter on.
pub fn level_name(level : @moonlog.Level) -> String {
  match level {
    Trace => "trace"
    Debug => "debug"
    Info => "info"
    Warning => "warn"
    Error => "error"
    Fatal => "severe"
  }
}

///|
/// A logger writing to `sink` at `level` and above.
///
/// The default sink prints one [`entry`] per line. `Logger::new(clock,
/// sink=@moonlog.Discard::{  })` is how a test silences one.
pub fn Logger::new(
  clock : Clock,
  level? : LogLevel = Info,
  sink? : &@moonlog.Sink = @moonlog.Lines::new(
    line => println(line),
    format=entry,
  ),
) -> Logger {
  { state: { level, sink, }, clock, duration_ms: None, }
}

///|
/// The level below which entries are dropped.
pub fn Logger::level(self : Logger) -> LogLevel {
  self.state.level
}

///|
/// Raise or lower the threshold (← `logx.SetLevel`), for this logger and every
/// view derived from it.
pub fn Logger::set_level(self : Logger, level : LogLevel) -> Unit {
  self.state.level = level
}

///|
/// Send entries to another sink, for this logger and every view derived from
/// it — a file, a collector client, a buffer under test.
pub fn Logger::set_sink(self : Logger, sink : &@moonlog.Sink) -> Unit {
  self.state.sink = sink
}

///|
/// Send entries somewhere other than stdout (← `logx.SetWriter`), keeping
/// go-zero's line format. [`Logger::set_sink`] changes the format too.
pub fn Logger::set_writer(self : Logger, writer : (String) -> Unit) -> Unit {
  self.state.sink = @moonlog.Lines::new(writer, format=entry)
}

///|
/// Whether an entry at `level` would be written.
pub fn Logger::enabled(self : Logger, level : LogLevel) -> Bool {
  level >= self.state.level
}

///|
/// A view of this logger that stamps `duration` on every entry (←
/// `logx.WithDuration`), sharing the level and sink with the original.
pub fn Logger::with_duration(self : Logger, ms : Int64) -> Logger {
  { state: self.state, clock: self.clock, duration_ms: Some(ms), }
}

///|
/// Render and write one entry, unless `level` is below the threshold.
pub fn Logger::log(
  self : Logger,
  level : LogLevel,
  content : String,
  fields? : Array[(String, Json)] = [],
) -> Unit {
  if !self.enabled(level) {
    return
  }
  let carried : Array[(String, Json)] = [
    (stamp_key, Json::number(self.clock.now().to_double())),
  ]
  match self.duration_ms {
    Some(ms) => carried.push((duration_key, Json::number(ms.to_double())))
    None => ()
  }
  for field in fields {
    carried.push(field)
  }
  self.state.sink.write({
    level: level.as_level(),
    message: content,
    fields: carried,
  })
}

///|
/// Write a `debug` entry.
pub fn Logger::debug(
  self : Logger,
  content : String,
  fields? : Array[(String, Json)] = [],
) -> Unit {
  self.log(Debug, content, fields~)
}

///|
/// Write an `info` entry.
pub fn Logger::info(
  self : Logger,
  content : String,
  fields? : Array[(String, Json)] = [],
) -> Unit {
  self.log(Info, content, fields~)
}

///|
/// Write an `error` entry.
pub fn Logger::error(
  self : Logger,
  content : String,
  fields? : Array[(String, Json)] = [],
) -> Unit {
  self.log(Error, content, fields~)
}

///|
/// Write a `severe` entry.
pub fn Logger::severe(
  self : Logger,
  content : String,
  fields? : Array[(String, Json)] = [],
) -> Unit {
  self.log(Severe, content, fields~)
}

///|
/// The process-wide logger (← logx's package-level logger): what the middlewares
/// write to when no logger is handed to them, on the system clock at `info`.
/// `RestEngine::new` points its level at the loaded `Log.Level`.
pub let logx : Logger = Logger::new(Clock::system())

///|
/// Set the process logger's level (← `logx.SetLevel`).
pub fn set_log_level(level : LogLevel) -> Unit {
  logx.set_level(level)
}

///|
/// Send the process logger's entries to `writer` (← `logx.SetWriter`).
pub fn set_log_writer(writer : (String) -> Unit) -> Unit {
  logx.set_writer(writer)
}

///|
/// Send the process logger's entries to `sink`.
pub fn set_log_sink(sink : &@moonlog.Sink) -> Unit {
  logx.set_sink(sink)
}
