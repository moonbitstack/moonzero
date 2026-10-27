///|
/// Log verbosity (← go-zero's `LogConf.Level`), ordered from most to least
/// verbose. `Compare` follows that order so thresholds can be tested directly.
pub(all) enum LogLevel {
  Debug
  Info
  Error
  Severe
} derive(Eq, Compare, Debug)

///|
/// The canonical lowercase name go-zero uses on the wire.
pub fn LogLevel::to_string(self : LogLevel) -> String {
  match self {
    Debug => "debug"
    Info => "info"
    Error => "error"
    Severe => "severe"
  }
}

///|
/// The `moonlog` level this one records as. go-zero's ladder has four rungs and
/// `moonlog`'s has six, so the map is one-way: `Severe` records as `Fatal`, and
/// [`level_name`] writes it back out as `severe`.
pub fn LogLevel::as_level(self : LogLevel) -> @moonlog.Level {
  match self {
    Debug => Debug
    Info => Info
    Error => Error
    Severe => Fatal
  }
}

///|
/// Parse a level name, falling back to `Info` for anything unrecognised — the
/// same lenient default go-zero applies to a missing/empty level.
pub fn LogLevel::parse(s : String) -> LogLevel {
  match s {
    "debug" => Debug
    "error" => Error
    "severe" => Severe
    _ => Info
  }
}

///|
pub extend LogLevel with Compare::{op_lt, op_le, op_ge, compare, op_gt}

///|
pub extend LogLevel with Debug::{to_repr}

///|
pub extend LogLevel with Eq::{not_equal, equal}

///|
pub extend LogLevel with FromJson::{from_json}

///|
/// Decode a `LogLevel` from a JSON string (`"debug"`/`"info"`/`"error"`/
/// `"severe"`), reusing `LogLevel::parse`'s lenient fallback to `Info`. This impl
/// lets `ServiceConf`'s derived `FromJson` read `log_level` as a plain string —
/// the way go-zero writes it in YAML/JSON config — instead of a tagged variant.
pub impl @json.FromJson for LogLevel with fn from_json(json, path) {
  match json {
    String(s) => LogLevel::parse(s)
    _ => raise @json.JsonDecodeError((path, "log level must be a JSON string"))
  }
}
