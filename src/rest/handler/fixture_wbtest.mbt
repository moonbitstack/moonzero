///|
/// A scope carrying only the given request headers, for middleware unit tests.
fn scope_with(headers : Array[(String, String)]) -> @moonasgi.Scope {
  @moonasgi.Scope::Http({
    http_version: "1.1",
    http_method: "GET",
    scheme: "http",
    path: "/",
    raw_path: Some(b"/"),
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

///|
/// Drive an app with one empty request and collect the events it sends, so a
/// middleware's decision is visible as the wire events it produced.
async fn run_app(
  app : @moonasgi.AsgiApp,
  scope : @moonasgi.Scope,
) -> Array[@moonasgi.Event] {
  let events : Array[@moonasgi.Event] = []
  let sent : Ref[Bool] = { val: false, }
  let receive : @moonasgi.Receive = () => {
    if sent.val {
      @moonasgi.Event::HttpDisconnect
    } else {
      sent.val = true
      @moonasgi.Event::HttpRequest(body=b"", more_body=false)
    }
  }
  app(scope, receive, event => events.push(event))
  events
}
