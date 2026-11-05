///|
/// A runner that keeps only the newest pending item: pushing while the consumer is
/// busy replaces what it will take next, so a burst collapses to its last value.
///
/// A service uses it for work that is idempotent and worth doing only once — a
/// configuration reload, a cache refresh, a re-index triggered by a write.
pub struct StableRunner[T] {
  queue : @aqueue.Queue[T]
}

///|
/// A stable runner with nothing pending. The queue holds one item and drops the
/// oldest when a newer one arrives, so a producer never waits and never queues more
/// than one turn of work.
pub fn[T] StableRunner::new() -> StableRunner[T] {
  { queue: @aqueue.Queue::Queue(kind=DiscardOldest(1)), }
}

///|
/// Make `item` the pending one, replacing whatever was pending. The queue holds one
/// item and discards the older one, so this never waits for the consumer.
pub async fn[T] StableRunner::push(self : StableRunner[T], item : T) -> Unit {
  self.queue.put(item)
}

///|
/// Take the pending item and hand it to `handle`, one at a time, until the runner is
/// closed.
pub async fn[T] StableRunner::run(
  self : StableRunner[T],
  handle : async (T) -> Unit,
) -> Unit {
  while true {
    let item = Some(self.queue.get()) catch { _ => None }
    match item {
      Some(item) => handle(item)
      None => return
    }
  }
}

///|
/// Stop accepting work and wake the consumer so it can finish.
pub fn[T] StableRunner::close(self : StableRunner[T]) -> Unit {
  self.queue.close()
}
