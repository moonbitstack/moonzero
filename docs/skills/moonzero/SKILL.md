---
name: moonzero
description: Microservice framework for MoonBit — assemble a REST service from a config document, wrap it in the middlewares the document asks for, add per-route checks (JWT, signature, deadline, body cap, shedding, SSE), run zRPC client and server interceptor chains, and use the resilience primitives. Use when a MoonBit service needs configuration loading, request middleware, route-level auth, load balancing, rate limiting, circuit breaking, or zRPC.
---

# moonzero

A service is assembled, not written: a config document says which middlewares run,
the engine builds the chain around an application, and the result is an ASGI
application a host runs.

```bash
moon add moonbitstack/moonzero
```

One package per job: `rest` (engine, server, groups, route options), `rest/handler`
(the middlewares), `zrpc` (server, channel, interceptor chains), `balance`,
`conf`, `breaker`, `shedder`, `limit`, `stores/*`, and the utilities `syncx`,
`collection`, `mr`, `fx`, `threading`, `service`. `moonbitstack/moonzero`
re-exports the common surface, so one import reaches most of it.

## Assemble a service

The engine reads `RestConf` and returns a `Server`; `to_asgi` hands the application
to whatever serves it. Middleware flags default to on, so a document that says
nothing about them still gets the whole chain.

```
import {
  "moonbitstack/moonzero",
  "moonbitstack/moonapi",
}
```

```moonbit
fn assemble(conf : @moonzero.RestConf) -> @moonzero.Server raise @moonzero.Refused {
  let app = @moonapi.App::new()
  let api = @moonzero.Group::new(app, "/api/v1")
  api.get("/ping", _ctx => @moonapi.text(200, "pong"))
  @moonzero.RestEngine::new(conf).build(app)
}
```

`RestConf::from_yaml(text)` loads an `etc/*.yaml`; `RestEngine::names()` answers the
layers the document installed, outermost first, which is the fastest way to check a
config before deploying it.

## Checks that belong to a route

A route carries its own options: a JWT with a rotation window, a deadline, a body
cap, a signature verifier, a priority shedder, an event-stream stamp. Each becomes a
check that runs before the handler and refuses with the status the option promises.

```moonbit
fn guarded(api : @moonzero.Group, clock : @moonzero.Clock) -> Unit {
  let checks = @moonzero.RouteOptions::new(clock~)
    .jwt(secret="s3cret", prev_secret="old-secret")
    .timeout(2_000L)
    .max_bytes(64 * 1024)
  api.options_(checks).post("/orders", _ctx => @moonapi.text(201, "created"))
}
```

`prev_secret` is the secret a rotation is retiring: a token signed with it keeps
working while clients pick the new one up, and stops when the window closes. A JWT
route answers `401` with the `WWW-Authenticate` challenge; a body past the cap
answers `413`; a handler past its deadline is abandoned and answered `503`.

## One chain shape on both halves of zRPC

An invoker turns a call into a result, an interceptor wraps an invoker, and the
transport is the innermost invoker. The presets build the chain a config document
asks for: five client layers, eight server layers.

```
import {
  "moonbitstack/moonzero",
  "moonbitstack/moonrpc",
}
```

```moonbit
fn call_with_chain(
  conf : @moonzero.RpcClientMiddlewaresConf,
) -> Result[Bytes, @moonrpc.Status] raise {
  let deps = @moonzero.ClientDeps::new() catch {
    _ => abort("the default client deps must build")
  }
  let transport : @moonzero.Invoker = call => Ok(call.request)
  let call = @moonzero.chain(
    @moonzero.client_interceptors(conf, deps),
    transport,
  )
  call({ path: "/greeter.Greeter/Say", request: b"hi", parent: None })
}
```

The server side is the mirror: `RpcServer::of(conf)` builds the eight layers from
`RpcServerConf`, and `invoke` runs a call through them to the handler registered for
its path. Both sides take their clock, randomness and metrics from the caller, so a
test drives time instead of waiting for it.

## Resilience primitives

Each decision is a pure function of an injected clock, which is what makes it
testable and replayable.

```moonbit
fn guarded_call(
  breaker : @moonzero.Breaker,
  backend : () -> Bytes raise,
) -> Bytes raise {
  breaker.run(() => backend())
}
```

The breaker counts the last ten seconds in forty buckets and sheds a *fraction* of
calls once the failure ratio passes its budget, so a struggling backend keeps the
load it can still serve. `Shedder` refuses only when the machine is both hot and
full. `TokenBucket`, `PeriodLimit` and `MaxConns` live in `limit`, in memory or on
Redis; the Redis token limiter keeps limiting from a local bucket while it cannot
reach the server, and returns to the shared one when a probe finds it again.

## Rules that bite

- **`Refused` is the config error.** Every loader raises it; a document that names
  one TLS file without the other, or a strict signature policy with no keys, is
  refused at load rather than at the first request.
- **Middleware flags default to on.** Turning one off is explicit:
  `MiddlewaresConf::new(breaker=false)`. `RestEngine::names()` tells you what you
  actually got.
- **TLS is the host's.** The certificate pair is carried and validated as a pair, but
  the object built here is an application, not a socket.
- **Metrics and spans come from elsewhere.** Families are moonp8s's, spans moontel's;
  the request counter keeps path, method and code as three labels, not one string.
- **The p2c lag is milliseconds.** The picker's load is the truncated square root of
  the lag times in-flight plus one, and the comparison is what decides between two
  instances; `Balancer::report` is how a finished call moves those numbers.
- **A file set is data, not a directory.** `Files::add` puts bytes in a value and
  `file_server` serves them under a prefix; `rest/files` loads a directory at start-up
  and needs a file system, so it is native only.
