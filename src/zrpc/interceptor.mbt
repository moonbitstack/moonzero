// The interceptor chain both halves of zRPC run calls through.
//
// One shape serves the client and the server: an invoker turns a call into a
// result, and an interceptor wraps an invoker. On the client the innermost invoker
// is the transport; on the server it is the registered handler. That is the same
// split the reference implementation gets from `grpc.ChainUnaryInterceptor`, with
// the transport detail removed.

///|
/// One unary call: its gRPC path (`/package.Service/Method`) and the request
/// message's wire bytes.
pub(all) struct Call {
  path : String
  request : Bytes
  /// The trace context this call runs under, when the caller has one. A client
  /// interceptor opens its span as a child of it and hands the result down, so a
  /// chain of calls is one trace.
  parent : @trace.TraceContext?
}

///|
/// The value the name of the method is not: `method` is reserved in MoonBit, and
/// the path already carries the service and the name.
pub fn Call::name(self : Call) -> String {
  let parts = self.path.split("/").collect()
  match parts.length() {
    0 => self.path
    n => parts[n - 1].to_owned()
  }
}

///|
/// The innermost of a chain: makes the call.
pub type Invoker = (Call) -> Result[Bytes, @moonrpc.Status] raise

///|
/// One layer around an invoker.
pub type Interceptor = (Invoker) -> Invoker

///|
/// Fold `interceptors` around `base`, first in the array outermost — the order
/// `ChainUnaryInterceptor` gives them.
pub fn chain(interceptors : Array[Interceptor], base : Invoker) -> Invoker {
  let mut invoker = base
  for i = interceptors.length() - 1; i >= 0; i = i - 1 {
    invoker = interceptors[i](invoker)
  }
  invoker
}

///|
/// The `grpc-status` an error becomes when a layer cannot say anything better. The
/// transport's own failures are internal: the caller asked for a method, not for a
/// protocol exchange.
pub fn internal_status() -> @moonrpc.Status {
  @moonrpc.Status::Internal
}
