///|
/// A set of tasks that are started together and joined together.
///
/// Bodies are collected first and run at `wait`, which is what makes the group
/// usable while the tasks they depend on are still being decided: a fan-out whose
/// width comes from the data does not have to know that width up front.
pub struct RoutineGroup {
  tasks : Array[async () -> Unit]
}

///|
/// A group with nothing in it.
pub fn RoutineGroup::new() -> RoutineGroup {
  { tasks: [], }
}

///|
/// Add a body to the group. The bodies run concurrently when `wait` is called.
pub fn RoutineGroup::run(self : RoutineGroup, body : async () -> Unit) -> Unit {
  self.tasks.push(body)
}

///|
/// How many bodies are waiting.
pub fn RoutineGroup::len(self : RoutineGroup) -> Int32 {
  self.tasks.length()
}

///|
/// Run every body concurrently and return when all of them have finished. A body
/// that raises cancels the others and the failure reaches the caller.
pub async fn RoutineGroup::wait(self : RoutineGroup) -> Unit {
  let runs : Array[async () -> Unit] = self.tasks.map(body => body)
  let _ = @async.all(runs)
}
