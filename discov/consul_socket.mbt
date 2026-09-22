// HTTP over a real TCP socket: a consul agent transport the discovery flow drives
// against a live consul. moonzero's root `ConsulHttp` is synchronous (so the driver and
// its mock run on every backend), but socket I/O is async, so the real transport is a
// separate native-only path here. The messages are moonhttp's; this adds only the
// async connect, send and receive. Native-only, because `moonbitlang/async` has no
// JS/Wasm backend.

///|
/// A consul agent reachable over HTTP at `host:port`. Each request opens a fresh
/// connection (HTTP/1.0 with `Connection: close`), the simplest correct model for the
/// agent's short JSON round trips.
pub struct ConsulSocket {
  host : String
  port : Int
}

///|
/// A transport to the consul agent at `host:port` (default port 8500).
pub fn ConsulSocket::new(host : String, port? : Int = 8500) -> ConsulSocket {
  { host, port, }
}

///|
/// Perform one HTTP request against the agent and return its status and body.
pub async fn ConsulSocket::request(
  self : ConsulSocket,
  verb : String,
  path : String,
  body : Bytes,
) -> @moonzero.ConsulResponse {
  let addr = @socket.Addr::resolve(self.host, port=self.port)
  let tcp = @socket.Tcp::connect(addr)
  let fields = if body.length() > 0 {
    [@header.Header::of("content-type", "application/json")]
  } else {
    []
  }
  // HTTP/1.0 with the connection closing, so the reply is delimited by the close
  // and there is no chunked framing to unpick for a short JSON round trip.
  let head = @http1.Request::of(
    verb,
    path,
    version="HTTP/1.0",
    host=self.host + ":" + self.port.to_string(),
    body=Sized(body.length()),
    fields~,
    keep_alive=false,
  )
  // The socket has to close on every path, cancellation included — there is no fd
  // finalizer to reclaim it otherwise.
  defer tcp.close()
  (tcp : &@io.Writer).write(head.encode())
  (tcp : &@io.Writer).write(body)
  let raw = (tcp : &@io.Reader).read_all().binary()
  let (resp, used) = @http1.response(raw[:], verb~)
  @moonzero.ConsulResponse::new(resp.status, content(raw, used, resp.body))
}

///|
/// The body of a reply that has been read to its close, framed as the reply said.
///
/// A length longer than what arrived keeps what arrived rather than failing: the
/// agent closed the connection, so there is no more coming.
fn content(raw : Bytes, used : Int, body : @http1.Body) -> Bytes raise {
  match body {
    Sized(n) =>
      if used + n <= raw.length() {
        raw[used:used + n].to_owned()
      } else {
        raw[used:].to_owned()
      }
    Closed => raw[used:].to_owned()
    Empty => b""
    Chunked => {
      let out = Buffer()
      let mut at = used
      for ;; {
        match @http1.chunked(raw[at:]) {
          Piece(part, n) => {
            out.write_bytes(part)
            at = at + n
          }
          Done(_, _) => break
        }
      }
      out.to_bytes()
    }
  }
}
