// Content security: the `X-Content-Security` request signature.
//
// A caller proves it is a trusted peer, and states a timestamp, with one header:
// `key=<fingerprint>, secret=<base64 envelope>, signature=<base64 mac>`. The
// envelope is sealed with the peer's RSA public key, so only the holder of the
// matching private key on this side can read it, and it carries the HMAC key,
// the time and the payload type. The MAC covers the time, the method, the path,
// the query and the SHA-256 of the body, so a captured request cannot be replayed
// against another route or with another payload.
//
// Verification is a pure function of a request snapshot, a key set and a clock
// reading, so every accept and every refusal is exactly testable.

///|
/// A content-security failure. Each variant names the one check that refused the
/// request, so a caller can tell a replay from a wrong key.
pub(all) suberror Refused {
  /// The request carried no `X-Content-Security` header.
  MissingHeader
  /// The header did not carry `key`, `secret` and `signature`.
  MalformedHeader
  /// No decrypter is registered under the header's fingerprint.
  UnknownKey
  /// The sealed envelope would not open, or did not name an HMAC key.
  BadSecret
  /// The envelope's timestamp is further from now than the tolerance allows.
  StaleTimestamp
  /// The body of an encrypted request is not decryptable.
  BadCiphertext
  /// The MAC does not match the request.
  BadSignature
}

///|
/// Turns the sealed `secret` field of the header into the envelope it carries.
/// Implemented by the RSA decrypter below and open to any transport a caller
/// prefers — an HSM, a KMS, a key in an environment variable.
pub(open) trait Decrypter {
  fn decrypt(Self, Bytes) -> Bytes raise
}

///|
/// One verification key: the fingerprint a caller names in the header, and the
/// decrypter that opens envelopes sealed for it.
pub(all) struct SignatureKey {
  fingerprint : String
  decrypter : &Decrypter
}

///|
/// The verification policy: the keys, how far a timestamp may drift, and whether
/// a request that fails verification is refused or merely ignored.
pub(all) struct SignatureVerifier {
  keys : Array[SignatureKey]
  tolerance_ms : Int64
  strict : Bool
}

///|
/// A verifier over `keys`. `tolerance_ms` defaults to one hour, the expiry
/// go-zero's `SignatureConf` carries. A strict verifier refuses a request that
/// fails; a lenient one serves it unsigned, which is how a service rolls the
/// check out before every client signs.
pub fn SignatureVerifier::new(
  keys~ : Array[SignatureKey],
  tolerance_ms~ : Int64 = 3600000L,
  strict~ : Bool = false,
) -> SignatureVerifier {
  { keys, tolerance_ms, strict, }
}

///|
/// Whether this verifier refuses a request it cannot verify.
pub fn SignatureVerifier::strict(self : SignatureVerifier) -> Bool {
  self.strict
}

///|
/// Split `key=value` pairs out of a header value: fields separated by `,`, name
/// and value by the **first** `=`, because a base64 value carries padding `=`.
/// Both sides of a field are trimmed, and a field with no name is skipped.
pub fn parse_pairs(value : String) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  for field in value.split(",").collect() {
    let field = field.trim()
    match field.find("=") {
      Some(at) =>
        if at > 0 {
          // The name is trimmed as well as the value: a peer that writes
          // `key = fp` has named the same field.
          out[field[0:at].trim().to_owned()] = field[at + 1:].trim().to_owned()
        }
      None => ()
    }
  }
  out
}

///|
/// Look a key up by fingerprint.
fn key_for(keys : Array[SignatureKey], fingerprint : String) -> &Decrypter? {
  for key in keys {
    if key.fingerprint == fingerprint {
      return Some(key.decrypter)
    }
  }
  None
}

///|
/// Compare two byte strings without leaking where they differ: a MAC check that
/// returns early lets an attacker count matched octets.
pub fn constant_time_eq(a : BytesView, b : BytesView) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut diff = 0
  for i = 0; i < a.length(); i = i + 1 {
    diff = diff | (a[i].to_int() ^ b[i].to_int())
  }
  diff == 0
}

