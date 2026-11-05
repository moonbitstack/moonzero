///|
test "a mapper that emits several values per item" {
  let expanded = Mapper::new(map=(item : Int32, emit) => {
    for i = 0; i < item; i = i + 1 {
      emit(i)
    }
  })
  let seen = map_reduce([1, 2, 3], expanded, emitted => emitted)
  assert_eq(seen, [0, 0, 1, 0, 1, 2])
}

///|
test "finish runs once after the last item" {
  let trailing = Mapper::new(map=(item : Int32, emit) => emit(item), finish=emit => {
    emit(99)
  })
  let seen = map_reduce([1, 2], trailing, emitted => emitted)
  assert_eq(seen, [1, 2, 99])
}

///|
test "one-value mapping and a reducer" {
  let doubled = Mapper::one((x : Int32) => x * 2)
  let total = map_reduce([1, 2, 3], doubled, values => {
    let mut sum = 0
    for value in values {
      sum = sum + value
    }
    sum
  })
  assert_eq(total, 12)
}

///|
async test "the parallel run emits in input order" {
  let doubled = Mapper::one((x : Int32) => x * 2)
  let seen = map_reduce_parallel(
    [1, 2, 3, 4, 5],
    doubled,
    values => values,
    max_concurrent=2,
  )
  assert_eq(seen, [2, 4, 6, 8, 10])
  // an empty source is not a special case
  let none = map_reduce_parallel(Array::make(0, 0), doubled, values => values)
  assert_eq(none, [])
}
