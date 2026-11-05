// Request-body decompression, so a client may send `Content-Encoding: gzip` and
// have the handler read the plain body.

///|
/// The event stream a body that will not decompress receives: `400 Bad Request`
/// with no body, which is what a server that cannot read the request owes the
/// client.
fn bad_request_events() -> Array[@moonasgi.Event] {
  [
    @moonasgi.Event::HttpResponseStart(
      status=400,
      headers=[("content-type", "text/plain; charset=utf-8")],
      trailers=false,
    ),
    @moonasgi.Event::HttpResponseBody(body=b"", more_body=false),
  ]
}

///|
/// Whether a `Content-Encoding` value asks for gzip. The header is a comma
/// separated list and `gzip` may be one of several codings, so the match is on
/// the token, not the whole value.
pub fn is_gzip_encoding(value : String) -> Bool {
  for token in value.split(",").collect() {
    if token.trim().to_lower() == "gzip" {
      return true
    }
  }
  false
}

///|
/// Gunzip middleware: when the request declares `Content-Encoding: gzip`, buffer
/// the body, inflate it, and hand the wrapped application one `HttpRequest`
/// carrying the plain body. A body that will not inflate is answered
/// `400 Bad Request` without reaching the application.
///
/// `limit` caps the *decompressed* size in bytes, the number a compression bomb
/// inflates to; `0` removes the cap, which is what a service that has already
/// bounded the compressed body at the edge wants. Anything but an HTTP scope, or
/// a request without the header, passes through untouched.
pub fn gunzip(limit~ : Int32 = 0) -> Middleware {
  inner => {
    (scope, receive, send) => {
      let encoded = match scope_header(scope, "content-encoding") {
        Some(value) => is_gzip_encoding(value)
        None => false
      }
      if !encoded {
        inner(scope, receive, send)
        return
      }
      let body = read_body(receive)
      let plain : Result[Bytes, @moonzip.Refused] = Ok(
        @gzip.gunzip(body[:], limit~),
      ) catch {
        error => Err(error)
      }
      match plain {
        Ok(plain) => inner(scope, buffered_body(plain), send)
        Err(_) =>
          for event in bad_request_events() {
            send(event)
          }
      }
    }
  }
}
