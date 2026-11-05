// Map-reduce over an array.
//
// The shape is the reference implementation's: a mapper sees one item and emits
// any number of values, and a `finish` step runs once after the last item so an
// aggregate that only makes sense at the end — a top ten, a digest — can be
// emitted too. The reducer then sees everything emitted, in order.

///|
/// A mapper: `map` sees one item and emits values with `emit`; `finish` runs after
/// the last item, for whatever an aggregate can only produce once the stream is
/// done.
pub(all) struct Mapper[A, B] {
  map : (A, (B) -> Unit) -> Unit
  finish : ((B) -> Unit) -> Unit
}

///|
/// A mapper from a function that emits per item. `finish` does nothing unless one
/// is given.
pub fn[A, B] Mapper::new(
  map~ : (A, (B) -> Unit) -> Unit,
  finish~ : ((B) -> Unit) -> Unit = _emit => (),
) -> Mapper[A, B] {
  { map, finish, }
}

///|
/// A mapper that emits exactly one value per item — the common case.
pub fn[A, B] Mapper::one(f : (A) -> B) -> Mapper[A, B] {
  { map: (item, emit) => emit(f(item)), finish: _emit => (), }
}

///|
/// Run `mapper` over `source` and hand every emitted value to `reducer`, in the
/// order the items were visited.
pub fn[A, B, C] map_reduce(
  source : Array[A],
  mapper : Mapper[A, B],
  reducer : (Array[B]) -> C,
) -> C {
  let emitted : Array[B] = []
  let emit : (B) -> Unit = value => emitted.push(value)
  for item in source {
    (mapper.map)(item, emit)
  }
  (mapper.finish)(emit)
  reducer(emitted)
}

///|
/// `map_reduce` with the mapping split across at most `max_concurrent` tasks.
///
/// The items are cut into one run per task, each run emits into its own array, and
/// the arrays are concatenated in slice order — so the result is the same one the
/// sequential run produces, whatever order the tasks happened to finish in.
pub async fn[A, B, C] map_reduce_parallel(
  source : Array[A],
  mapper : Mapper[A, B],
  reducer : (Array[B]) -> C,
  max_concurrent~ : Int32 = 4,
) -> C {
  let workers = if max_concurrent < 1 { 1 } else { max_concurrent }
  let chunks = slice(source, workers)
  let runs : Array[async () -> Array[B]] = chunks.map(chunk => {
    () => {
      let emitted : Array[B] = []
      let emit : (B) -> Unit = value => emitted.push(value)
      for item in chunk {
        (mapper.map)(item, emit)
      }
      emitted
    }
  })
  let parts = @async.all(runs, max_concurrent=workers)
  let emitted : Array[B] = []
  for part in parts {
    for value in part {
      emitted.push(value)
    }
  }
  // `finish` runs once, after the merge, so an aggregate is not emitted per task.
  (mapper.finish)(value => emitted.push(value))
  reducer(emitted)
}

///|
/// Cut `items` into at most `parts` contiguous slices of near-equal length.
fn[A] slice(items : Array[A], parts : Int32) -> Array[Array[A]] {
  let out : Array[Array[A]] = []
  let total = items.length()
  let count = if parts > total { total } else { parts }
  guard count > 0 else { return [items] }
  let base = total / count
  let extra = total % count
  let mut at = 0
  for i = 0; i < count; i = i + 1 {
    let size = base + (if i < extra { 1 } else { 0 })
    let part : Array[A] = []
    for j = at; j < at + size; j = j + 1 {
      part.push(items[j])
    }
    out.push(part)
    at = at + size
  }
  out
}
