///|
/// A body that runs at most once: the first caller runs it, every later one is a
/// no-op. Guards one-time initialisation, which in a service is a pool, a table or
/// a connection that must not be built twice.
pub struct Once {
  mut done : Bool
}

///|
/// A body that has not run yet.
pub fn Once::new() -> Once {
  { done: false, }
}

///|
/// Whether the body has run.
pub fn Once::done(self : Once) -> Bool {
  self.done
}

///|
/// Run `body` unless it has already run, and report whether this call ran it.
pub fn Once::run(self : Once, body : () -> Unit) -> Bool {
  if self.done {
    false
  } else {
    self.done = true
    body()
    true
  }
}
