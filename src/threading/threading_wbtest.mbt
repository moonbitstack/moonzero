///|
async test "a routine group runs every body and joins them" {
  let group = RoutineGroup::new()
  let seen : Ref[Int32] = { val: 0, }
  for i = 0; i < 5; i = i + 1 {
    group.run(() => {
      @async.sleep(1)
      seen.val = seen.val + 1
    })
  }
  assert_eq(group.len(), 5)
  group.wait()
  assert_eq(seen.val, 5)
}

///|
async test "a task runner drains its queue in order" {
  let runner : TaskRunner[Int32] = TaskRunner::new()
  let taken : Array[Int32] = []
  for i = 0; i < 3; i = i + 1 {
    runner.push(i + 1)
  }
  runner.close()
  runner.run(item => taken.push(item))
  assert_eq(taken, [1, 2, 3])
}

///|
async test "a stable runner keeps only the newest pending item" {
  let runner : StableRunner[Int32] = StableRunner::new()
  runner.push(1)
  runner.push(2)
  runner.push(3)
  runner.close()
  // The consumer takes the newest item; the two it replaced were dropped by the
  // queue rather than left for a later turn.
  let handled : Array[Int32] = []
  runner.run(item => handled.push(item))
  assert_eq(handled, [3])
}
