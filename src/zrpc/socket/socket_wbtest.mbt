// The socket transport, driven the way a client drives it: a real listener, a real
// connection, and messages that leave this process and come back.
//
// Every listener here asks for port 0 and connects to the port it reports, so two
// runs of the suite — on one machine or on three — never contend for a number.

///|
/// An echo server: every method answers with the bytes it was given.
fn echo_server(names : Array[String]) -> @zrpc.RpcServer {
  let server = @zrpc.RpcServer::new(@conf.RpcServerConf::new(name="echo"))
  let group = server.group("echo.Echo")
  for name in names {
    group.register(name, request => request)
  }
  server
}

///|
/// A chain that lets `/echo.Echo/Open` through and refuses everything else, and
/// records every path it saw — the record is what proves the chain ran at all.
fn open_only(seen : Ref[Array[String]]) -> @zrpc.Interceptor {
  inner => {
    call => {
      seen.val.push(call.path)
      guard call.path == "/echo.Echo/Open" else {
        return Err(@moonrpc.Status::PermissionDenied)
      }
      inner(call)
    }
  }
}

///|
async test "a call crosses a socket and comes back" {
  let listener = Listener::new(echo_server(["Call"]))
  @async.with_task_group(g => {
    g.spawn_bg(() => listener.serve(port=0))
    // The port is known only once the socket exists; the client connects to what the
    // listener reports rather than to a number this file picked.
    let port = listener.bound_port()
    let channel = SocketChannel::connect("127.0.0.1", port)
    assert_eq(channel.call("/echo.Echo/Call", b"hello"), Ok(b"hello"))
    // Close the client before draining the listener: a drain waits for the
    // connections it opened, so a client that closes afterwards would hold it to
    // the full grace period.
    channel.close()
    listener.stop(grace=500)
  })
}

///|
async test "the server's chain runs for a call that arrived on a socket" {
  let seen : Ref[Array[String]] = { val: [], }
  let listener = Listener::new(
    echo_server(["Open", "Closed"]).use_(open_only(seen)),
  )
  @async.with_task_group(g => {
    g.spawn_bg(() => listener.serve(port=0))
    let port = listener.bound_port()
    let channel = SocketChannel::connect("127.0.0.1", port)
    assert_eq(channel.call("/echo.Echo/Open", b"x"), Ok(b"x"))
    assert_eq(
      channel.call("/echo.Echo/Closed", b"x")
      is Err(@moonrpc.Status::PermissionDenied),
      true,
    )
    channel.close()
    listener.stop(grace=500)
  })
  // The chain saw both calls, in the order they were made.
  assert_eq(seen.val, ["/echo.Echo/Open", "/echo.Echo/Closed"])
}

///|
async test "an unknown method is answered Unimplemented, not dropped" {
  let listener = Listener::new(echo_server(["Call"]))
  @async.with_task_group(g => {
    g.spawn_bg(() => listener.serve(port=0))
    let port = listener.bound_port()
    let channel = SocketChannel::connect("127.0.0.1", port)
    assert_eq(
      channel.call("/echo.Echo/Missing", b"x")
      is Err(@moonrpc.Status::Unimplemented),
      true,
    )
    channel.close()
    listener.stop(grace=500)
  })
}

///|
async test "calls on one channel run on their own streams" {
  let listener = Listener::new(echo_server(["Call"]))
  @async.with_task_group(g => {
    g.spawn_bg(() => listener.serve(port=0))
    let port = listener.bound_port()
    let channel = SocketChannel::connect("127.0.0.1", port)
    // Eight calls at once on one connection: each is its own HTTP/2 stream, so none
    // of them waits for another's reply, and each gets its own bytes back.
    let calls : Array[async () -> Result[Bytes, @moonrpc.Status]] = []
    for i = 0; i < 8; i = i + 1 {
      let payload = @utf8.encode("call-" + i.to_string())
      calls.push(() => channel.call("/echo.Echo/Call", payload))
    }
    let replies = @async.all(calls)
    for i = 0; i < 8; i = i + 1 {
      assert_eq(replies[i], Ok(@utf8.encode("call-" + i.to_string())))
    }
    channel.close()
    listener.stop(grace=500)
  })
}

