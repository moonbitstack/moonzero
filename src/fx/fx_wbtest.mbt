///|
suberror Failure {
  Failure(String)
}

///|
test "retry stops at the first success" {
  let attempts : Ref[Int32] = { val: 0, }
  let body : () -> Int32 raise = () => {
    attempts.val = attempts.val + 1
    if attempts.val < 3 {
      raise Failure("again")
    }
    attempts.val
  }
  let value = retry(body)
  assert_eq(value, 3)
  assert_eq(attempts.val, 3)
}

///|
test "retry reports the last failure when every attempt fails" {
  let attempts : Ref[Int32] = { val: 0, }
  let outcome = try {
    let body : () -> Int32 raise = () => {
      attempts.val = attempts.val + 1
      raise Failure("always")
    }
    let _ = retry(body, attempts=4)
    Ok(0)
  } catch {
    Failure(_) => Err(attempts.val)
    _ => Err(-1)
  }
  assert_eq(outcome, Err(4))
}

///|
test "a fatal failure is not retried" {
  let attempts : Ref[Int32] = { val: 0, }
  let _ = try {
    let body : () -> Int32 raise = () => {
      attempts.val = attempts.val + 1
      raise Failure("fatal")
    }
    let _ = retry(body, attempts=5, fatal=_error => true)
  } catch {
    _ => ()
  }
  assert_eq(attempts.val, 1)
}

///|
/// A body that takes half a second — far past the deadline the test gives it.
async fn slow_body() -> Int32 {
  @async.sleep(500)
  1
}

///|
/// A body that answers at once.
async fn fast_body() -> Int32 {
  @async.pause()
  7
}

///|
async test "a body past its deadline is abandoned" {
  let outcome = timeout(10, slow_body) catch { _ => Some(-1) }
  assert_eq(outcome, None)
  let quick = timeout(500, fast_body) catch { _ => None }
  assert_eq(quick, Some(7))
}

///|
test "grouping keeps arrival order both ways" {
  let groups = group_by([1, 2, 3, 4, 5], x => x % 2)
  assert_eq(groups, [(1, [1, 3, 5]), (0, [2, 4])])
}

///|
test "chunking leaves a short tail" {
  assert_eq(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
  let none : Array[Int32] = []
  assert_eq(chunk(none, 2), [])
  assert_eq(chunk([1, 2], 0).length(), 0)
}
