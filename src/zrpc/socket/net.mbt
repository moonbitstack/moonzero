// zRPC on a socket.
//
// Everything below this file is the same as the in-process transport: the same
// `RpcServer`, the same handlers, the same interceptor chains, the same message
// bytes. What changes is the wire — an HPACK-coded HEADERS block on a real TCP
// connection instead of frames handed to an engine living in this process — and
// that the call becomes something to wait for.

///|
/// A server's methods, bound to a gRPC server but not yet listening.
///
/// Holding the handle separate from the blocking `serve` is what gives a process a
/// way to stop: `stop` is a graceful drain, so a test can start a listener, call it,
/// and shut it down without cancelling a task that is parked in `accept`.
pub struct Listener {
  grpc : @net.GrpcServer
}

///|
/// A listener for `server`'s methods.
///
/// Every registered method is registered with the gRPC server under its own path,
/// and each one dispatches through `RpcServer::invoke` — so a call arriving on the
/// socket passes the same interceptor chain a call made in process does, including
/// authentication, shedding and the deadline.
pub fn Listener::new(server : @zrpc.RpcServer) -> Listener {
  let grpc = @net.GrpcServer::new()
  for path in server.methods() {
    grpc.register_unary(path, (ctx, request) => {
      match server.invoke({ path, request, parent: None, }) {
        Ok(reply) => reply
        Err(status) => {
          // A failure leaves the chain as a status; on the wire that is the
          // `grpc-status` trailer, with no message behind it.
          ctx.fail(@zrpc.status_code(status), @zrpc.status_name(status))
          b""
        }
      }
    })
  }
  { grpc, }
}

///|
/// Listen on `host:port` and serve until `stop` drains the listener or the running
/// task is cancelled.
pub async fn Listener::serve(
  self : Listener,
  host~ : String = "127.0.0.1",
  port~ : Int32 = 12001,
) -> Unit {
  self.grpc.serve(host~, port~)
}

///|
/// Stop accepting, let the calls already running finish, and tell every client which
/// streams were accepted so it can reconnect elsewhere. `grace` is how long a quiet
/// client is waited on before the connection is given up.
pub async fn Listener::stop(self : Listener, grace~ : Int32 = 10_000) -> Unit {
  self.grpc.graceful_stop(grace~)
}

///|
/// Serve `server` on `host:port` for as long as the running task lives. A process
/// that wants to shut down on its own terms builds a `Listener` instead and calls
/// `stop`.
pub async fn serve(
  server : @zrpc.RpcServer,
  host~ : String = "127.0.0.1",
  port~ : Int32 = 12001,
) -> Unit {
  Listener::new(server).serve(host~, port~)
}

///|
/// A channel to a zRPC server over a socket.
///
/// The connection is opened once and multiplexed: calls are separate HTTP/2
/// streams, so they do not queue behind each other, and the HPACK state is the
/// channel's for its whole life.
pub struct SocketChannel {
  inner : @net.Channel
}

///|
/// Open a channel to `host:port`. The connection is a real one: the preface and the
/// client SETTINGS go out here, and the server's SETTINGS are read on the first
/// call.
pub async fn SocketChannel::connect(
  host : String,
  port : Int32,
) -> SocketChannel {
  { inner: @net.Channel::connect(host, port), }
}

///|
/// Invoke a unary method at `path` with `request` as its message payload.
///
/// `request` and the returned reply are bare message bytes: the five-octet gRPC
/// length prefix is applied and stripped by the transport, so a handler and a
/// caller on either side of this call see the same bytes they would in process.
pub async fn SocketChannel::call(
  self : SocketChannel,
  path : String,
  request : Bytes,
  deadline_ms? : Int32,
) -> Result[Bytes, @moonrpc.Status] {
  let reply = self.inner.unary(path, request, timeout_millis?=deadline_ms)
  match @zrpc.status_of_code(reply.grpc_status) {
    Ok => Ok(if reply.messages.length() > 0 { reply.messages[0] } else { b"" })
    other => Err(other)
  }
}

///|
/// Send one call and report what the peer said about it, status and message both.
/// A caller that wants to log why a call failed reads the message here rather than
/// reconstructing it from the status code.
pub async fn SocketChannel::call_detailed(
  self : SocketChannel,
  path : String,
  request : Bytes,
  deadline_ms? : Int32,
) -> (Result[Bytes, @moonrpc.Status], String) {
  let reply = self.inner.unary(path, request, timeout_millis?=deadline_ms)
  let outcome = match @zrpc.status_of_code(reply.grpc_status) {
    Ok => Ok(if reply.messages.length() > 0 { reply.messages[0] } else { b"" })
    other => Err(other)
  }
  (outcome, reply.grpc_message)
}

///|
/// Close the connection. A call already in flight on another stream is not
/// cancelled by this; the peer sees a GOAWAY and finishes what it started.
pub fn SocketChannel::close(self : SocketChannel) -> Unit {
  self.inner.close()
}
