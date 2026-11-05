// Replay the reference implementation's decision table through this library's
// two-node comparison.
//
// The table is not written here: `scripts/reference/p2c_vector_test.go` runs
// inside a go-zero checkout, beside the picker whose decisions it records, and
// `scripts/gen_reference_vectors.py` turns its output into `p2c_vectors_wbtest.mbt`.
// A row is one pair of node states and the node that picker chose.

///|
/// A node with the given state at `now`: its last pick was `age_ms` ago.
fn vector_node(
  lag : Double,
  inflight : Int64,
  age_ms : Int64,
  now : Int64,
) -> P2cNode {
  {
    lag,
    success: 1000.0,
    inflight,
    requests: 0,
    last: now,
    pick: now - age_ms,
  }
}

///|
test "the two-node comparison agrees with the reference implementation" {
  let vectors = p2c_vectors()
  // A truncated table would still replay green, so the row count is asserted too.
  assert_eq(vectors.length(), 1620)
  let picker = P2c::new()
  let left = @moonsd.Endpoint::new("10.0.0.1", 12001, id="a")
  let right = @moonsd.Endpoint::new("10.0.0.2", 12001, id="b")
  let now = 100_000_000L
  let mut disagreements = 0
  let mut first_disagreement = ""
  for vector in vectors {
    let first = vector_node(vector.lag_a, vector.inflight_a, vector.age_a, now)
    let second = vector_node(vector.lag_b, vector.inflight_b, vector.age_b, now)
    let chosen = picker.choose_pair(first, left, second, right, now)
    if chosen.id != vector.expected {
      disagreements = disagreements + 1
      if first_disagreement == "" {
        first_disagreement = "lag " +
          vector.lag_a.to_string() +
          "/" +
          vector.inflight_a.to_string() +
          " vs " +
          vector.lag_b.to_string() +
          "/" +
          vector.inflight_b.to_string() +
          " age " +
          vector.age_b.to_string() +
          ": chose " +
          chosen.id +
          ", reference chose " +
          vector.expected
      }
    }
  }
  // One message with the first disagreement, so a failure says which row diverged
  // rather than only how many did.
  assert_eq(first_disagreement, "")
  assert_eq(disagreements, 0)
}
