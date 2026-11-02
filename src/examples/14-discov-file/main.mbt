///|
/// Discovery over a file: a publisher writes what it has registered, and a reader resolves from
/// the file. `FileDiscovery` is a `@moonsd.Discovery` like any other, so a `View` follows it.
///
///     moon run --target native src/examples/14-discov-file
#coverage.skip
async fn main {
  let path = @fs.tmpdir(prefix="moonzero-discov") + "/registry.json"
  let writer = @memory.Registry::new()
  ignore(
    writer.register(
      "greeter",
      @moonzero.Endpoint::new("10.0.0.1", 9090),
      60_000,
    ),
  )
  let second = writer.register(
    "greeter",
    @moonzero.Endpoint::new("10.0.0.2", 9090),
    60_000,
  )
  @discov.publish(path, writer)

  let reader = @discov.FileDiscovery::new(path)
  println("resolved: " + addresses(reader.resolve("greeter")))

  writer.deregister(second)
  @discov.publish(path, writer)
  println("after one left: " + addresses(reader.resolve("greeter")))
}

///|
fn addresses(endpoints : Array[@moonzero.Endpoint]) -> String {
  let all = endpoints.map(e => e.address())
  all.sort()
  all.join(", ")
}
