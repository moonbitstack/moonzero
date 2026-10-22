///|
test "rpc server registers and dispatches a method by gRPC path" {
  let server = RpcServer::new(
    @conf.RpcServerConf::new(name="greeter", port=9090),
  )
  let desc : @moonrpc.Method = { service: "hello.Greeter", name: "SayHello", }
  server.register(desc, req => {
    // echo handler: prepend a byte so we can prove the handler actually ran
    let buf = Buffer()
    buf.write_byte(b'\x2a')
    buf.write_bytes(req[:])
    buf.to_bytes()
  })
  assert_eq(desc.path(), "/hello.Greeter/SayHello")
  assert_eq(server.has_method("/hello.Greeter/SayHello"), true)
  assert_eq(server.methods().length(), 1)
  // dispatch runs the handler and returns its bytes
  match server.dispatch("/hello.Greeter/SayHello", b"hi") {
    Ok(resp) => {
      assert_eq(resp[0].to_int(), 0x2a)
      assert_eq(resp.length(), 3)
    }
    Err(_) => fail("expected the handler to run")
  }
}

///|
test "rpc dispatch on an unknown method returns Unimplemented" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  match server.dispatch("/no.Such/Method", b"") {
    Ok(_) => fail("unknown method should not dispatch")
    Err(status) => assert_eq(status == @moonrpc.Status::Unimplemented, true)
  }
  assert_eq(server.has_method("/no.Such/Method"), false)
  assert_eq(server.lookup("/no.Such/Method") is None, true)
}

///|
test "rpc group registers methods under one service name" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  let g = server.group("order.OrderService")
  assert_eq(g.service(), "order.OrderService")
  g.register("Create", _req => b"created")
  g.register("Cancel", _req => b"cancelled")
  assert_eq(server.has_method("/order.OrderService/Create"), true)
  assert_eq(server.has_method("/order.OrderService/Cancel"), true)
  assert_eq(server.methods().length(), 2)
  match server.dispatch("/order.OrderService/Create", b"") {
    Ok(resp) => assert_eq(resp, b"created")
    Err(_) => fail("Create should dispatch")
  }
}

///|
/// The graceful dispatch gate serves normally before shutdown and refuses with
/// `Unavailable` after, while an unknown method still maps to `Unimplemented`.
test "dispatch_graceful serves, then refuses with Unavailable after shutdown" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server.group("greet.Greeter").register("Hello", req => dcat(b"hi:", req))
  let coord = @proc.ShutdownCoordinator::new()
  match server.dispatch_graceful(coord, "/greet.Greeter/Hello", b"leo") {
    Ok(reply) => assert_eq(reply, b"hi:leo")
    Err(s) => fail("expected OK, got " + s.name())
  }
  // unknown method still reports Unimplemented while serving.
  match server.dispatch_graceful(coord, "/greet.Greeter/Missing", b"") {
    Ok(_) => fail("unknown method should not be OK")
    Err(s) => assert_eq(s == @moonrpc.Status::Unimplemented, true)
  }
  assert_eq(coord.in_flight(), 0)
  coord.initiate_shutdown()
  match server.dispatch_graceful(coord, "/greet.Greeter/Hello", b"leo") {
    Ok(_) => fail("a shutting-down server must refuse new calls")
    Err(s) => assert_eq(s == @moonrpc.Status::Unavailable, true)
  }
}