///|
async test "a listener on port 0 reports the port the system chose" {
  let listener = Listener::new(echo_server(["Call"]))
  // Nothing is serving yet, so there is no port to report and nothing to connect to.
  assert_eq(listener.port() is None, true)
  @async.with_task_group(g => {
    g.spawn_bg(() => listener.serve(port=0))
    let port = listener.bound_port()
    // An ephemeral port the system picked, not the 0 the listener was handed.
    assert_eq(port > 1023, true)
    assert_eq(listener.port(), Some(port))
    let channel = SocketChannel::connect("127.0.0.1", port)
    assert_eq(channel.call("/echo.Echo/Call", b"x"), Ok(b"x"))
    channel.close()
    listener.stop(grace=500)
  })
  // A drained listener holds no socket, so it stops naming a port.
  assert_eq(listener.port() is None, true)
}

///|
async test "two listeners on port 0 get their own port and answer their own echoes" {
  let first = Listener::new(echo_server(["First"]))
  let second = Listener::new(echo_server(["Second"]))
  @async.with_task_group(g => {
    g.spawn_bg(() => first.serve(port=0))
    g.spawn_bg(() => second.serve(port=0))
    let first_port = first.bound_port()
    let second_port = second.bound_port()
    assert_eq(first_port == second_port, false)
    let to_first = SocketChannel::connect("127.0.0.1", first_port)
    let to_second = SocketChannel::connect("127.0.0.1", second_port)
    // Each channel reaches the server it was pointed at: the ports are distinct and
    // the listeners are not sharing one socket.
    assert_eq(to_first.call("/echo.Echo/First", b"1"), Ok(b"1"))
    assert_eq(to_second.call("/echo.Echo/Second", b"2"), Ok(b"2"))
    assert_eq(
      to_first.call("/echo.Echo/Second", b"1")
      is Err(@moonrpc.Status::Unimplemented),
      true,
    )
    to_first.close()
    to_second.close()
    first.stop(grace=500)
    second.stop(grace=500)
  })
}

///|
async test "a listener that never bound raises Timeout at the deadline" {
  let listener = Listener::new(echo_server(["Call"]))
  let outcome : Result[Int32, Error] = Ok(listener.bound_port(timeout_ms=20)) catch {
    e => Err(e)
  }
  let raised = match outcome {
    Err(Timeout) => true
    _ => false
  }
  assert_eq(raised, true)
}

///|
async test "bind reports the port before any accept loop is running" {
  let listener = Listener::new(echo_server(["Call"]))
  // The socket exists as soon as bind returns, so the client can be pointed at a
  // number the system picked without waiting for a task to start serving.
  let port = listener.bind(port=0)
  assert_eq(port > 1023, true)
  assert_eq(listener.port(), Some(port))
  @async.with_task_group(g => {
    g.spawn_bg(() => listener.serve())
    let channel = SocketChannel::connect("127.0.0.1", port)
    assert_eq(channel.call("/echo.Echo/Call", b"early"), Ok(b"early"))
    channel.close()
    listener.stop(grace=500)
  })
}

///|
async test "serve accepts on the socket bind already opened" {
  let listener = Listener::new(echo_server(["Call"]))
  let bound = listener.bind(port=0)
  @async.with_task_group(g => {
    g.spawn_bg(() => listener.serve(port=0))
    // serve keeps the socket it was given: a second bind would either fail on the
    // address or move the listener, and a client holding the reported number would
    // then reach nothing.
    assert_eq(listener.port(), Some(bound))
    let channel = SocketChannel::connect("127.0.0.1", bound)
    assert_eq(channel.call("/echo.Echo/Call", b"bound"), Ok(b"bound"))
    channel.close()
    listener.stop(grace=500)
  })
}

///|
async test "a second bind answers the socket that exists" {
  let listener = Listener::new(echo_server(["Call"]))
  let first = listener.bind(port=0)
  let second = listener.bind(port=0)
  assert_eq(second, first)
  listener.stop(grace=500)
}

///|
async test "bound_port on a listener this task bound answers without waiting" {
  let listener = Listener::new(echo_server(["Call"]))
  let bound = listener.bind(port=0)
  // No task is serving: the answer comes from the bind, so a wait here would hang
  // until the deadline rather than return.
  assert_eq(listener.bound_port(timeout_ms=20), bound)
  listener.stop(grace=500)
}
