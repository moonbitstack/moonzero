///|
/// A scope carrying only the given request headers, for middleware unit tests.
fn scope_with(headers : Array[(String, String)]) -> @moonasgi.Scope {
  @moonasgi.Scope::Http({
    http_version: "1.1",
    http_method: "GET",
    scheme: "http",
    path: "/",
    raw_path: b"/",
    query_string: b"",
    root_path: "",
    headers,
    client: None,
    server: None,
    asgi: @moonasgi.AsgiVersion::http(),
    extensions: @moonasgi.Extensions::none(),
    state: Map([]),
  })
}
