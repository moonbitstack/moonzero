///|
/// Group `items` by `key`, keeping the items of each group in the order they
/// arrived. The groups come out in the order their first item did, so a report over
/// them is stable.
pub fn[A, K : Hash + Eq] group_by(
  items : Array[A],
  key : (A) -> K,
) -> Array[(K, Array[A])] {
  let order : Array[K] = []
  let groups : Map[K, Array[A]] = Map([])
  for item in items {
    let k = key(item)
    match groups.get(k) {
      Some(group) => group.push(item)
      None => {
        let group : Array[A] = [item]
        groups[k] = group
        order.push(k)
      }
    }
  }
  order.map(k => (k, groups.get(k).unwrap()))
}

///|
/// Cut `items` into consecutive chunks of `size`, the last one possibly shorter.
pub fn[A] chunk(items : Array[A], size : Int32) -> Array[Array[A]] {
  let out : Array[Array[A]] = []
  guard size > 0 else { return out }
  let mut at = 0
  while at < items.length() {
    let part : Array[A] = []
    let mut end = at + size
    if end > items.length() {
      end = items.length()
    }
    for i = at; i < end; i = i + 1 {
      part.push(items[i])
    }
    out.push(part)
    at = end
  }
  out
}
