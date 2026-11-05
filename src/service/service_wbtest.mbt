///|
async test "a service group runs every member and returns when they finish" {
  let group = ServiceGroup::new()
  let seen : Ref[Int32] = { val: 0, }
  group.add_fn("first", () => {
    @async.sleep(1)
    seen.val = seen.val + 1
  })
  group.add_fn("second", () => {
    @async.sleep(2)
    seen.val = seen.val + 2
  })
  assert_eq(group.names(), ["first", "second"])
  group.start()
  assert_eq(seen.val, 3)
}

///|
suberror Failure {
  Failure(String)
}

///|
async test "one failing member stops the whole group" {
  let group = ServiceGroup::new()
  let survived : Ref[Bool] = { val: true, }
  group.add_fn("slow", () => {
    @async.sleep(5_000)
    survived.val = false
  })
  group.add_fn("broken", () => {
    @async.sleep(1)
    raise Failure("died")
  })
  let outcome = try {
    group.start()
    Ok(0)
  } catch {
    Failure(_) => Err(1)
    _ => Err(-1)
  }
  assert_eq(outcome, Err(1))
  // The slow member was cancelled rather than left running behind a failed start.
  assert_eq(survived.val, true)
}
