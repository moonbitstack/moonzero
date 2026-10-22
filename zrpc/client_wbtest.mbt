///|
/// Concatenate two byte strings (test helper).
fn bcat(a : Bytes, b : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(a)
  buf.write_bytes(b)
  buf.to_bytes()
}

///|
/// A real bidirectional zRPC round-trip over the moonrpc h2c transport, driven one
/// message at a time so the interleaving is observable: each `send` gets back
/// exactly the echo for the message just sent (not a batch at the end), and
/// `close_send` runs the server's `on_end` and returns its farewell. This is only
/// possible if request and reply frames truly flow both ways on the open stream.
test "zrpc bidi call interleaves a reply per message, then a farewell on close" {
  let server = RpcServer::new(@conf.RpcServerConf::new(name="chat", port=9201))
  server
  .group("chat.Chat")
  .register_bidi_streaming("Echo", () => BidiStreamHandler::{
    on_message: m => [dcat(b"re:", m)],
    on_end: () => [b"bye"],
  })
  let ch = RpcChannel::connect(server)
  let call = ch.open_bidi("/chat.Chat/Echo")
  let first = call.send(b"one")
  assert_eq(first.length(), 1)
  assert_eq(first[0], b"re:one")
  let second = call.send(b"two")
  assert_eq(second.length(), 1)
  assert_eq(second[0], b"re:two")
  match call.close_send() {
    Ok(final_msgs) => {
      assert_eq(final_msgs.length(), 1)
      assert_eq(final_msgs[0], b"bye")
    }
    Err(s) => fail("expected OK, got " + s.name())
  }
}

///|
/// The one-shot convenience drives the whole exchange and returns every reply in
/// emission order: an echo per request followed by the `on_end` farewell.
test "zrpc call_bidi_streaming returns the interleaved replies then the terminator" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server
  .group("chat.Chat")
  .register_bidi_streaming("Echo", () => BidiStreamHandler::{
    on_message: m => [dcat(b"re:", m)],
    on_end: () => [b"bye"],
  })
  let ch = RpcChannel::connect(server)
  match ch.call_bidi_streaming("/chat.Chat/Echo", [b"one", b"two", b"three"]) {
    Ok(msgs) => {
      assert_eq(msgs.length(), 4)
      assert_eq(msgs[0], b"re:one")
      assert_eq(msgs[1], b"re:two")
      assert_eq(msgs[2], b"re:three")
      assert_eq(msgs[3], b"bye")
    }
    Err(s) => fail("expected OK, got " + s.name())
  }
}

///|
/// A bidi handler that buffers every message and only replies at half-close (a
/// reduce-over-the-stream shape): each `send` returns no messages, and `close_send`
/// returns the single aggregate. Distinguishes the `on_end` terminator from the
/// per-message path — if `on_end` were dropped the call would yield nothing.
test "zrpc bidi handler may defer all replies to on_end" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server
  .group("agg.Agg")
  .register_bidi_streaming("Reduce", () => {
    let parts : Array[Bytes] = []
    BidiStreamHandler::{
      on_message: m => {
        parts.push(m)
        []
      },
      on_end: () => {
        let buf = Buffer()
        for p in parts {
          buf.write_bytes(p)
        }
        [buf.to_bytes()]
      },
    }
  })
  let ch = RpcChannel::connect(server)
  let call = ch.open_bidi("/agg.Agg/Reduce")
  assert_eq(call.send(b"a").length(), 0)
  assert_eq(call.send(b"b").length(), 0)
  assert_eq(call.send(b"c").length(), 0)
  match call.close_send() {
    Ok(final_msgs) => {
      assert_eq(final_msgs.length(), 1)
      assert_eq(final_msgs[0], b"abc")
    }
    Err(_) => fail("aggregate should be OK")
  }
}

///|
/// A bidi handler may emit several replies for one request; every one arrives on
/// that `send`.
test "zrpc bidi handler may fan one message out into several replies" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server
  .group("fan.Fan")
  .register_bidi_streaming("Out", () => BidiStreamHandler::{
    on_message: m => [dcat(m, b"-1"), dcat(m, b"-2")],
    on_end: () => [],
  })
  let ch = RpcChannel::connect(server)
  let call = ch.open_bidi("/fan.Fan/Out")
  let out = call.send(b"x")
  assert_eq(out.length(), 2)
  assert_eq(out[0], b"x-1")
  assert_eq(out[1], b"x-2")
  match call.close_send() {
    Ok(final_msgs) => assert_eq(final_msgs.length(), 0)
    Err(_) => fail("no on_end replies is still OK")
  }
}

