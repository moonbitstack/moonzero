// zRPC over a socket, used as one half of the interoperability check.
//
// The same binary is both ends: `serve` listens, `call` sends one message and
// prints the reply. The check pairs it with a gRPC server and client written
// against the Go implementation, so both directions are covered by running two
// processes rather than by describing them.
//
//     moon run --target native src/examples/15-interop -- serve 12011
//     moon run --target native src/examples/15-interop -- call 12011 hello

///|
/// Where the one method this example serves lives. A gRPC path is
/// `/package.Service/Method`, and the message bytes are opaque to the transport —
/// which is what lets a client and a server built by different libraries meet.
let echo_path : String = "/interop.Echo/Call"

///|
async fn main {
  let args = @env.args()
  let command = args.get(1).unwrap_or("")
  let port_text = args.get(2).unwrap_or("")
  let port = match parse_port(port_text) {
    Some(port) => port
    None => {
      println(
        "usage: 15-interop serve <port> | 15-interop call <port> [message]",
      )
      return
    }
  }
  match command {
    "serve" => {
      let server = @zrpc.RpcServer::new(
        @conf.RpcServerConf::new(name="interop", port~),
      )
      server.group("interop.Echo").register("Call", request => request)
      // Blocks in the accept loop: the process lives as long as the listener does.
      @socket.serve(server, port~)
    }
    "call" => {
      let message = args.get(3).unwrap_or("hello")
      let channel = @socket.SocketChannel::connect("127.0.0.1", port)
      let outcome = channel.call(echo_path, @utf8.encode(message))
      match outcome {
        Ok(reply) => println("reply " + (@utf8.decode(reply) catch { _ => "" }))
        Err(status) => println("status " + @zrpc.status_name(status))
      }
      channel.close()
    }
    _ =>
      println(
        "usage: 15-interop serve <port> | 15-interop call <port> [message]",
      )
  }
}

///|
/// A decimal port, or `None` when the text is not one.
fn parse_port(text : String) -> Int32? {
  guard text.length() > 0 else { return None }
  let mut port = 0
  for i = 0; i < text.length(); i = i + 1 {
    let digit = text[i].to_int() - '0'.to_int()
    guard digit >= 0 && digit <= 9 else { return None }
    port = port * 10 + digit
  }
  guard port > 0 && port < 65536 else { return None }
  Some(port)
}
