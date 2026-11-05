///|
/// A driver that records what it was asked to do, so a transaction's outcome is
/// visible as the calls it made.
struct Recorder {
  trace : Array[String]
}

///|
fn Recorder::new() -> Recorder {
  { trace: [], }
}

///|
pub extend Recorder with @moondb.Driver::{
  execute,
  query,
  query_stream,
  begin,
  commit,
  rollback,
  close,
  ping,
}

///|
pub impl @moondb.Driver for Recorder with fn execute(
  self : Recorder,
  query : String,
  _args : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.trace.push("execute " + query)
  { rows_affected: 1L, last_insert_id: 0L, }
}

///|
pub impl @moondb.Driver for Recorder with fn query(
  self : Recorder,
  query : String,
  _args : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.trace.push("query " + query)
  [@moondb.Row::{ columns: ["n"], values: [@moondb.Value::Int(7)], }]
}

///|
pub impl @moondb.Driver for Recorder with fn begin(self : Recorder) -> Unit raise @moondb.DbError {
  self.trace.push("begin")
}

///|
pub impl @moondb.Driver for Recorder with fn commit(self : Recorder) -> Unit raise @moondb.DbError {
  self.trace.push("commit")
}

///|
pub impl @moondb.Driver for Recorder with fn rollback(self : Recorder) -> Unit raise @moondb.DbError {
  self.trace.push("rollback")
}

///|
pub impl @moondb.Driver for Recorder with fn close(self : Recorder) -> Unit {
  self.trace.push("close")
}

///|
/// One failure a test transaction raises.
suberror Failure {
  Failure(String)
}

///|
async test "a statement and a query reach the driver" {
  let recorder = Recorder::new()
  let sql = Sql::blocking(recorder)
  let result = sql.exec("UPDATE t SET a = 1")
  assert_eq(result.rows_affected, 1L)
  let rows = sql.query("SELECT n FROM t")
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), 7)
  assert_eq(recorder.trace, [
    "execute UPDATE t SET a = 1", "query SELECT n FROM t",
  ])
}

///|
async test "a transaction commits when the body returns" {
  let recorder = Recorder::new()
  let sql = Sql::blocking(recorder)
  let value = sql.transact(body => body.exec("INSERT INTO t VALUES (1)"))
  assert_eq(value.rows_affected, 1L)
  assert_eq(value.last_insert_id, 0L)
  assert_eq(recorder.trace, [
    "begin", "execute INSERT INTO t VALUES (1)", "commit",
  ])
}

///|
async test "a transaction rolls back when the body raises" {
  let recorder = Recorder::new()
  let sql = Sql::blocking(recorder)
  let outcome = try {
    let _ = sql.transact(_body => {
      raise Failure("halfway")
      0
    })
    Ok(0)
  } catch {
    Failure(_) => Err(0)
    _ => Err(-1)
  }
  assert_eq(outcome, Err(0))
  assert_eq(recorder.trace, ["begin", "rollback"])
}

///|
async test "a scalar reads one column of the first row" {
  let recorder = Recorder::new()
  let sql = Sql::blocking(recorder)
  let value : Int32? = sql.scalar("SELECT n FROM t")
  assert_eq(value, Some(7))
}
