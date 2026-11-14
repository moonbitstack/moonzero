///|
/// A structured access-log record (← go-zero's `logx` HTTP access fields). Rather
/// than a free-form line, each request is captured as typed fields and rendered
/// as one JSON object per line — the format a log collector (ELK, Loki) expects.
pub(all) struct RequestLog {
  http_method : String
  path : String
  status : Int32
  duration_ms : Int64
  request_id : String
  client_ip : String
  user_agent : String
}

///|
/// The record as a JSON object with a stable field order, `duration_ms` a number
/// of milliseconds.
pub impl ToJson for RequestLog with fn to_json(self) {
  Json::object(
    Map([
      ("method", Json::string(self.http_method)),
      ("path", Json::string(self.path)),
      ("status", Json::number(self.status.to_double())),
      ("duration_ms", Json::number(self.duration_ms.to_double())),
      ("request_id", Json::string(self.request_id)),
      ("client_ip", Json::string(self.client_ip)),
      ("user_agent", Json::string(self.user_agent)),
    ]),
  )
}

///|
pub extend RequestLog with ToJson::{to_json}

///|
/// Read a record back from the JSON `to_json` writes. Every field is required;
/// a log line is written by this library, so a missing one means the document was
/// not one of ours.
pub impl FromJson for RequestLog with fn from_json(json, path) {
  let object = match json {
    Object(fields) => fields
    _ => raise @json.JsonDecodeError((path, "access log must be a JSON object"))
  }
  let text = fn(key : String) -> String raise @json.JsonDecodeError {
    match object.get(key) {
      Some(String(value)) => value
      Some(_) => raise @json.JsonDecodeError((path, key + " must be a string"))
      None => raise @json.JsonDecodeError((path, key + " is missing"))
    }
  }
  let number = fn(key : String) -> Double raise @json.JsonDecodeError {
    match object.get(key) {
      Some(Number(value, ..)) => value
      Some(_) => raise @json.JsonDecodeError((path, key + " must be a number"))
      None => raise @json.JsonDecodeError((path, key + " is missing"))
    }
  }
  {
    http_method: text("method"),
    path: text("path"),
    status: number("status").to_int(),
    duration_ms: number("duration_ms").to_int64(),
    request_id: text("request_id"),
    client_ip: text("client_ip"),
    user_agent: text("user_agent"),
  }
}

///|
pub extend RequestLog with FromJson::{from_json}

///|
/// The record rendered as a single-line JSON string, ready to write to a log
/// sink.
pub fn RequestLog::render(self : RequestLog) -> String {
  @moonjson.dumps(self.to_json())
}

///|
/// The record as `logx` fields, for logging it through a `@logx.Logger` — the
/// method and path make the entry's message, so they are not repeated here.
pub fn RequestLog::fields(self : RequestLog) -> Array[(String, Json)] {
  [
    ("status", Json::number(self.status.to_double())),
    ("duration_ms", Json::number(self.duration_ms.to_double())),
    ("request_id", Json::string(self.request_id)),
    ("client_ip", Json::string(self.client_ip)),
    ("user_agent", Json::string(self.user_agent)),
  ]
}

///|
/// The client IP from an HTTP scope: the `X-Forwarded-For` first hop if present
/// (proxy-aware), else the transport peer from the scope's `client`, else `"-"`.
fn client_ip_of(scope : @moonasgi.Scope) -> String {
  match scope {
    Http(hs) => {
      for pair in hs.headers {
        if pair.0.to_lower() == "x-forwarded-for" {
          let raw = pair.1
          let mut end = 0
          while end < raw.length() && raw[end] != ',' {
            end = end + 1
          }
          return raw[0:end].to_owned()
        }
      }
      match hs.client {
        Some((ip, _)) => ip
        None => "-"
      }
    }
    _ => "-"
  }
}

