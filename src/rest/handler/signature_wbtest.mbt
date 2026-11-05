// Content security: the X-Content-Security signature, every check in it, and the
// middleware that turns a refusal into a 403 or a pass-through.
//
// The envelope is the seam: a decrypter is whatever opens it, so these cases use one
// that carries the envelope in the clear and exercise everything above that — the
// MAC, the timestamp, the key lookup and the encrypted payload — without an RSA key.

///|
/// A decrypter for tests: the sealed block is the envelope itself.
struct Clear {}

///|
impl Decrypter for Clear with fn decrypt(self : Clear, block : Bytes) -> Bytes raise {
  let _ = self
  block
}

///|
/// A decrypter that cannot open anything, for the case where the envelope itself is
/// what fails.
struct Broken {}

///|
impl Decrypter for Broken with fn decrypt(self : Broken, block : Bytes) -> Bytes raise {
  let _ = self
  let _ = block
  raise SigFailure("no key here")
}

///|
/// One failure a test decrypter raises.
suberror SigFailure {
  SigFailure(String)
}

///|
pub extend Clear with Decrypter::{decrypt}

///|
pub extend Broken with Decrypter::{decrypt}

///|
/// The HMAC/AES key these cases share.
let test_key : Bytes = b"0123456789abcdef"

///|
/// The fingerprint a caller names in the header.
let test_fingerprint : String = "fp-1"

///|
/// A verifier over the clear decrypter, strict or not, with the given tolerance.
fn sig_verifier(
  strict~ : Bool = true,
  tolerance_ms~ : Int64 = 3600000L,
) -> SignatureVerifier {
  SignatureVerifier::new(
    keys=[{ fingerprint: test_fingerprint, decrypter: Clear::{ }, }],
    tolerance_ms~,
    strict~,
  )
}

///|
/// The MAC a caller would send: HMAC-SHA256 over the request, base64.
fn mac_of(
  key : Bytes,
  timestamp : String,
  verb : String,
  path : String,
  query : String,
  body : Bytes,
) -> String {
  let mac = @hmac.mac(
    key[:],
    sign_content(timestamp, verb, path, query, body)[:],
    () => @sha2.Hasher::new(kind=Sha256),
  )
  @base64.encode(mac[:])
}

///|
/// A header a correctly signed request carries.
fn header_for(
  verb : String,
  path : String,
  query : String,
  body : Bytes,
  now_secs : Int64,
  type_~ : Int64 = 0L,
  key~ : Bytes = test_key,
  fingerprint~ : String = test_fingerprint,
) -> String {
  let timestamp = now_secs.to_string()
  let envelope = "key=" +
    @base64.encode(key[:]) +
    ",time=" +
    timestamp +
    ",type=" +
    type_.to_string()
  "key=" +
  fingerprint +
  ", secret=" +
  @base64.encode(@utf8.encode(envelope)[:]) +
  ", signature=" +
  mac_of(key, timestamp, verb, path, query, body)
}

///|
/// A request snapshot for these cases.
fn input_of(
  header : String?,
  body~ : Bytes = b"",
  path~ : String = "/api/order",
  query~ : String = "",
  verb~ : String = "POST",
  signed_uri? : String,
) -> SignatureInput {
  { verb, path, query, header, body, signed_uri, }
}

///|
/// The name of a refusal, so a case asserts on which check said no.
fn sig_name_of(refusal : Refused) -> String {
  match refusal {
    MissingHeader => "missing-header"
    MalformedHeader => "malformed-header"
    UnknownKey => "unknown-key"
    BadSecret => "bad-secret"
    StaleTimestamp => "stale-timestamp"
    BadCiphertext => "bad-ciphertext"
    BadSignature => "bad-signature"
  }
}

///|
/// Verify and report the outcome as `"ok"` or the name of the refusal.
fn sig_outcome_of(
  verifier : SignatureVerifier,
  input : SignatureInput,
  now_ms : Int64,
) -> String {
  let result : Result[VerifiedContent, Refused] = Ok(
    verify_signature(verifier, input, now_ms),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => "ok"
    Err(error) => sig_name_of(error)
  }
}

