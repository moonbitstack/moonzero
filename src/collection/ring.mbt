///|
/// A fixed-size circular buffer: pushing past the capacity overwrites the oldest
/// sample. What a service keeps its last N events, timings or failures in.
pub struct Ring[T] {
  slots : Array[T?]
  capacity : Int32
  mut start : Int32
  mut size : Int32
}

///|
/// A ring holding at most `capacity` items.
///
/// # Parameters
/// - `capacity` : how many items it keeps; `0` is raised to `1`, because a ring of
///   nothing could never hold a sample
pub fn[T] Ring::new(capacity : Int32) -> Ring[T] {
  let capacity = if capacity < 1 { 1 } else { capacity }
  { slots: Array::make(capacity, None), capacity, start: 0, size: 0, }
}

///|
/// Append a sample, overwriting the oldest one when the ring is full.
pub fn[T] Ring::push(self : Ring[T], item : T) -> Unit {
  if self.size < self.capacity {
    let at = (self.start + self.size) % self.capacity
    self.slots[at] = Some(item)
    self.size = self.size + 1
  } else {
    self.slots[self.start] = Some(item)
    self.start = (self.start + 1) % self.capacity
  }
}

///|
/// The sample `i` places from the oldest, or `None` past the end.
pub fn[T] Ring::get(self : Ring[T], i : Int32) -> T? {
  guard i >= 0 && i < self.size else { None }
  self.slots[(self.start + i) % self.capacity]
}

///|
/// The newest sample.
pub fn[T] Ring::last(self : Ring[T]) -> T? {
  if self.size == 0 {
    None
  } else {
    self.get(self.size - 1)
  }
}

///|
/// How many samples are held.
pub fn[T] Ring::len(self : Ring[T]) -> Int32 {
  self.size
}

///|
/// The capacity it was built with.
pub fn[T] Ring::capacity(self : Ring[T]) -> Int32 {
  self.capacity
}

///|
/// The samples, oldest first.
pub fn[T] Ring::to_array(self : Ring[T]) -> Array[T] {
  let out : Array[T] = []
  for i = 0; i < self.size; i = i + 1 {
    if self.get(i) is Some(item) {
      out.push(item)
    }
  }
  out
}