///|
/// A request header's value from an HTTP scope, matched case-insensitively;
/// `default` when absent or on a non-HTTP scope.
fn header_ci(
  scope : @moonasgi.Scope,
  name : String,
  default : String,
) -> String {
  match scope {
    Http(hs) => {
      for pair in hs.headers {
        if pair.0.to_lower() == name {
          return pair.1
        }
      }
      default
    }
    _ => default
  }
}

///|
/// A header list as a JSON object, so a verbose log line carries the whole
/// exchange and not just the fields the record names.
pub fn headers_json(headers : Array[(String, String)]) -> Json {
  Json::object(Map(headers.map(pair => (pair.0, Json::string(pair.1)))))
}

///|
/// Structured-logging middleware: time each HTTP request on the shared clock,
/// capture its method/path/client-ip/user-agent and the response status observed
/// on `HttpResponseStart`, and write one access entry through `logger` (the
/// process `logx` by default) when the response starts. Access logs are `info`, so
/// a service configured at `error` or above emits none of them.
///
/// `verbose` adds both header sets and a preview of the request body to the entry —
/// what a debugging deployment switches on and an ordinary one leaves off. The
/// preview is the first `verbose_body_preview` bytes: go-zero dumps the whole body,
/// which for a service that accepts uploads means a log line the size of the
/// upload. Non-HTTP scopes pass through without logging.
pub fn structured_logging(
  clock : @clock.Clock,
  logger? : @logx.Logger,
  verbose~ : Bool = false,
) -> Middleware {
  let lg = logger.unwrap_or(@logx.logx)
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(hs) => {
          // A verbose entry describes the body, so the body has to be read before
          // the application runs; the application is then handed the same bytes it
          // would have read itself.
          let body = if verbose { read_body(receive) } else { b"" }
          let start = clock.now()
          let verb = hs.http_method
          let path = hs.path
          let ip = client_ip_of(scope)
          let ua = header_ci(scope, "user-agent", "-")
          let rid = header_ci(scope, "x-request-id", "-")
          let request_headers = headers_json(hs.headers)
          let logged : Ref[Bool] = { val: false, }
          let observed : @moonasgi.Send = event => {
            match event {
              HttpResponseStart(status~, headers~, trailers~) => {
                if !logged.val {
                  logged.val = true
                  let entry = RequestLog::{
                    http_method: verb,
                    path,
                    status,
                    duration_ms: clock.now() - start,
                    request_id: rid,
                    client_ip: ip,
                    user_agent: ua,
                  }
                  let fields = entry.fields()
                  if verbose {
                    fields.push(("request_headers", request_headers))
                    fields.push(("response_headers", headers_json(headers)))
                    fields.push(
                      ("request_body", Json::string(body_preview(body))),
                    )
                  }
                  lg
                  .with_duration(entry.duration_ms)
                  .info(verb + " " + path, fields~)
                }
                send(
                  @moonasgi.Event::HttpResponseStart(
                    status~,
                    headers~,
                    trailers~,
                  ),
                )
              }
              other => send(other)
            }
          }
          if verbose {
            inner(scope, buffered_body(body), observed)
          } else {
            inner(scope, receive, observed)
          }
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}

///|
/// How much of a request body a verbose access entry carries. Named because it is a
/// policy, not an arithmetic detail: enough to recognise a payload, short of a log
/// line the size of an upload.
pub let verbose_body_preview : Int32 = 1024

///|
/// The first `verbose_body_preview` bytes of `body` as text, or a count when the
/// bytes are not UTF-8. A truncated body is marked so a reader does not mistake it
/// for the whole one.
fn body_preview(body : Bytes) -> String {
  if body.length() == 0 {
    return ""
  }
  let shown = if body.length() > verbose_body_preview {
    body[:verbose_body_preview]
  } else {
    body[:]
  }
  let text = @utf8.decode(shown) catch {
    _ => return "<" + body.length().to_string() + " bytes, not text>"
  }
  if body.length() > verbose_body_preview {
    text + "…"
  } else {
    text
  }
}
