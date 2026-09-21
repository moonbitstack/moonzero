// go-zero's JWT authentication, bound to `mooncred`.
//
// Only the shape go-zero's `handler.Authorize` presents is here — an HS256
// shared secret given as a string, and a verification time in seconds. The
// token format, the algorithm ladder and every check belong to `mooncred/jwt`.

///|
/// The HS256 key for `secret`, as `mooncred` wants it: a `Mac` factory it can
/// run once per signature.
fn hs256(secret : String) -> @jwt.Keyed {
  let key = @utf8.encode(secret)
  @jwt.mac(fn() { @hmac.Hmac::new(key[:], fn() { @sha2.Hasher::new() }) })
}

///|
/// Sign a claims set as a compact HS256 JWT (← go-zero's
/// `jwt.NewWithClaims(SigningMethodHS256, ...)`).
///
/// `claims` is the payload; put `exp`/`iat`/`nbf`/`sub` in it as ordinary
/// entries. `typ` is the header's type (`"JWT"` unless given; `None` writes no
/// `typ` header at all), and `extra` merges further members into the header.
///
/// Configuration has three layers, later ones winning: the library preset <
/// the `typ` given here < `extra`. `wins` turns the last two around and `clash`
/// decides what a collision does — by default the reserved header fields we
/// write are the ones that stand, and overwriting one raises.
pub fn jwt_sign(
  claims : Map[String, Json],
  secret : String,
  typ? : String? = Some("JWT"),
  extra? : Map[String, Json],
  wins? : @jwt.Wins,
  clash? : @jwt.OnClash[Map[String, Json]],
) -> String {
  @jwt.sign(claims, HS256, hs256(secret), typ~, extra?, wins?, clash?)
}

///|
/// Verify a compact HS256 JWT and return its claims (← go-zero's
/// `handler.Authorize`).
///
/// `now_secs` is the verification time as a Unix timestamp in **seconds**, the
/// unit JWT's `NumericDate` uses — not the milliseconds the [`Clock`] seam
/// carries, because the claim is defined in seconds.
///
/// `policy` carries every check: `exp` and `nbf` are verified by default and
/// `iat` is not, which is what PyJWT and jjwt both do. Hand it a different
/// `Policy` to require an issuer, an audience, or particular claims.
pub fn jwt_verify(
  token : String,
  secret : String,
  now_secs : Int64,
  policy? : @jwt.Policy = @jwt.policy,
) -> Map[String, Json] raise @jwt.Rejected {
  @jwt.verify(token, HS256, hs256(secret), now=At(now_secs), policy~)
}
