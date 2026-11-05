///|
/// One service in a group: a name, so a failure can say which one it was, and the
/// body that runs it until it is cancelled.
pub(all) struct Service {
  name : String
  start : async () -> Unit
}

///|
/// A named service.
pub fn Service::new(name : String, start : async () -> Unit) -> Service {
  { name, start, }
}

///|
/// Several services run as one process (← go-zero's `service.Group`).
///
/// Every service is a task that runs until it returns or is cancelled, so a server
/// loop and a background refresher share one lifetime: when the first fails, the
/// rest are cancelled and the failure reaches the caller rather than leaving half a
/// process running.
pub struct ServiceGroup {
  services : Array[Service]
}

///|
/// A group with nothing in it.
pub fn ServiceGroup::new() -> ServiceGroup {
  { services: [], }
}

///|
/// Add a service to the group.
pub fn ServiceGroup::add(self : ServiceGroup, service : Service) -> Unit {
  self.services.push(service)
}

///|
/// Add a service under `name`.
pub fn ServiceGroup::add_fn(
  self : ServiceGroup,
  name : String,
  start : async () -> Unit,
) -> Unit {
  self.add({ name, start, })
}

///|
/// The names of the services in the group, in the order they were added.
pub fn ServiceGroup::names(self : ServiceGroup) -> Array[String] {
  self.services.map(service => service.name)
}

///|
/// Run every service concurrently and return when all of them have finished.
///
/// A service that fails cancels the others, so a group either runs or reports what
/// stopped it — it never leaves a member behind.
pub async fn ServiceGroup::start(self : ServiceGroup) -> Unit {
  let runs : Array[async () -> Unit] = self.services.map(service => {
    service.start
  })
  let _ = @async.all(runs)
}
