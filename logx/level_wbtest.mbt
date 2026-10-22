///|
test "log level naming, parsing, and ordering" {
  assert_eq(LogLevel::Debug.to_string(), "debug")
  assert_eq(LogLevel::Info.to_string(), "info")
  assert_eq(LogLevel::Error.to_string(), "error")
  assert_eq(LogLevel::Severe.to_string(), "severe")
  assert_eq(LogLevel::parse("severe"), Severe)
  assert_eq(LogLevel::parse("debug"), Debug)
  assert_eq(LogLevel::parse("nonsense"), Info)
  assert_eq(LogLevel::Debug < LogLevel::Severe, true)
}
