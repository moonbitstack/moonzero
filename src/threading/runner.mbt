///|
/// A queue drained by one consumer: `push` hands work over and returns, `run` is the
/// loop that takes it. What a service uses when the work must not run on the
/// request's own task — a write-behind, a slow notification.
pub struct TaskRunner[T] {
  queue : @aqueue.Queue[T]
}

///|
/// A runner with an unbounded queue.
pub fn[T] TaskRunner::new() -> TaskRunner[T] {
  { queue: @aqueue.Queue::Queue(kind=Unbounded), }
}

///|
/// Hand one item to the consumer, waiting if the queue is bounded and full.
pub async fn[T] TaskRunner::push(self : TaskRunner[T], item : T) -> Unit {
  self.queue.put(item)
}

///|
/// Try to hand one item over without waiting; `false` when the queue is full or
/// already closed.
pub fn[T] TaskRunner::try_push(self : TaskRunner[T], item : T) -> Bool {
  self.queue.try_put(item) catch {
    _ => false
  }
}

///|
/// Drain the queue, handing each item to `handle`, until the runner is closed. A
/// handler that raises stops the loop and the failure reaches whoever is waiting
/// for the service.
pub async fn[T] TaskRunner::run(
  self : TaskRunner[T],
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
pub fn[T] TaskRunner::close(self : TaskRunner[T]) -> Unit {
  self.queue.close()
}
