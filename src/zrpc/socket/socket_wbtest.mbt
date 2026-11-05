// The socket transport, driven the way a client drives it: a real listener, a real
// connection, and messages that leave this process and come back.

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
    g.spawn_bg(() => listener.serve(port=14711))
    @async.sleep(100)
    let channel = SocketChannel::connect("127.0.0.1", 14711)
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
    g.spawn_bg(() => listener.serve(port=14712))
    @async.sleep(100)
    let channel = SocketChannel::connect("127.0.0.1", 14712)
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
    g.spawn_bg(() => listener.serve(port=14713))
    @async.sleep(100)
    let channel = SocketChannel::connect("127.0.0.1", 14713)
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
    g.spawn_bg(() => listener.serve(port=14714))
    @async.sleep(100)
    let channel = SocketChannel::connect("127.0.0.1", 14714)
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
