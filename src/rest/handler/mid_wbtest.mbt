// The adapter between this package's middlewares and moonasgi's `mid` layers: one
// layer shape, two packages that ship layers.

///|
/// An app that answers 200 with the body `ok` and records that it ran.
fn inner_app(called : Ref[Bool]) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    let _ = scope
    let _ = receive
    called.val = true
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
  }
}

///|
/// The status of an event list's response start.
fn status_in(events : Array[@moonasgi.Event]) -> Int32 {
  for event in events {
    match event {
      HttpResponseStart(status~, ..) => return status
      _ => ()
    }
  }
  0
}

///|
async test "a middleware here is a layer in a mid stack" {
  let entered : Ref[Bool] = { val: false, }
  let answered : Ref[Bool] = { val: false, }
  let marker : Middleware = inner => {
    (scope, receive, send) => {
      entered.val = true
      inner(scope, receive, send)
    }
  }
  // `stack` takes the layers, outermost last, and hands back the app.
  let app = @mid.stack([as_layer(marker)], inner_app(answered))
  let events = run_app(app, scope_with([]))
  assert_eq(entered.val, true)
  assert_eq(answered.val, true)
  assert_eq(status_in(events), 200)
}

///|
async test "a layer from mid is a middleware here" {
  let answered : Ref[Bool] = { val: false, }
  // `body_limit` refuses a declared body larger than it allows, which is a
  // behaviour this package does not ship: the point is that it runs in this chain.
  let limited = of_layer(@mid.BodyLimit::new(limit=64))
  let app = limited(inner_app(answered))
  let events = run_app(app, scope_with([("content-length", "2048")]))
  assert_eq(answered.val, false)
  assert_eq(status_in(events), 413)
  // A request inside the limit reaches the application as usual.
  let small = run_app(app, scope_with([("content-length", "8")]))
  assert_eq(status_in(small), 200)
  assert_eq(answered.val, true)
}