///|
/// A bidi call to an unregistered path comes back UNIMPLEMENTED — the trailers-only
/// status the engine answers during the request HEADERS, captured by `open_bidi`
/// before any message is sent.
test "zrpc bidi call to an unknown method returns Unimplemented" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server
  .group("chat.Chat")
  .register_bidi_streaming("Echo", () => BidiStreamHandler::{
    on_message: m => [m],
    on_end: () => [],
  })
  let ch = RpcChannel::connect(server)
  match ch.call_bidi_streaming("/chat.Chat/Missing", [b"hi"]) {
    Ok(_) => fail("unknown method should not return OK")
    Err(s) => assert_eq(s == @moonrpc.Status::Unimplemented, true)
  }
}

///|
/// Calling `close_send` twice is refused with `Cancelled`; the stream is already
/// half-closed.
test "zrpc bidi close_send is idempotent-guarded" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server
  .group("chat.Chat")
  .register_bidi_streaming("Echo", () => BidiStreamHandler::{
    on_message: m => [m],
    on_end: () => [b"bye"],
  })
  let ch = RpcChannel::connect(server)
  let call = ch.open_bidi("/chat.Chat/Echo")
  let _ = call.send(b"one")
  let _ = call.close_send()
  match call.close_send() {
    Ok(_) => fail("second close_send must not succeed")
    Err(s) => assert_eq(s == @moonrpc.Status::Cancelled, true)
  }
}

///|
/// A real server-streaming zRPC round-trip over the moonrpc h2c transport: the
/// server registers a server-streaming handler that fans one request out into three
/// framed reply messages, and the channel reads all three back off the response
/// DATA frames, closed by `grpc-status: 0`. Each reply embeds the request bytes, so
/// the sequence can only be right if the request actually reached the handler and
/// every message survived the length-prefix framing.
test "zrpc server-streaming call returns every framed message in order" {
  let server = RpcServer::new(@conf.RpcServerConf::new(name="feed", port=9101))
  server
  .group("feed.Feed")
  .register_server_streaming("Tail", req => {
    [bcat(req, b"#1"), bcat(req, b"#2"), bcat(req, b"#3")]
  })
  let ch = RpcChannel::connect(server)
  match ch.call_server_streaming("/feed.Feed/Tail", b"log") {
    Ok(msgs) => {
      assert_eq(msgs.length(), 3)
      assert_eq(msgs[0], b"log#1")
      assert_eq(msgs[1], b"log#2")
      assert_eq(msgs[2], b"log#3")
    }
    Err(s) => fail("expected OK, got " + s.name())
  }
}

///|
/// A server-streaming method may legitimately produce zero messages; the call still
/// completes on `grpc-status: 0` with an empty sequence.
test "zrpc server-streaming call with no messages completes OK" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server.group("feed.Feed").register_server_streaming("Empty", _req => [])
  let ch = RpcChannel::connect(server)
  match ch.call_server_streaming("/feed.Feed/Empty", b"x") {
    Ok(msgs) => assert_eq(msgs.length(), 0)
    Err(_) => fail("empty stream should be OK")
  }
}

///|
/// A real client-streaming zRPC round-trip: the channel sends three request
/// messages as their own DATA frames, half-closes, and the handler — which sees the
/// whole collected sequence at once — returns a single reply built from all of
/// them. The reply encodes the count and the concatenation, so it is only right if
/// every message arrived, in order.
test "zrpc client-streaming call collects every request message" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server
  .group("upload.Upload")
  .register_client_streaming("Send", msgs => {
    let buf = Buffer()
    buf.write_byte((msgs.length() + 0x30).to_byte())
    buf.write_byte(b':')
    for m in msgs {
      buf.write_bytes(m)
    }
    buf.to_bytes()
  })
  let ch = RpcChannel::connect(server)
  match ch.call_client_streaming("/upload.Upload/Send", [b"a", b"bb", b"ccc"]) {
    Ok(reply) => assert_eq(reply, b"3:abbccc")
    Err(s) => fail("expected OK, got " + s.name())
  }
}

///|
/// A client-streaming call with no messages still runs the handler once with an
/// empty sequence.
test "zrpc client-streaming call with no messages runs the handler empty" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server
  .group("upload.Upload")
  .register_client_streaming("Count", msgs => {
    if msgs.length() == 0 {
      b"none"
    } else {
      b"some"
    }
  })
  let ch = RpcChannel::connect(server)
  match ch.call_client_streaming("/upload.Upload/Count", []) {
    Ok(reply) => assert_eq(reply, b"none")
    Err(_) => fail("empty client stream should be OK")
  }
}

