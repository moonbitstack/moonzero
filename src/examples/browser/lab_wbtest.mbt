// The page's two benches, driven the way the page drives them. These pin the numbers
// a reader can see: if the page's glue stops matching the library, the bench shows a
// figure nobody meant and these tests say so first.

///|
test "the picker takes its calls from the slow instance" {
  mz_lab_p2c(2, 2, 120, 300)
  let total = mz_lab_p2c_picks(0) + mz_lab_p2c_picks(1) + mz_lab_p2c_picks(2)
  assert_eq(total, 300)
  // The slow instance is not avoided outright — the picker forces it back in — but it
  // carries a small share of the calls.
  assert_eq(mz_lab_p2c_picks(2) < 20, true)
  // Its load is the largest of the three, which is what the readout says.
  assert_eq(mz_lab_p2c_load(2) > mz_lab_p2c_load(0), true)
}

///|
test "the same sliders draw the same picks" {
  mz_lab_p2c(5, 5, 80, 200)
  let first = [mz_lab_p2c_picks(0), mz_lab_p2c_picks(1), mz_lab_p2c_picks(2)]
  mz_lab_p2c(5, 5, 80, 200)
  let second = [mz_lab_p2c_picks(0), mz_lab_p2c_picks(1), mz_lab_p2c_picks(2)]
  assert_eq(first, second)
}

///|
test "a pick out of range answers zero rather than reading past the run" {
  mz_lab_p2c(2, 2, 2, 30)
  assert_eq(mz_lab_p2c_picks(-1), 0)
  assert_eq(mz_lab_p2c_picks(3), 0)
  assert_eq(mz_lab_p2c_load(9), 0)
}

///|
test "the bucket admits its rate over the window, plus the burst" {
  let admitted = mz_lab_bucket(50, 20, 200)
  assert_eq(mz_lab_bucket_refused() > 0, true)
  // Five seconds at fifty a second, plus the twenty it started with: the window's
  // own arithmetic, not a rounded figure.
  assert_eq(admitted <= 270, true)
  assert_eq(admitted >= 265, true)
}

///|
test "demand under the rate is admitted without a refusal" {
  let admitted = mz_lab_bucket(50, 20, 40)
  assert_eq(admitted, 200)
  assert_eq(mz_lab_bucket_refused(), 0)
}
