///|
/// Build a synthetic request for routing assertions.
fn mkreq(m : String, path : String) -> @moonasgi.Request {
  { http_method: m, path, query_string: b"", headers: [], body: b"", }
}