///|
/// Parse a decimal integer, optionally signed. A value that is empty, carries a
/// non-digit, or overflows is `None` — the caller reports it as a malformed
/// field rather than reading a truncated number.
pub fn parse_i64(text : String) -> Int64? {
  guard text.length() > 0 else { None }
  let negative = text[0] == '-'
  let mut at = if negative { 1 } else { 0 }
  guard at < text.length() else { None }
  let mut acc = 0L
  while at < text.length() {
    let digit = text[at].to_int() - '0'.to_int()
    if digit < 0 || digit > 9 {
      return None
    }
    acc = acc * 10L + digit.to_int64()
    at = at + 1
  }
  Some(if negative { -acc } else { acc })
}

///|
/// A request as the signature check sees it.
pub(all) struct SignatureInput {
  verb : String
  path : String
  query : String
  header : String?
  body : Bytes
  /// The URI the caller signed, when it differs from the one it addressed —
  /// go-zero's `X-Request-Uri`, used behind a rewriting proxy.
  signed_uri : String?
}

///|
/// The plain content a verified request carries: the HMAC key the envelope
/// named, whether the body was sealed, and the body itself — already decrypted
/// when it was.
pub(all) struct VerifiedContent {
  key : Bytes
  encrypted : Bool
  body : Bytes
}

///|
/// The MAC preimage: timestamp, method, path, query and the hex SHA-256 of the
/// body, newline separated.
pub fn sign_content(
  timestamp : String,
  verb : String,
  path : String,
  query : String,
  body : Bytes,
) -> Bytes {
  let digest = @sha2.hash(body[:], kind=Sha256)
  @utf8.encode(
    timestamp +
    "\n" +
    verb +
    "\n" +
    path +
    "\n" +
    query +
    "\n" +
    @base16.encode(digest[:]),
  )
}

///|
/// The path and query the caller signed: `X-Request-Uri` when present and
/// non-empty, the addressed URI otherwise.
fn signed_path_query(input : SignatureInput) -> (String, String) {
  match input.signed_uri {
    Some(uri) =>
      match uri.find("?") {
        Some(at) => {
          let path = uri[0:at].to_owned()
          if path == "" {
            (input.path, input.query)
          } else {
            (path, uri[at + 1:].to_owned())
          }
        }
        None => (uri, "")
      }
    None => (input.path, input.query)
  }
}

///|
/// Decrypt an AES-ECB body with the key the envelope carried. The ciphertext is
/// base64 in the request itself and the plaintext is PKCS#7 padded, which is
/// the shape the reference implementation uses.
fn ecb_decrypt(key : Bytes, body : Bytes) -> Bytes raise Refused {
  let encoded = @utf8.decode(body) catch { _ => raise Refused::BadCiphertext }
  let ciphertext = @base64.decode(encoded) catch {
    _ => raise Refused::BadCiphertext
  }
  let cipher = @aes.Cipher::new(key[:]) catch { _ => raise Refused::BadSecret }
  let plain = cipher.decrypt_blocks(ciphertext[:])
  @mode.unpad(16, plain[:]) catch {
    _ => raise Refused::BadCiphertext
  }
}

