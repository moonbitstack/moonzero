// The static-file layer: a GET under a prefix that names a registered file is
// answered with it, and everything else reaches the application.

///|
/// A scope for one request: the verb, the path, and whatever headers the case
/// needs.
fn file_scope(
  verb : String,
  path : String,
  headers~ : Array[(String, String)] = [],
) -> @moonasgi.Scope {
  @moonasgi.Scope::Http({
    http_version: "1.1",
    http_method: verb,
    scheme: "http",
    path,
    raw_path: None,
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
/// An app that answers every request with `reached`, so a test can tell whether a
/// request fell through the file layer.
fn fallthrough(reached : Ref[Bool]) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    let _ = scope
    let _ = receive
    reached.val = true
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"app", more_body=false))
  }
}

///|
/// The status of an event list's response start.
fn status_of(events : Array[@moonasgi.Event]) -> Int32 {
  for event in events {
    match event {
      HttpResponseStart(status~, ..) => return status
      _ => ()
    }
  }
  0
}

///|
/// The body an event list carried.
fn body_of(events : Array[@moonasgi.Event]) -> Bytes {
  for event in events {
    match event {
      HttpResponseBody(body~, ..) => return body
      _ => ()
    }
  }
  b""
}

///|
/// The value of one response header, or `""`.
fn response_header(events : Array[@moonasgi.Event], name : String) -> String {
  for event in events {
    match event {
      HttpResponseStart(headers~, ..) =>
        for pair in headers {
          if pair.0 == name {
            return pair.1
          }
        }
      _ => ()
    }
  }
  ""
}

///|
/// A file set with one CSS file and one JSON file under `/static`.
fn static_files() -> Files {
  let files = Files::new()
  files.add("/app.css", b"body{margin:0}")
  files.add("/data.json", b"{\"a\":1}")
  files
}

///|
async test "a registered file is served with its type and an etag" {
  let reached : Ref[Bool] = { val: false, }
  let app = file_server(static_files(), "/static")(fallthrough(reached))
  let events = run_app(app, file_scope("GET", "/static/app.css"))
  assert_eq(status_of(events), 200)
  assert_eq(body_of(events), b"body{margin:0}")
  assert_eq(response_header(events, "content-type"), "text/css; charset=utf-8")
  assert_eq(response_header(events, "content-length"), "14")
  // A strong validator: quoted, derived from the bytes.
  assert_eq(response_header(events, "etag").has_prefix("\""), true)
  // The application never ran.
  assert_eq(reached.val, false)
}

///|
async test "HEAD gets the headers and no body" {
  let reached : Ref[Bool] = { val: false, }
  let app = file_server(static_files(), "/static")(fallthrough(reached))
  let events = run_app(app, file_scope("HEAD", "/static/data.json"))
  assert_eq(status_of(events), 200)
  assert_eq(response_header(events, "content-type"), "application/json")
  assert_eq(response_header(events, "content-length"), "7")
  assert_eq(body_of(events), b"")
}

///|
async test "a matching If-None-Match is answered 304 without the body" {
  let reached : Ref[Bool] = { val: false, }
  let files = static_files()
  let tag = files.get("/app.css").unwrap().etag()
  let app = file_server(files, "/static")(fallthrough(reached))
  let events = run_app(
    app,
    file_scope("GET", "/static/app.css", headers=[("if-none-match", tag)]),
  )
  assert_eq(status_of(events), 304)
  assert_eq(body_of(events), b"")
  // A different tag still gets the file.
  let stale = run_app(
    app,
    file_scope("GET", "/static/app.css", headers=[
      ("if-none-match", "\"other\""),
    ]),
  )
  assert_eq(status_of(stale), 200)
  assert_eq(body_of(stale), b"body{margin:0}")
}

///|
async test "a request outside the mount reaches the application" {
  let reached : Ref[Bool] = { val: false, }
  let app = file_server(static_files(), "/static")(fallthrough(reached))
  let events = run_app(app, file_scope("GET", "/api/ping"))
  assert_eq(reached.val, true)
  assert_eq(body_of(events), b"app")
}

///|
async test "the mount ends where its name ends" {
  let reached : Ref[Bool] = { val: false, }
  let files = Files::new()
  // Registered under the mount, not under a prefix of it that merely starts the
  // same way: `/staticx/app.css` must not be served out of this.
  files.add("/x/app.css", b"secret")
  let app = file_server(files, "/static")(fallthrough(reached))
  let events = run_app(app, file_scope("GET", "/staticx/app.css"))
  assert_eq(reached.val, true)
  assert_eq(body_of(events), b"app")
}

///|
async test "a path that walks up is not a file" {
  let reached : Ref[Bool] = { val: false, }
  let app = file_server(static_files(), "/static")(fallthrough(reached))
  // The set is keyed by normalised path, so there is nothing for `..` to reach.
  let events = run_app(app, file_scope("GET", "/static/../../etc/passwd"))
  assert_eq(reached.val, true)
  assert_eq(status_of(events), 200)
}

///|
async test "a method other than GET or HEAD reaches the application" {
  let reached : Ref[Bool] = { val: false, }
  let app = file_server(static_files(), "/static")(fallthrough(reached))
  let events = run_app(app, file_scope("POST", "/static/app.css"))
  assert_eq(reached.val, true)
  assert_eq(body_of(events), b"app")
}

///|
async test "a mount at the root serves the whole path space" {
  let reached : Ref[Bool] = { val: false, }
  let app = file_server(static_files(), "/")(fallthrough(reached))
  let events = run_app(app, file_scope("GET", "/data.json"))
  assert_eq(status_of(events), 200)
  assert_eq(body_of(events), b"{\"a\":1}")
  assert_eq(reached.val, false)
}

///|
test "a media type comes from the extension, and the longest extension wins" {
  assert_eq(media_type_of("/a.JSONLD"), "application/ld+json")
  assert_eq(media_type_of("/a.json"), "application/json")
  assert_eq(media_type_of("/a"), "application/octet-stream")
  assert_eq(media_type_of("/a.tar.gz"), "application/octet-stream")
  // An explicit type overrides the guess.
  let files = Files::new()
  files.add("/blob", b"x", media_type="application/x-custom")
  assert_eq(files.get("/blob").unwrap().media_type, "application/x-custom")
}

///|
test "the file set normalises its keys and lists them in order" {
  let files = Files::new()
  files.add("a.css", b"a")
  files.add("/b.css/", b"b")
  assert_eq(files.paths(), ["/a.css", "/b.css"])
  // Every spelling of the same path names the same entry.
  assert_eq(files.get("a.css") is Some(_), true)
  assert_eq(files.get("/a.css/") is Some(_), true)
  assert_eq(files.get("/missing") is None, true)
}

///|
test "an etag follows the content, not the path" {
  let files = Files::new()
  files.add("/one", b"same bytes")
  files.add("/two", b"same bytes")
  files.add("/three", b"other")
  let one = files.get("/one").unwrap().etag()
  let two = files.get("/two").unwrap().etag()
  let three = files.get("/three").unwrap().etag()
  assert_eq(one, two)
  assert_eq(one == three, false)
}
