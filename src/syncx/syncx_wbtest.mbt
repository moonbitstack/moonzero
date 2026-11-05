///|
test "once runs a body exactly once" {
  let once = Once::new()
  let runs : Ref[Int32] = { val: 0, }
  assert_eq(once.run(() => runs.val = runs.val + 1), true)
  assert_eq(once.run(() => runs.val = runs.val + 1), false)
  assert_eq(once.run(() => runs.val = runs.val + 1), false)
  assert_eq(runs.val, 1)
  assert_eq(once.done(), true)
}

///|
test "a pool reuses what it is given back" {
  let built : Ref[Int32] = { val: 0, }
  let pool : Pool[Int32] = Pool::new(() => {
    built.val = built.val + 1
    built.val
  })
  let first = pool.get()
  let second = pool.get()
  assert_eq(first, 1)
  assert_eq(second, 2)
  pool.put(first)
  assert_eq(pool.idle(), 1)
  assert_eq(pool.get(), 1)
  assert_eq(built.val, 2)
}

///|
async test "singleflight runs one body for concurrent callers" {
  let single : Single[Int32] = Single::new()
  let runs : Ref[Int32] = { val: 0, }
  let body : async () -> Int32 = () => {
    runs.val = runs.val + 1
    @async.sleep(20)
    runs.val
  }
  let answers = @async.all([
    () => single.run("k", body),
    () => single.run("k", body),
    () => single.run("k", body),
  ])
  assert_eq(runs.val, 1)
  assert_eq(answers, [1, 1, 1])
  assert_eq(single.len(), 0)
}

///|
async test "singleflight hands the same failure to every waiter" {
  let single : Single[Int32] = Single::new()
  let runs : Ref[Int32] = { val: 0, }
  let body : async () -> Int32 = () => {
    runs.val = runs.val + 1
    @async.sleep(10)
    raise Failure("nope")
  }
  let callers : Array[async () -> Bool] = [
    () => (single.run("k", body) catch { _ => -1 }) == -1,
    () => (single.run("k", body) catch { _ => -1 }) == -1,
  ]
  let outcomes = @async.all(callers)
  assert_eq(outcomes, [true, true])
  assert_eq(runs.val, 1)
}

///|
suberror Failure {
  Failure(String)
}
