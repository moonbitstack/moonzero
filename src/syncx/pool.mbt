///|
/// A pool of reusable objects: a caller takes one, uses it, and hands it back.
/// Building is deferred until the first take, so a pool nobody touches costs
/// nothing — which is what makes it usable for a buffer or a connection that only
/// some code paths need.
pub struct Pool[T] {
  make : () -> T
  idle : Array[T]
}

///|
/// A pool that builds its objects with `make`.
pub fn[T] Pool::new(make : () -> T) -> Pool[T] {
  { make, idle: [], }
}

///|
/// Take an object: an idle one when there is one, a fresh one otherwise.
pub fn[T] Pool::get(self : Pool[T]) -> T {
  match self.idle.pop() {
    Some(item) => item
    None => (self.make)()
  }
}

///|
/// Hand an object back. The pool keeps every one it is given, so a caller that
/// wants a ceiling on retained objects puts one on its own side.
pub fn[T] Pool::put(self : Pool[T], item : T) -> Unit {
  self.idle.push(item)
}

///|
/// How many objects are idle.
pub fn[T] Pool::idle(self : Pool[T]) -> Int32 {
  self.idle.length()
}
