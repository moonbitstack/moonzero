///|
/// The canonical jwt.io HS256 example token, produced by an independent
/// implementation (Go/JS), so verifying it proves the binding reaches a
/// wire-correct HS256 — real interop, not a self-round-trip.
/// header `{"alg":"HS256","typ":"JWT"}`, payload
/// `{"sub":"1234567890","name":"John Doe","iat":1516239022}`, secret
/// `your-256-bit-secret`.
let jwtio_token : String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

///|
let jwtio_secret : String = "your-256-bit-secret"

///|
/// The token's three `.`-separated segments.
fn segments(token : String) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder()
  for i = 0; i < token.length(); i = i + 1 {
    if token[i].to_int() == '.'.to_int() {
      out.push(sb.to_string())
      sb.reset()
    } else {
      sb.write_char(token[i].unsafe_to_char())
    }
  }
  out.push(sb.to_string())
  out
}

///|
test "jwt_verify accepts an independently-produced HS256 token (interop)" {
  let claims = jwt_verify(jwtio_token, jwtio_secret, 1516239100L)
  assert_eq(claims.get("sub"), Some(Json::string("1234567890")))
  assert_eq(claims.get("name"), Some(Json::string("John Doe")))
  assert_eq(claims.get("iat"), Some(Json::number(1516239022.0)))
}

///|
test "jwt sign -> verify round-trip" {
  let claims : Map[String, Json] = Map([
    ("sub", Json::string("alice")),
    ("role", Json::string("admin")),
    ("exp", Json::number(2000000000.0)),
  ])
  let token = jwt_sign(claims, "topsecret")
  // three segments
  assert_eq(segments(token).length(), 3)
  let out = jwt_verify(token, "topsecret", 1000000000L)
  assert_eq(out.get("sub"), Some(Json::string("alice")))
  assert_eq(out.get("role"), Some(Json::string("admin")))
}

///|
/// MUTATION-VERIFY target: a token whose signature byte is flipped must be
/// rejected with `Signature`. If the verification dropped its HMAC comparison,
/// this assertion goes red.
test "jwt_verify rejects a tampered signature" {
  let token = jwt_sign(Map([("sub", Json::string("bob"))]), "topsecret")
  let parts = segments(token)
  // flip the last character of the signature segment
  let sig = parts[2]
  let last = sig[sig.length() - 1].unsafe_to_char()
  let flipped = if last == 'A' { 'B' } else { 'A' }
  let tampered = parts[0] +
    "." +
    parts[1] +
    "." +
    sig[0:sig.length() - 1].to_owned() +
    flipped.to_string()
  let mut rejected = false
  try {
    let _ = jwt_verify(tampered, "topsecret", 1000000000L)
  } catch {
    Signature => rejected = true
    _ => rejected = false
  }
  assert_eq(rejected, true)
}

///|
test "jwt_verify rejects a token signed with the wrong secret" {
  let token = jwt_sign(Map([("sub", Json::string("carol"))]), "right-secret")
  let mut rejected = false
  try {
    let _ = jwt_verify(token, "wrong-secret", 1000000000L)
  } catch {
    Signature => rejected = true
    _ => rejected = false
  }
  assert_eq(rejected, true)
}

///|
test "jwt_verify enforces exp and nbf" {
  // expired: exp is before now
  let expired = jwt_sign(Map([("exp", Json::number(1000.0))]), "s")
  let mut past = false
  try {
    let _ = jwt_verify(expired, "s", 2000L)
  } catch {
    Expired(..) => past = true
    _ => past = false
  }
  assert_eq(past, true)
  // not yet valid: nbf is after now
  let future = jwt_sign(Map([("nbf", Json::number(5000.0))]), "s")
  let mut early = false
  try {
    let _ = jwt_verify(future, "s", 2000L)
  } catch {
    TooEarly(..) => early = true
    _ => early = false
  }
  assert_eq(early, true)
  // valid window: nbf <= now < exp
  let ok = jwt_sign(
    Map([("nbf", Json::number(1000.0)), ("exp", Json::number(9000.0))]),
    "s",
  )
  let claims = jwt_verify(ok, "s", 3000L)
  assert_eq(claims.get("nbf"), Some(Json::number(1000.0)))
}

///|
/// The forged `{"alg":"none","typ":"JWT"}` header with an empty signature,
/// written out rather than built: a fixture an attacker could paste is a
/// stronger test than one our own encoder produced.
test "jwt_verify rejects the alg:none downgrade" {
  // A forgery with a signature segment reaches the `alg` check, which is the
  // one that matters: the header says `none`, verification wants HS256.
  let mut named = false
  try {
    let _ = jwt_verify(
      "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJtYWxsb3J5In0.QUFB", "s", 1000L,
    )
  } catch {
    Algorithm(want~, got~) => named = want == "HS256" && got == "none"
    _ => named = false
  }
  assert_eq(named, true)
  // The bare form attackers actually paste, with nothing after the last dot,
  // is refused a step earlier as a malformed token.
  let mut refused = false
  try {
    let _ = jwt_verify(
      "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJtYWxsb3J5In0.", "s", 1000L,
    )
  } catch {
    Shape(_) => refused = true
    _ => refused = false
  }
  assert_eq(refused, true)
}

///|
test "jwt_verify rejects a malformed token" {
  let mut malformed = false
  try {
    let _ = jwt_verify("only.two", "s", 1000L)
  } catch {
    Shape(_) => malformed = true
    _ => malformed = false
  }
  assert_eq(malformed, true)
}

///|
/// The policy is the knob: the same expired token is refused by default and
/// accepted when `expiry` is turned off.
test "jwt_verify's policy is a knob" {
  let expired = jwt_sign(Map([("exp", Json::number(1000.0))]), "s")
  let mut refused = false
  try {
    let _ = jwt_verify(expired, "s", 2000L)
  } catch {
    Expired(..) => refused = true
    _ => refused = false
  }
  assert_eq(refused, true)
  let claims = jwt_verify(
    expired,
    "s",
    2000L,
    policy=@jwt.Policy::new(expiry=false),
  )
  assert_eq(claims.get("exp"), Some(Json::number(1000.0)))
}
