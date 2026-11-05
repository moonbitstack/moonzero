// The RSA decrypter a content-security key set is built from: the PEM reader and
// the PKCS#1 v1.5 unpad it strips.
//
// The key below is a 512-bit one generated for this file, and the sealed block is
// what that key's public half produces from the envelope text — so the case is the
// real operation end to end, not a mock of it.

///|
/// A 512-bit RSA private key, in the `RSA PRIVATE KEY` form a key file carries.
let test_pem : String = "-----BEGIN RSA PRIVATE KEY-----\n" +
  "MIIBOgIBAAJBAK7wHxw7ToSbsz3P5ayTn0j59FUNB7eSx8xrqPQ9LuEjCPg92EQ7\n" +
  "pWw847JzvW22tv2rfWCEwz02KyDnGCjWBusCAwEAAQJAMiMx12aL/2ecfIe8HLUG\n" +
  "fuTciQ+9+XgA+W6VssJiUDW/jolYMcNKCHvTdXZAUayYIITfDiPIzjl2kV2BdVfy\n" +
  "mQIhAMF6BTDRLe4I2pqvH66sDxGeNQBQU/VfIkXKU6ntxfI9AiEA53huIC08y36e\n" +
  "Bf5biwshwQZ6FC9uaNi+txwa4aVkuEcCIQCkOHjtba/JinRatWhz75E+yAV+xa/t\n" +
  "5pkFme2Xn73TlQIgdYReHPX6rLIPFqnp3jD7pR1ds4vVOWP5h8u8Fh27ghcCIErP\n" +
  "oHwRO9NIRgX3DNdlLvpv0uAmdTfiHcwfKLSYTvDZ\n" +
  "-----END RSA PRIVATE KEY-----"

///|
/// The same key in the PKCS#8 `PRIVATE KEY` form.
let test_pkcs8 : String = "-----BEGIN PRIVATE KEY-----\n" +
  "MIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEArvAfHDtOhJuzPc/l\n" +
  "rJOfSPn0VQ0Ht5LHzGuo9D0u4SMI+D3YRDulbDzjsnO9bba2/at9YITDPTYrIOcY\n" +
  "KNYG6wIDAQABAkAyIzHXZov/Z5x8h7wctQZ+5NyJD735eAD5bpWywmJQNb+OiVgx\n" +
  "w0oIe9N1dkBRrJgghN8OI8jOOXaRXYF1V/KZAiEAwXoFMNEt7gjamq8frqwPEZ41\n" +
  "AFBT9V8iRcpTqe3F8j0CIQDneG4gLTzLfp4F/luLCyHBBnoUL25o2L63HBrhpWS4\n" +
  "RwIhAKQ4eO1tr8mKdFq1aHPvkT7IBX7Fr+3mmQWZ7ZefvdOVAiB1hF4c9fqssg8W\n" +
  "qeneMPulHV2zi9U5Y/mHy7wWHbuCFwIgSs+gfBE700hGBfcM12Uu+m/S4CZ1N+Id\n" +
  "zB8otJhO8Nk=\n" +
  "-----END PRIVATE KEY-----"

///|
/// The envelope that key sealed, as the peer would send it: base64 of the RSAES
/// block the public half produced.
fn sealed_block() -> Bytes {
  @base64.decode(
    "VYlERSQ5Y0u/U4AYNYUJKy4RAMLfKKd8mTylzq+AellHrPO7FZpUdH2LXymJLvA/dio44WOvDYlgXmPTcse3Wg==",
  ) catch {
    _ => abort("the fixture block must decode")
  }
}

///|
/// What is inside that block.
let envelope : Bytes = b"key=YWJjZGVmZ2hpamts,time=1700000000,type=0"

///|
test "a sealed envelope opens with the key it was sealed for" {
  let decrypter = RsaDecrypter::from_pem(test_pem) catch {
    _ => abort("the fixture key must parse")
  }
  let opened = decrypter.decrypt(sealed_block()) catch {
    _ => abort("the fixture block must open")
  }
  assert_eq(opened, envelope)
}

///|
test "the PKCS#8 form of the same key opens the same block" {
  let decrypter = RsaDecrypter::from_pem(test_pkcs8) catch {
    _ => abort("the fixture key must parse")
  }
  let opened = decrypter.decrypt(sealed_block()) catch {
    _ => abort("the fixture block must open")
  }
  assert_eq(opened, envelope)
}

///|
test "a block from another key does not open" {
  let decrypter = RsaDecrypter::from_pem(test_pem) catch {
    _ => abort("the fixture key must parse")
  }
  // A block sealed for a different key decrypts to noise, and the padding check is
  // what turns that noise into a refusal instead of a wrong envelope.
  let other : Bytes = @base64.decode(
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
  )
  let outcome = Ok(decrypter.decrypt(other)) catch { _ => Err(0) }
  assert_eq(outcome is Err(_), true)
}

///|
test "a document that is not a key is refused" {
  let outcome = Ok(RsaDecrypter::from_pem("not a pem document at all")) catch {
    _ => Err(0)
  }
  assert_eq(outcome is Err(_), true)
}

///|
test "the padding check names what is wrong with a block" {
  // Too short to carry a separator at all.
  assert_eq(unpad_fails(b"\x00\x02abcdefgh\x00x"), false)
  assert_eq(unpad_fails(b"\x00\x02ab\x00x"), true)
  // Type 1 is signing padding, not encryption padding.
  assert_eq(unpad_fails(b"\x00\x01" + nonzero(8) + b"\x00msg"), true)
  // A separator inside the eight-octet minimum is a block that was built wrong.
  assert_eq(unpad_fails(b"\x00\x02abc\x00msg"), true)
  // No separator at all.
  assert_eq(unpad_fails(b"\x00\x02" + nonzero(20)), true)
  // The one shape that is right.
  let block = b"\x00\x02" + nonzero(8) + b"\x00msg"
  let unpadded = pkcs1v15_unpad(block) catch { _ => b"" }
  assert_eq(unpadded, b"msg")
}

///|
/// Eight non-zero octets, the shortest padding a PKCS#1 v1.5 block may carry.
fn nonzero(n : Int32) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < n; i = i + 1 {
    out.push((i + 1).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Whether the unpad refuses `block`.
fn unpad_fails(block : Bytes) -> Bool {
  let outcome = Ok(pkcs1v15_unpad(block)) catch { _ => Err(0) }
  outcome is Err(_)
}
