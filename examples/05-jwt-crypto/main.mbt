///|
/// The primitives behind JWT auth — SHA-256, HMAC-SHA256 and the constant-time
/// comparison, all `mooncrypt`'s — then sign and verify a compact HS256 token,
/// including the ways verification is meant to fail: a tampered signature, an
/// expired token, and the `alg: none` downgrade.
///
///     moon run examples/05-jwt-crypto
#coverage.skip
fn main {
  // SHA-256 of "abc" — the FIPS 180-4 vector mooncrypt is checked against.
  println("sha256(\"abc\") = " + @base16.encode(@moonzero.sha256(b"abc")))
  println(
    "hmac_sha256 = " +
    @base16.encode(@moonzero.hmac_sha256(b"key", b"heke1228")),
  )

  // Constant-time equality: same bytes match, different bytes do not.
  let a = @moonzero.sha256(b"qwe")
  println(
    "constant_time_eq(a,a)=" +
    @moonzero.constant_time_eq(a, a).to_string() +
    " (a,b)=" +
    @moonzero.constant_time_eq(a, @moonzero.sha256(b"qwq")).to_string(),
  )
  let secret = "topsecret"
  let claims : Map[String, Json] = Map([
    ("sub", Json::string("lfanke")),
    ("exp", Json::number(2000.0)),
  ])
  let token = @moonzero.jwt_sign(claims, secret)
  println("jwt three segments: " + count_dots(token).to_string())

  // A valid token verifies and hands back its claims.
  try {
    let got = @moonzero.jwt_verify(token, secret, 1000L)
    println("verify ok, sub=" + sub_of(got))
  } catch {
    e => println("unexpected verify failure: " + jwt_reason(e))
  }

  // Each rejection path reports its own reason.
  println("wrong secret -> " + reject(token, "wrong", 1000L))
  println("expired (t=3000 >= exp=2000) -> " + reject(token, secret, 3000L))
  println(
    "alg:none downgrade -> " +
    reject("eyJhbGciOiJub25lIn0.eyJzdWIiOiJtYWxsb3J5In0.QUFB", secret, 1000L),
  )

  // The claim checks are a record: the same expired token passes with `exp`
  // switched off.
  try {
    let lenient = @moonzero.jwt_verify(
      token,
      secret,
      3000L,
      policy=@jwt.Policy::new(expiry=false),
    )
    println("expired but expiry=false -> sub=" + sub_of(lenient))
  } catch {
    e => println("unexpected: " + jwt_reason(e))
  }

  // The middleware's accept/reject decision, as a pure predicate.
  println(
    "jwt_authorized(valid) = " +
    @moonzero.jwt_authorized(Some(token), secret, 1000L).to_string(),
  )
  println(
    "jwt_authorized(none)  = " +
    @moonzero.jwt_authorized(None, secret, 1000L).to_string(),
  )
}

///|
/// Verify a token expected to fail, returning the rejection's name.
fn reject(token : String, secret : String, now : Int64) -> String {
  try {
    let _ = @moonzero.jwt_verify(token, secret, now)
    "unexpectedly accepted"
  } catch {
    e => jwt_reason(e)
  }
}

///|
fn jwt_reason(e : @jwt.Rejected) -> String {
  match e {
    Shape(m) => "malformed: " + m
    Algorithm(want~, got~) => "unsupported-alg: " + got + " (want " + want + ")"
    Signature => "bad-signature"
    Expired(..) => "expired"
    TooEarly(..) => "not-yet-valid"
    Issuer(..) => "wrong-issuer"
    Audience(..) => "wrong-audience"
    Subject(..) => "wrong-subject"
    IssuedAt(..) => "issued-in-the-future"
    Type(..) => "wrong-typ"
    Missing(claim~) => "missing claim: " + claim
  }
}

///|
fn sub_of(claims : Map[String, Json]) -> String {
  match claims.get("sub") {
    Some(String(s)) => s
    _ => "?"
  }
}

///|
fn count_dots(s : String) -> Int {
  let mut n = 1
  for i = 0; i < s.length(); i = i + 1 {
    if s[i] == '.' {
      n = n + 1
    }
  }
  n
}
