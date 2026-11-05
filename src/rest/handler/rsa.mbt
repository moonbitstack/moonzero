// The RSA decrypter a content-security key set is built from.
//
// The envelope is sealed with RSAES-PKCS1-v1_5, the scheme the reference
// implementation's `NewRsaDecrypter` uses: `EM = 00 || 02 || PS || 00 || M` with
// PS at least eight non-zero octets. The private operation is raw RSA, and the
// padding is stripped here because the seal is not a message the library parser
// can see.

///|
/// A content-security key: an RSA private key and the PKCS#1 v1.5 unpad the
/// envelope needs.
pub(all) struct RsaDecrypter {
  key : @rsa.PrivateKey
}

///|
/// Wrap an RSA private key as a decrypter.
pub fn RsaDecrypter::new(key : @rsa.PrivateKey) -> RsaDecrypter {
  { key, }
}

///|
/// Build a decrypter from a PKCS#1 `RSAPrivateKey` DER structure, the body of a
/// `-----BEGIN RSA PRIVATE KEY-----` block.
pub fn RsaDecrypter::from_der(der : BytesView) -> RsaDecrypter raise {
  let parsed = @key.parse_rsa_private(der)
  RsaDecrypter::new(
    @rsa.PrivateKey::new(
      parsed.modulus.to_octets(),
      parsed.public_exponent.to_octets(),
      parsed.private_exponent.to_octets(),
    ),
  )
}

///|
/// Build a decrypter from a **PEM** document: a `RSA PRIVATE KEY` or a
/// `PRIVATE KEY` (PKCS#8) block. The reader is a pure function of the text, so
/// which file to read and how stays the caller's decision.
pub fn RsaDecrypter::from_pem(pem : StringView) -> RsaDecrypter raise {
  let (label, body) = @key.dearmor(pem)
  let der = if label == "RSA PRIVATE KEY" {
    body
  } else {
    @key.parse_pkcs8(body[:])
  }
  RsaDecrypter::from_der(der[:])
}

///|
/// Strip PKCS#1 v1.5 encryption padding: `00 02 PS 00 M`, with `PS` at least
/// eight non-zero octets. A block that does not start that way is not a sealed
/// envelope, and one whose separator never comes is refused rather than read
/// past.
fn pkcs1v15_unpad(block : Bytes) -> Bytes raise {
  guard block.length() > 11 else { raise Failure("rsa block too short") }
  guard block[0].to_int() == 0 && block[1].to_int() == 2 else {
    raise Failure("rsa block is not PKCS#1 v1.5 type 2")
  }
  let mut at = 2
  while at < block.length() && block[at].to_int() != 0 {
    at = at + 1
  }
  guard at >= 10 && at < block.length() else {
    raise Failure("rsa block has no padding separator")
  }
  block[at + 1:].to_owned()
}

///|
/// The one failure a decrypter reports: the sealed block is not one.
pub(all) suberror Failure {
  Failure(String)
}

///|
pub extend RsaDecrypter with Decrypter::{decrypt}

///|
impl Decrypter for RsaDecrypter with fn decrypt(self, block) {
  pkcs1v15_unpad(self.key.rsadp(block))
}
