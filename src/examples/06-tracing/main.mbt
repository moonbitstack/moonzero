// Copyright 2026 Leo Cheng
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// Send one request through a tracing layer and read back what it did: a request
/// with no inbound context starts a trace, one that arrives with a `traceparent`
/// joins it and opens a child span, and either way the response carries the
/// context on so the next hop continues the same trace.
///
///     moon run --target native src/examples/06-tracing
#coverage.skip
async fn main {
  let recorder = @moontel.Recorder::new()
  let tracer = @moonzero.tracer(sink=recorder)
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let conf = @moonzero.ServiceConf::new(name="traced", port=8888)
  let server = @moonzero.Server::new(conf, app).use_(@moonzero.tracing(tracer~))
  let handler = server.to_asgi()

  println("--- no inbound traceparent ---")
  show(handler, [])
  println("--- continuing an inbound trace ---")
  show(handler, [
    ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
  ])

  let spans = recorder.spans()
  println("\{spans.length()} spans recorded")
  for span in spans {
    println(
      span.name +
      "  sampled=" +
      span.sampled().to_string() +
      "  span_id=" +
      @base16.encode(span.context.span_id[:]),
    )
  }
}

///|
/// Drive one request through the assembled app and print the propagation headers
/// it answered with.
async fn show(
  handler : @moonasgi.AsgiApp,
  headers : Array[(String, String)],
) -> Unit {
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method="GET", path="/ping", headers~),
  )
  let sent : Ref[Bool] = { val: false, }
  let receive : @moonasgi.Receive = () => {
    if sent.val {
      @moonasgi.Event::HttpDisconnect
    } else {
      sent.val = true
      @moonasgi.Event::HttpRequest(body=b"", more_body=false)
    }
  }
  handler(scope, receive, event => {
    match event {
      HttpResponseStart(status~, headers~, ..) => {
        println("status \{status}")
        for pair in headers {
          if pair.0 == "traceparent" || pair.0 == "x-trace-id" {
            println("  " + pair.0 + ": " + pair.1)
          }
        }
      }
      _ => ()
    }
  })
}