///|
/// The events a middleware run produced.
async fn sig_run(
  app : @moonasgi.AsgiApp,
  scope : @moonasgi.Scope,
  body : Bytes,
) -> Array[@moonasgi.Event] {
  let events : Array[@moonasgi.Event] = []
  let sent : Ref[Bool] = { val: false, }
  let receive : @moonasgi.Receive = () => {
    if sent.val {
      @moonasgi.Event::HttpDisconnect
    } else {
      sent.val = true
      @moonasgi.Event::HttpRequest(body~, more_body=false)
    }
  }
  app(scope, receive, event => events.push(event))
  events
}

///|
/// A scope carrying the request's headers and query.
fn sig_scope(
  verb : String,
  path : String,
  headers : Array[(String, String)],
  query~ : Bytes = b"",
) -> @moonasgi.Scope {
  @moonasgi.Scope::Http({
    http_version: "1.1",
    http_method: verb,
    scheme: "http",
    path,
    raw_path: None,
    query_string: query,
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
/// What the application under the middleware saw.
struct SigSeen {
  mut calls : Int32
  mut body : Bytes
}

///|
fn SigSeen::new() -> SigSeen {
  { calls: 0, body: b"", }
}

///|
fn sig_app(seen : SigSeen) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    let _ = scope
    seen.calls = seen.calls + 1
    seen.body = read_body(receive)
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
fn sig_status(events : Array[@moonasgi.Event]) -> Int32 {
  for event in events {
    match event {
      HttpResponseStart(status~, ..) => return status
      _ => ()
    }
  }
  0
}

///|
test "a correctly signed request verifies and reports its content" {
  let now_ms = 1_700_000_000_000L
  let body = b"{\"id\":7}"
  let header = header_for("POST", "/api/order", "", body, now_ms / 1000L)
  let content = verify_signature(
    sig_verifier(),
    input_of(Some(header), body~),
    now_ms,
  )
  assert_eq(content.body, body)
  assert_eq(content.encrypted, false)
  assert_eq(content.key, test_key)
}

///|
test "a body that changed after signing is refused" {
  let now_ms = 1_700_000_000_000L
  let body = b"{\"id\":7}"
  let header = header_for("POST", "/api/order", "", body, now_ms / 1000L)
  // The whole point of signing the body's digest: an attacker who can edit the
  // payload cannot recompute the MAC without the key.
  assert_eq(
    sig_outcome_of(
      sig_verifier(),
      input_of(Some(header), body=b"{\"id\":8}"),
      now_ms,
    ),
    "bad-signature",
  )
}

///|
test "a signature cannot be replayed against another route, verb or query" {
  let now_ms = 1_700_000_000_000L
  let body = b"x"
  let header = header_for("POST", "/api/order", "a=1", body, now_ms / 1000L)
  let signed = input_of(Some(header), body~, query="a=1")
  assert_eq(sig_outcome_of(sig_verifier(), signed, now_ms), "ok")
  assert_eq(
    sig_outcome_of(sig_verifier(), { ..signed, path: "/api/refund", }, now_ms),
    "bad-signature",
  )
  assert_eq(
    sig_outcome_of(sig_verifier(), { ..signed, verb: "GET", }, now_ms),
    "bad-signature",
  )
  assert_eq(
    sig_outcome_of(sig_verifier(), { ..signed, query: "a=2", }, now_ms),
    "bad-signature",
  )
}

///|
test "a timestamp outside the tolerance is refused, one inside it is not" {
  let signed_at = 1_700_000_000L
  let header = header_for("POST", "/api/order", "", b"", signed_at)
  let within = sig_verifier(tolerance_ms=60_000L)
  // One minute of tolerance either way.
  assert_eq(
    sig_outcome_of(within, input_of(Some(header)), (signed_at + 59L) * 1000L),
    "ok",
  )
  assert_eq(
    sig_outcome_of(within, input_of(Some(header)), (signed_at - 59L) * 1000L),
    "ok",
  )
  assert_eq(
    sig_outcome_of(within, input_of(Some(header)), (signed_at + 61L) * 1000L),
    "stale-timestamp",
  )
  assert_eq(
    sig_outcome_of(within, input_of(Some(header)), (signed_at - 61L) * 1000L),
    "stale-timestamp",
  )
}

///|
test "a header that is absent or incomplete is named as such" {
  let now_ms = 1_700_000_000_000L
  assert_eq(
    sig_outcome_of(sig_verifier(), input_of(None), now_ms),
    "missing-header",
  )
  assert_eq(
    sig_outcome_of(
      sig_verifier(),
      input_of(Some("key=fp-1, secret=abc")),
      now_ms,
    ),
    "malformed-header",
  )
  assert_eq(
    sig_outcome_of(sig_verifier(), input_of(Some("")), now_ms),
    "malformed-header",
  )
}

///|
test "a fingerprint nobody registered is an unknown key, not a bad secret" {
  let now_ms = 1_700_000_000_000L
  let header = header_for(
    "POST",
    "/api/order",
    "",
    b"",
    now_ms / 1000L,
    fingerprint="someone-else",
  )
  assert_eq(
    sig_outcome_of(sig_verifier(), input_of(Some(header)), now_ms),
    "unknown-key",
  )
}

///|
test "an envelope that will not open is a bad secret" {
  let now_ms = 1_700_000_000_000L
  let broken = SignatureVerifier::new(keys=[
    { fingerprint: test_fingerprint, decrypter: Broken::{ }, },
  ])
  let header = header_for("POST", "/api/order", "", b"", now_ms / 1000L)
  assert_eq(
    sig_outcome_of(broken, input_of(Some(header)), now_ms),
    "bad-secret",
  )
  // An envelope with no key in it fails the same way.
  let empty = SignatureVerifier::new(keys=[
    { fingerprint: test_fingerprint, decrypter: Clear::{ }, },
  ])
  let hollow = "key=" +
    test_fingerprint +
    ", secret=" +
    @base64.encode(@utf8.encode("time=1700000000")[:]) +
    ", signature=abc"
  assert_eq(sig_outcome_of(empty, input_of(Some(hollow)), now_ms), "bad-secret")
}

///|
test "a sealed payload is delivered as its plaintext" {
  let now_ms = 1_700_000_000_000L
  let plain = b"{\"sealed\":true}"
  let cipher = @aes.Cipher::new(test_key[:]) catch {
    _ => abort("a 16-byte key is a valid AES key")
  }
  let ciphertext = cipher.encrypt_blocks(@mode.pad(16, plain[:]))
  let body = @utf8.encode(@base64.encode(ciphertext[:]))
  let header = header_for(
    "POST",
    "/api/order",
    "",
    body,
    now_ms / 1000L,
    type_=1L,
  )
  let content = verify_signature(
    sig_verifier(),
    input_of(Some(header), body~),
    now_ms,
  )
  assert_eq(content.encrypted, true)
  assert_eq(content.body, plain)
  // A ciphertext that is not the one that was signed does not get that far.
  let tampered = @utf8.encode(@base64.encode(b"not a block"))
  assert_eq(
    sig_outcome_of(
      sig_verifier(),
      input_of(Some(header), body=tampered),
      now_ms,
    ),
    "bad-signature",
  )
}

///|
test "a payload the cipher cannot open is named, not served" {
  let now_ms = 1_700_000_000_000L
  // A payload the MAC vouches for and the cipher still cannot read: the block was
  // sealed without the padding the reader requires, so it opens to noise.
  let cipher = @aes.Cipher::new(test_key[:]) catch {
    _ => abort("a 16-byte key is a valid AES key")
  }
  let body = @utf8.encode(
    @base64.encode(cipher.encrypt_blocks(b"0123456789abcdef")[:]),
  )
  let header = header_for(
    "POST",
    "/api/order",
    "",
    body,
    now_ms / 1000L,
    type_=1L,
  )
  assert_eq(
    sig_outcome_of(sig_verifier(), input_of(Some(header), body~), now_ms),
    "bad-ciphertext",
  )
}

///|
test "the caller may sign a URI that differs from the one it addressed" {
  let now_ms = 1_700_000_000_000L
  // Behind a rewriting proxy: the request arrives at /internal/order but the client
  // signed /api/order?x=1, and that is what the MAC covers.
  let header = header_for("GET", "/api/order", "x=1", b"", now_ms / 1000L)
  let proxied = input_of(
    Some(header),
    verb="GET",
    path="/internal/order",
    signed_uri="/api/order?x=1",
  )
  assert_eq(sig_outcome_of(sig_verifier(), proxied, now_ms), "ok")
  // A signed URI whose path is empty falls back to the addressed one.
  let fallback = input_of(
    Some(header_for("GET", "/internal/order", "x=1", b"", now_ms / 1000L)),
    verb="GET",
    path="/internal/order",
    query="x=1",
    signed_uri="?x=1",
  )
  assert_eq(sig_outcome_of(sig_verifier(), fallback, now_ms), "ok")
}

///|
test "a header is parsed on the first = so base64 padding survives" {
  let pairs = parse_pairs("key=fp, secret=YWJjZA==, signature=Zm9v==")
  assert_eq(pairs.get("key"), Some("fp"))
  assert_eq(pairs.get("secret"), Some("YWJjZA=="))
  assert_eq(pairs.get("signature"), Some("Zm9v=="))
  // A field with no name or no `=` is skipped, not fatal.
  let odd = parse_pairs("=novalue, lonely, key = spaced ")
  assert_eq(odd.get("key"), Some("spaced"))
}

///|
test "a decimal field is read whole or not at all" {
  assert_eq(parse_i64("1700000000"), Some(1_700_000_000L))
  assert_eq(parse_i64("-5"), Some(-5L))
  assert_eq(parse_i64("0"), Some(0L))
  assert_eq(parse_i64(""), None)
  assert_eq(parse_i64("-"), None)
  assert_eq(parse_i64("12a"), None)
  assert_eq(parse_i64(" 12"), None)
}

///|
test "the comparison does not stop at the first differing octet" {
  assert_eq(constant_time_eq(b"abc", b"abc"), true)
  assert_eq(constant_time_eq(b"abc", b"abd"), false)
  assert_eq(constant_time_eq(b"abc", b"ab"), false)
  assert_eq(constant_time_eq(b"", b""), true)
}

///|
async test "a strict verifier answers 403 and never reaches the application" {
  let now = @clock.ManualClock::new(start=1_700_000_000_000L)
  let seen = SigSeen::new()
  let app = content_security(sig_verifier(), now.as_clock())(sig_app(seen))
  let events = sig_run(app, sig_scope("POST", "/api/order", []), b"{\"id\":7}")
  assert_eq(sig_status(events), 403)
  assert_eq(seen.calls, 0)
}

///|
async test "a lenient verifier serves the request it could not verify" {
  let now = @clock.ManualClock::new(start=1_700_000_000_000L)
  let seen = SigSeen::new()
  let app = content_security(sig_verifier(strict=false), now.as_clock())(
    sig_app(seen),
  )
  let events = sig_run(app, sig_scope("POST", "/api/order", []), b"{\"id\":7}")
  assert_eq(sig_status(events), 200)
  assert_eq(seen.calls, 1)
  assert_eq(seen.body, b"{\"id\":7}")
}

///|
async test "a signed request reaches the application with its plaintext body" {
  let start_ms = 1_700_000_000_000L
  let now = @clock.ManualClock::new(start=start_ms)
  let plain = b"{\"sealed\":true}"
  let cipher = @aes.Cipher::new(test_key[:]) catch {
    _ => abort("a 16-byte key is a valid AES key")
  }
  let ciphertext = cipher.encrypt_blocks(@mode.pad(16, plain[:]))
  let body = @utf8.encode(@base64.encode(ciphertext[:]))
  let header = header_for(
    "POST",
    "/api/order",
    "",
    body,
    start_ms / 1000L,
    type_=1L,
  )
  let seen = SigSeen::new()
  let app = content_security(sig_verifier(), now.as_clock())(sig_app(seen))
  let events = sig_run(
    app,
    sig_scope("POST", "/api/order", [("x-content-security", header)]),
    body,
  )
  assert_eq(sig_status(events), 200)
  assert_eq(seen.body, plain)
}

///|
async test "the methods the reference implementation leaves alone are not checked" {
  let now = @clock.ManualClock::new(start=1_700_000_000_000L)
  let seen = SigSeen::new()
  let app = content_security(sig_verifier(), now.as_clock())(sig_app(seen))
  // A strict verifier with no header would refuse a POST; PATCH is not on the list.
  let events = sig_run(app, sig_scope("PATCH", "/api/order", []), b"v")
  assert_eq(sig_status(events), 200)
  assert_eq(seen.calls, 1)
}
