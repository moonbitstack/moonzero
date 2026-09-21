// The primitives go-zero's middlewares name, bound to `mooncrypt`.
//
// Nothing is implemented here. Every line hands off; what this file carries is
// the binding, so the auth and discovery layers ask for a digest rather than
// restating which package it comes from on every call.

///|
/// SHA-256 (FIPS 180-4), which the signature middleware and the Redis-backed
/// registry both hash with.
pub fn sha256(msg : Bytes) -> Bytes {
  @sha2.hash(msg[:])
}

///|
/// HMAC-SHA256 (RFC 2104), which signs JWTs and the request signatures.
pub fn hmac_sha256(key : Bytes, msg : Bytes) -> Bytes {
  @hmac.mac(key[:], msg[:], () => @sha2.Hasher::new())
}

///|
/// Compare two byte strings in time that does not depend on where they first
/// differ (← go-zero's `subtle.ConstantTimeCompare`).
pub fn constant_time_eq(a : Bytes, b : Bytes) -> Bool {
  @spec.eq(a[:], b[:])
}
