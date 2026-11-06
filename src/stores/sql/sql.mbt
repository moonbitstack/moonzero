// SQL over moondb's asynchronous driver contract.

///|
/// A handle on a database (← go-zero's `sqlx.SqlConn`): statements, rows and
/// transactions, with the driver supplied by the caller so one service works over
/// SQLite in a test and over Postgres in production without changing a line.
pub struct Sql {
  driver : &@moondb.AsyncDriver
}

///|
/// A handle over `driver`.
pub fn Sql::new(driver : &@moondb.AsyncDriver) -> Sql {
  { driver, }
}

///|
/// A handle over a synchronous driver. The calls still happen inside the async
/// function, so a blocking driver occupies the task it runs on — which is what a
/// service over an embedded database wants and what a test uses.
pub fn Sql::blocking(driver : &@moondb.Driver) -> Sql {
  Sql::new(Blocking::new(driver))
}

///|
/// A synchronous driver seen through the asynchronous contract.
struct Blocking {
  inner : &@moondb.Driver
}

///|
/// Wrap a synchronous driver.
fn Blocking::new(inner : &@moondb.Driver) -> Blocking {
  { inner, }
}

///|
pub extend Blocking with @moondb.AsyncDriver::{
  execute,
  query,
  query_stream,
  begin,
  commit,
  rollback,
  close,
  ping,
  prepare,
  dialect,
  capabilities,
}

///|
pub impl @moondb.AsyncDriver for Blocking with fn execute(
  self : Blocking,
  query : String,
  args : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.inner.execute(query, args)
}

///|
pub impl @moondb.AsyncDriver for Blocking with fn query(
  self : Blocking,
  query : String,
  args : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.inner.query(query, args)
}

///|
pub impl @moondb.AsyncDriver for Blocking with fn begin(self : Blocking) -> Unit raise @moondb.DbError {
  self.inner.begin()
}

///|
pub impl @moondb.AsyncDriver for Blocking with fn commit(self : Blocking) -> Unit raise @moondb.DbError {
  self.inner.commit()
}

///|
pub impl @moondb.AsyncDriver for Blocking with fn rollback(self : Blocking) -> Unit raise @moondb.DbError {
  self.inner.rollback()
}

///|
pub impl @moondb.AsyncDriver for Blocking with fn close(self : Blocking) -> Unit {
  self.inner.close()
}

///|
pub impl @moondb.AsyncDriver for Blocking with fn ping(self : Blocking) -> Bool {
  self.inner.ping()
}

///|
/// The wrapped driver's dialect: the default would report SQLite for every backend.
pub impl @moondb.AsyncDriver for Blocking with fn dialect(self : Blocking) -> @moondb.Dialect {
  self.inner.dialect()
}

///|
pub impl @moondb.AsyncDriver for Blocking with fn capabilities(self : Blocking) -> @moondb.Capabilities {
  self.inner.capabilities()
}

///|
/// Run a statement and report how many rows it touched.
pub async fn Sql::exec(
  self : Sql,
  query : String,
  args~ : Array[@moondb.Value] = [],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.driver.execute(query, args)
}

///|
/// Run a query and return every row.
pub async fn Sql::query(
  self : Sql,
  query : String,
  args~ : Array[@moondb.Value] = [],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.driver.query(query, args)
}

///|
/// Run a query and return its first row, or `None` when it matched nothing.
pub async fn Sql::one(
  self : Sql,
  query : String,
  args~ : Array[@moondb.Value] = [],
) -> @moondb.Row? raise @moondb.DbError {
  let rows = self.driver.query(query, args)
  rows.get(0)
}

///|
/// Run a query and read one column of its first row as `T`, which is what most
/// callers of `one` actually want.
pub async fn[T : @moondb.FromValue] Sql::scalar(
  self : Sql,
  query : String,
  args~ : Array[@moondb.Value] = [],
) -> T? raise @moondb.DbError {
  match self.one(query, args~) {
    Some(row) => Some(row.read(0))
    None => None
  }
}

///|
/// Run `body` inside a transaction: it commits when the body returns and rolls back
/// when it raises, so a failure halfway through leaves nothing behind.
///
/// The body receives a `Sql` bound to the same driver — the driver is the
/// transaction, in this contract — so a nested call cannot silently start a second
/// one.
pub async fn[T] Sql::transact(self : Sql, body : async (Sql) -> T) -> T {
  self.driver.begin()
  let outcome : Result[T, Error] = Ok(body(self)) catch { error => Err(error) }
  match outcome {
    Ok(value) => {
      self.driver.commit()
      value
    }
    Err(error) => {
      self.driver.rollback() catch {
        _ => ()
      }
      raise error
    }
  }
}

///|
/// Whether the database answers.
pub async fn Sql::ping(self : Sql) -> Bool {
  self.driver.ping()
}

///|
/// How many of `rows` match `predicate` — the counting pass a page of results is
/// paired with.
pub fn count_rows(
  rows : Array[@moondb.Row],
  predicate : (@moondb.Row) -> Bool,
) -> Int32 {
  let mut count = 0
  for row in rows {
    if predicate(row) {
      count = count + 1
    }
  }
  count
}