///|
/// Verify one request against `verifier` at `now_ms`.
///
/// On success the returned `VerifiedContent` carries the body to serve — the
/// plaintext when the request declared an encrypted payload. A failure is the
/// single check that refused it; the caller decides whether that is a `403` or a
/// pass-through, per `strict`.
pub fn verify_signature(
  verifier : SignatureVerifier,
  input : SignatureInput,
  now_ms : Int64,
) -> VerifiedContent raise Refused {
  let header = match input.header {
    Some(value) => value
    None => raise Refused::MissingHeader
  }
  let fields = parse_pairs(header)
  let fingerprint = fields.get("key").unwrap_or("")
  let secret = fields.get("secret").unwrap_or("")
  let signature = fields.get("signature").unwrap_or("")
  if fingerprint == "" || secret == "" || signature == "" {
    raise Refused::MalformedHeader
  }
  let decrypter = match key_for(verifier.keys, fingerprint) {
    Some(decrypter) => decrypter
    None => raise Refused::UnknownKey
  }
  let block = @base64.decode(secret) catch {
    _ => raise Refused::MalformedHeader
  }
  let envelope = decrypter.decrypt(block) catch {
    _ => raise Refused::BadSecret
  }
  let envelope_text = @utf8.decode(envelope) catch {
    _ => raise Refused::BadSecret
  }
  let attrs = parse_pairs(envelope_text)
  let encoded_key = attrs.get("key").unwrap_or("")
  if encoded_key == "" {
    raise Refused::BadSecret
  }
  let key = @base64.decode(encoded_key) catch { _ => raise Refused::BadSecret }
  let timestamp = attrs.get("time").unwrap_or("")
  if timestamp == "" {
    raise Refused::MalformedHeader
  }
  let seconds = match parse_i64(timestamp) {
    Some(seconds) => seconds
    None => raise Refused::MalformedHeader
  }
  let tolerance_secs = verifier.tolerance_ms / 1000L
  let now_secs = now_ms / 1000L
  if seconds + tolerance_secs < now_secs || now_secs + tolerance_secs < seconds {
    raise Refused::StaleTimestamp
  }
  let (path, query) = signed_path_query(input)
  let expected = @hmac.mac(
    key[:],
    sign_content(timestamp, input.verb, path, query, input.body)[:],
    () => @sha2.Hasher::new(kind=Sha256),
  )
  let claimed = @base64.decode(signature) catch {
    _ => raise Refused::MalformedHeader
  }
  if !constant_time_eq(expected[:], claimed[:]) {
    raise Refused::BadSignature
  }
  let encrypted = match attrs.get("type") {
    Some(text) =>
      match parse_i64(text) {
        Some(1L) => true
        _ => false
      }
    None => false
  }
  let body = if encrypted && input.body.length() > 0 {
    ecb_decrypt(key, input.body)
  } else {
    input.body
  }
  { key, encrypted, body, }
}

///|
/// The event stream a refused request receives.
fn forbidden_events() -> Array[@moonasgi.Event] {
  [
    @moonasgi.Event::HttpResponseStart(
      status=403,
      headers=[("content-type", "text/plain; charset=utf-8")],
      trailers=false,
    ),
    @moonasgi.Event::HttpResponseBody(body=b"403 Forbidden", more_body=false),
  ]
}

///|
/// Content-security middleware: verify the `X-Content-Security` signature on
/// `DELETE`, `GET`, `POST` and `PUT` requests, the methods the reference
/// implementation checks.
///
/// A strict verifier answers `403 Forbidden` when the check fails. A lenient one
/// serves the request anyway, which is what lets a fleet roll signing out one
/// client at a time. When the envelope declares an encrypted payload, the body
/// served to the application is the decrypted one.
pub fn content_security(
  verifier : SignatureVerifier,
  clock : @clock.Clock,
  header~ : String = "x-content-security",
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(hs) => {
          let checked = ["DELETE", "GET", "POST", "PUT"].contains(
            hs.http_method,
          )
          if !checked {
            inner(scope, receive, send)
            return
          }
          let body = read_body(receive)
          let query = @utf8.decode(hs.query_string[:]) catch { _ => "" }
          let input = {
            verb: hs.http_method,
            path: hs.path,
            query,
            header: scope_header(scope, header),
            body,
            signed_uri: scope_header(scope, "x-request-uri"),
          }
          let verified = Ok(verify_signature(verifier, input, clock.now())) catch {
            error => Err(error)
          }
          match verified {
            Ok(content) => inner(scope, buffered_body(content.body), send)
            Err(_) =>
              if verifier.strict {
                for event in forbidden_events() {
                  send(event)
                }
              } else {
                inner(scope, buffered_body(input.body), send)
              }
          }
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}
