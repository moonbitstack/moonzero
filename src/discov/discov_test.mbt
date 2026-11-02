///|
const WEB = "web"

///|
async fn registered(
  registry : @memory.Registry,
  endpoint : @moonsd.Endpoint,
) -> @moonsd.Lease {
  registry.register(WEB, endpoint, 60_000)
}

///|
async test "what one process publishes, another resolves" {
  let path = @fs.tmpdir(prefix="mz-file") + "/registry.json"
  let reader = @discov.FileDiscovery::new(path)
  assert_eq(reader.resolve(WEB), [])
  let writer = @memory.Registry::new()
  let lease = registered(writer, @moonsd.Endpoint::new("10.0.0.7", 9001))
  @discov.publish(path, writer)
  assert_eq(reader.resolve(WEB).map(e => e.address()), ["10.0.0.7:9001"])
  writer.deregister(lease)
  @discov.publish(path, writer)
  assert_eq(reader.resolve(WEB), [])
}

///|
async test "a watcher wakes when the file changes" {
  let path = @fs.tmpdir(prefix="mz-watch") + "/registry.json"
  let writer = @memory.Registry::new()
  @discov.publish(path, writer)
  let watcher = @discov.FileDiscovery::new(path).watch(WEB)
  defer watcher.close()
  assert_eq(watcher.next().endpoints, [])
  ignore(registered(writer, @moonsd.Endpoint::new("10.0.0.7", 9001)))
  @discov.publish(path, writer)
  let update = @async.with_timeout(5000, () => watcher.next())
  assert_eq(update.endpoints.length(), 1)
}

///|
async test "a view over a file answers without waiting" {
  let path = @fs.tmpdir(prefix="mz-view") + "/registry.json"
  let writer = @memory.Registry::new()
  ignore(registered(writer, @moonsd.Endpoint::new("10.0.0.7", 9001)))
  @discov.publish(path, writer)
  let view = @moonsd.View::new()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      view.follow(@discov.FileDiscovery::new(path), WEB)
    })
    for _ in 0..<100 {
      if !view.endpoints().is_empty() {
        break
      }
      @async.sleep(20)
    }
  })
  assert_eq(view.endpoints().length(), 1)
}
