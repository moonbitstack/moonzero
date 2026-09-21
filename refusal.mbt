// What a request turned away by a middleware receives.
//
// go-zero answers 503 when a breaker is open, a connection budget is spent or a
// deadline passes, 429 when a rate limit bites, and 413 when a body is too
// large. Those are the defaults here; every one of them is a parameter, because
// which status a refusal carries is a deployment's decision — an API gateway in
// front may want 429 with `Retry-After` where the service alone wants 503.

///|
/// The response a refused request receives: a status, a body, and the headers
/// sent with it.
pub(all) struct Refusal {
  status : Int
  body : Bytes
  headers : Array[(String, String)]
}

///|
/// The headers a refusal carries unless told otherwise.
pub let plain_text : Array[(String, String)] = [
  ("content-type", "text/plain; charset=utf-8"),
]

///|
/// Build a refusal. Left alone it is the `503 Service Unavailable` the breaker,
/// the shedder and the connection limiter all answer with.
pub fn Refusal::new(
  status? : Int = 503,
  body? : Bytes = b"503 Service Unavailable",
  headers? : Array[(String, String)] = plain_text,
) -> Refusal {
  { status, body, headers, }
}

///|
/// The generic refusal: `503 Service Unavailable`.
pub let refusal : Refusal = Refusal::new()

///|
/// What an open breaker, a shed request and a spent connection budget answer
/// with (← go-zero's `breaker`, `sheddingHandler`, `maxConns`).
pub let unavailable : Refusal = refusal

///|
/// What a rate-limited request answers with (← go-zero's `periodlimit` and
/// `tokenlimit` handlers).
pub let too_many : Refusal = Refusal::new(
  status=429,
  body=b"429 Too Many Requests",
)

///|
/// What a request past its deadline answers with. go-zero's timeout middleware
/// answers `503` with this body rather than `504`, so that is the default.
pub let timed_out : Refusal = Refusal::new(body=b"service timeout")

///|
/// What an over-large request body answers with (← go-zero's `maxBytes`).
pub let too_large : Refusal = Refusal::new(
  status=413,
  body=b"413 Payload Too Large",
)

///|
/// The refusal as the ASGI events that send it. A pure value, so a middleware's
/// answer is testable without driving the async transport.
pub fn Refusal::events(self : Refusal) -> Array[@moonasgi.Event] {
  [
    @moonasgi.Event::HttpResponseStart(
      status=self.status,
      headers=self.headers,
      trailers=false,
    ),
    @moonasgi.Event::HttpResponseBody(body=self.body, more_body=false),
  ]
}