///|
/// A server-streaming call to an unregistered path comes back UNIMPLEMENTED, the
/// same trailers-only error the unary path reports for an unknown method.
test "zrpc server-streaming call to an unknown method returns Unimplemented" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server.group("feed.Feed").register_server_streaming("Tail", _req => [b"x"])
  let ch = RpcChannel::connect(server)
  match ch.call_server_streaming("/feed.Feed/Missing", b"") {
    Ok(_) => fail("unknown method should not return OK")
    Err(s) => assert_eq(s == @moonrpc.Status::Unimplemented, true)
  }
}

///|
/// A real unary zRPC round-trip over the moonrpc h2c transport: the server
/// registers a handler through a group, an in-process channel encodes a request
/// as HPACK HEADERS + length-prefixed DATA, the H2Server engine dispatches it, and
/// the channel reads the reply back off the response frames and `grpc-status: 0`
/// trailer. The handler concatenates a marker so the reply can only be right if
/// the request bytes actually reached it.
test "zrpc unary call goes through the h2c transport" {
  let server = RpcServer::new(
    @conf.RpcServerConf::new(name="greeter", port=9090),
  )
  server
  .group("hello.Greeter")
  .register("SayHello", req => {
    let buf = Buffer()
    buf.write_bytes(b"hello, ")
    buf.write_bytes(req[:])
    buf.to_bytes()
  })
  let ch = RpcChannel::connect(server)
  match ch.call("/hello.Greeter/SayHello", b"world") {
    Ok(reply) => assert_eq(reply, b"hello, world")
    Err(s) => fail("expected OK, got " + s.name())
  }
}

///|
/// Distinct message payloads round-trip intact, and a second call on the same
/// channel still decodes — proving the HPACK dynamic table stays in sync across
/// calls rather than only working on the first.
test "zrpc channel carries multiple sequential calls" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server.group("echo.Echo").register("Echo", req => req)
  let ch = RpcChannel::connect(server)
  match ch.call("/echo.Echo/Echo", b"first") {
    Ok(reply) => assert_eq(reply, b"first")
    Err(_) => fail("first call failed")
  }
  match ch.call("/echo.Echo/Echo", b"second-and-longer") {
    Ok(reply) => assert_eq(reply, b"second-and-longer")
    Err(_) => fail("second call failed")
  }
  // A binary payload with NUL and high bytes survives the DATA framing.
  match ch.call("/echo.Echo/Echo", b"\x00\xff\x01\xfe") {
    Ok(reply) => assert_eq(reply, b"\x00\xff\x01\xfe")
    Err(_) => fail("binary call failed")
  }
}

///|
/// An empty request and an empty reply are a valid unary exchange.
test "zrpc unary call with empty payloads" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server.group("ping.Ping").register("Ping", _req => b"")
  let ch = RpcChannel::connect(server)
  match ch.call("/ping.Ping/Ping", b"") {
    Ok(reply) => assert_eq(reply.length(), 0)
    Err(_) => fail("ping failed")
  }
}

///|
/// A call to an unregistered path comes back as `UNIMPLEMENTED` over the wire —
/// the trailers-only response a real gRPC server sends for an unknown method.
test "zrpc call to an unknown method returns Unimplemented" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  server.group("hello.Greeter").register("SayHello", req => req)
  let ch = RpcChannel::connect(server)
  match ch.call("/hello.Greeter/DoesNotExist", b"x") {
    Ok(_) => fail("unknown method should not return OK")
    Err(status) => assert_eq(status == @moonrpc.Status::Unimplemented, true)
  }
}

///|
/// The transport dispatches by path: two methods on one service each reach their
/// own handler.
test "zrpc routes each method to its own handler over the transport" {
  let server = RpcServer::new(@conf.RpcServerConf::new())
  let g = server.group("order.OrderService")
  g.register("Create", _req => b"created")
  g.register("Cancel", _req => b"cancelled")
  let ch = RpcChannel::connect(server)
  match ch.call("/order.OrderService/Create", b"") {
    Ok(reply) => assert_eq(reply, b"created")
    Err(_) => fail("Create failed")
  }
  match ch.call("/order.OrderService/Cancel", b"") {
    Ok(reply) => assert_eq(reply, b"cancelled")
    Err(_) => fail("Cancel failed")
  }
}

///|
/// `status_of_code` covers the whole canonical range and rejects out-of-range
/// codes as `Unknown`.
test "status_of_code maps the canonical range" {
  assert_eq(status_of_code(0) == @moonrpc.Status::Ok, true)
  assert_eq(status_of_code(12) == @moonrpc.Status::Unimplemented, true)
  assert_eq(status_of_code(16) == @moonrpc.Status::Unauthenticated, true)
  assert_eq(status_of_code(99) == @moonrpc.Status::Unknown, true)
  assert_eq(status_of_code(-1) == @moonrpc.Status::Unknown, true)
}
