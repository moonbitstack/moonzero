// Redis behind the cache's `Store` contract.

///|
/// A `Store` whose entries live in redis, under a key prefix. Every key is
/// `prefix + key`, so one redis serves several caches without them colliding.
pub struct RedisStore {
  client : @moonredis.Client
  prefix : String
}

///|
/// A store over `client`, prefixing every key with `prefix`.
pub fn RedisStore::new(
  client : @moonredis.Client,
  prefix~ : String = "",
) -> RedisStore {
  { client, prefix, }
}

///|
/// The redis client this store writes through, for a caller that needs a command
/// the cache does not use.
pub fn RedisStore::client(self : RedisStore) -> @moonredis.Client {
  self.client
}

///|
/// The key actually written for `key`.
pub fn RedisStore::key_of(self : RedisStore, key : String) -> String {
  self.prefix + key
}

///|
/// A byte string as a Latin-1 string: one character per octet, which is the only
/// mapping a `String`-valued client can carry without losing a byte. A cached value
/// is opaque here — it may be a serialised record or a compressed blob.
pub fn to_latin1(bytes : BytesView) -> String {
  let sb = StringBuilder()
  for i = 0; i < bytes.length(); i = i + 1 {
    sb.write_char(bytes[i].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// The inverse of `to_latin1`: the octets a Latin-1 string stands for.
pub fn of_latin1(text : String) -> Bytes {
  let buf = Buffer()
  for i = 0; i < text.length(); i = i + 1 {
    buf.write_byte((text[i].to_int() & 0xFF).to_byte())
  }
  buf.to_bytes()
}

///|
pub impl @cache.Store for RedisStore with fn get(
  self : RedisStore,
  key : String,
) -> Bytes? raise {
  self.client.get(self.key_of(key)) catch {
    _ => raise @cache.Refused("redis get failed for " + key)
  }
}

///|
pub impl @cache.Store for RedisStore with fn set(
  self : RedisStore,
  key : String,
  value : Bytes,
  ttl_ms : Int64,
) -> Unit raise {
  let text = to_latin1(value[:])
  let redis_key = self.key_of(key)
  let wrote : Result[Bool, Error] = try {
    if ttl_ms > 0L {
      Ok(self.client.set(redis_key, text, px=ttl_ms))
    } else {
      Ok(self.client.set(redis_key, text))
    }
  } catch {
    error => Err(error)
  }
  match wrote {
    Ok(_) => ()
    Err(_) => raise @cache.Refused("redis set failed for " + key)
  }
}

///|
pub impl @cache.Store for RedisStore with fn del(
  self : RedisStore,
  key : String,
) -> Unit raise {
  let _ = self.client.del([self.key_of(key)]) catch {
    _ => raise @cache.Refused("redis del failed for " + key)
  }
}

///|
pub extend RedisStore with @cache.Store::{get, set, del}

///|
/// Add `delta` to the counter under `key` and return the new value. A counter is not
/// a cached value: it lives in redis so every replica increments one number.
pub async fn RedisStore::add(
  self : RedisStore,
  key : String,
  delta : Int64,
) -> Int64 raise @cache.Refused {
  self.client.incrby(self.key_of(key), delta) catch {
    _ => raise @cache.Refused("redis incrby failed for " + key)
  }
}

///|
/// How long `key` has left, in milliseconds; `-2` when it does not exist and `-1`
/// when it has no expiry.
pub async fn RedisStore::ttl_ms(
  self : RedisStore,
  key : String,
) -> Int64 raise @cache.Refused {
  self.client.pttl(self.key_of(key)) catch {
    _ => raise @cache.Refused("redis pttl failed for " + key)
  }
}

///|
/// Drop every TTL under the prefix and let them expire with `ttl_ms` instead — what a
/// deploy does after changing how long a cache entry should live.
pub async fn RedisStore::re_expire(
  self : RedisStore,
  ttl_ms : Int64,
) -> Int32 raise @cache.Refused {
  let keys = self.client.keys(self.prefix + "*") catch {
    _ => raise @cache.Refused("redis keys failed for " + self.prefix)
  }
  let mut changed = 0
  for key in keys {
    let done = self.client.expire(key, ttl_ms / 1000L) catch {
      _ => raise @cache.Refused("redis expire failed for " + key)
    }
    if done {
      changed = changed + 1
    }
  }
  changed
}
