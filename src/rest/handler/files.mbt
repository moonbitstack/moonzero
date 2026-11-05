// Serving static files from the routes under a prefix.
//
// The bytes live in a `Files` value rather than in the file system, so the layer
// is pure: a test serves a file it built in memory, a deployment loads a
// directory once at start-up, and neither path needs a second implementation.

///|
/// One servable file: its bytes and the media type it is announced with. The
/// `ETag` is derived from the content, so a conditional request works without the
/// loader having to know a modification time.
pub(all) struct FileEntry {
  body : Bytes
  media_type : String
}

///|
/// The files a service serves, keyed by path relative to the mount prefix.
pub(all) struct Files {
  entries : Map[String, FileEntry]
}

///|
/// An empty set of files.
pub fn Files::new() -> Files {
  { entries: Map([]), }
}

///|
/// Add `body` under `path` (`/logo.svg`, say). The media type is guessed from the
/// extension unless one is given.
pub fn Files::add(
  self : Files,
  path : String,
  body : Bytes,
  media_type? : String,
) -> Unit {
  let media_type = match media_type {
    Some(media_type) => media_type
    None => media_type_of(path)
  }
  self.entries[normalise(path)] = { body, media_type, }
}

///|
/// The file registered under `path`, or `None`.
pub fn Files::get(self : Files, path : String) -> FileEntry? {
  self.entries.get(normalise(path))
}

///|
/// The paths in this set, sorted, so a listing or a test is stable.
pub fn Files::paths(self : Files) -> Array[String] {
  let paths = self.entries.keys().collect()
  paths.sort()
  paths
}

///|
/// A path as the map keys it: one leading slash, no trailing slash.
fn normalise(path : String) -> String {
  let mut start = 0
  while start < path.length() && path[start] == '/' {
    start = start + 1
  }
  let mut end = path.length()
  while end > start && path[end - 1] == '/' {
    end = end - 1
  }
  "/" + path[start:end].to_owned()
}

///|
/// The media type for a path, from its extension. The table covers the types a
/// static bundle actually carries; anything else is served as
/// `application/octet-stream`, which every client downloads rather than guesses.
pub fn media_type_of(path : String) -> String {
  let lower = path.to_lower()
  for pair in media_types {
    if lower.has_suffix("." + pair.0) {
      return pair.1
    }
  }
  "application/octet-stream"
}

///|
/// The extension-to-media-type table, longest extension first so `.jsonld` wins
/// over `.json`.
let media_types : Array[(String, String)] = [
  ("jsonld", "application/ld+json"),
  ("woff2", "font/woff2"),
  ("woff", "font/woff"),
  ("html", "text/html; charset=utf-8"),
  ("css", "text/css; charset=utf-8"),
  ("json", "application/json"),
  ("mjs", "text/javascript; charset=utf-8"),
  ("js", "text/javascript; charset=utf-8"),
  ("svg", "image/svg+xml"),
  ("png", "image/png"),
  ("jpg", "image/jpeg"),
  ("jpeg", "image/jpeg"),
  ("webp", "image/webp"),
  ("avif", "image/avif"),
  ("ico", "image/x-icon"),
  ("txt", "text/plain; charset=utf-8"),
  ("xml", "application/xml"),
  ("pdf", "application/pdf"),
  ("wasm", "application/wasm"),
  ("map", "application/json"),
  ("ttf", "font/ttf"),
  ("otf", "font/otf"),
  ("mp4", "video/mp4"),
  ("webm", "video/webm"),
]

///|
/// The `ETag` of a file: a quoted, strong validator derived from the length and a
/// CRC-32 of the bytes, so two builds that produce the same content serve the same
/// tag.
pub fn FileEntry::etag(self : FileEntry) -> String {
  "\"" +
  self.body.length().to_string() +
  "-" +
  @moonzip.crc32(self.body[:]).to_string() +
  "\""
}

///|
/// Whether a request's `If-None-Match` names this file's tag.
fn matches_etag(scope : @moonasgi.Scope, tag : String) -> Bool {
  match scope_header(scope, "if-none-match") {
    Some(value) => value == tag || value == "*"
    None => false
  }
}

///|
/// The file-serving layer: a `GET` under `prefix` whose remaining path names a
/// registered file is answered with it, and every other request reaches the
/// application. A conditional request whose `If-None-Match` names the file's tag
/// is answered `304` without the body.
///
/// This is a middleware rather than a route so it composes with the assembled
/// chain exactly as the reference implementation's does: the file response still
/// carries the CORS, trace and access-log layers.
pub fn file_server(files : Files, prefix : String) -> Middleware {
  let mount = normalise(prefix)
  inner => {
    (scope, receive, send) => {
      let served = match scope {
        Http(hs) =>
          if hs.http_method == "GET" || hs.http_method == "HEAD" {
            serve_file(files, mount, scope, hs.path, hs.http_method, send)
          } else {
            false
          }
        _ => false
      }
      if served {
        // the response has already gone out
        ()
      } else {
        inner(scope, receive, send)
      }
    }
  }
}

///|
/// Answer one request from `files`; `true` when it was served. `HEAD` gets the
/// headers and no body, as a HEAD response must.
async fn serve_file(
  files : Files,
  mount : String,
  scope : @moonasgi.Scope,
  path : String,
  verb : String,
  send : @moonasgi.Send,
) -> Bool {
  let relative = if path.has_prefix(mount) {
    path.exact_view(start=mount.length()).to_owned()
  } else {
    return false
  }
  let entry = match files.get(relative) {
    Some(entry) => entry
    None => return false
  }
  let tag = entry.etag()
  let headers = [("content-type", entry.media_type), ("etag", tag)]
  if matches_etag(scope, tag) {
    send(
      @moonasgi.Event::HttpResponseStart(status=304, headers~, trailers=false),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"", more_body=false))
    return true
  }
  send(
    @moonasgi.Event::HttpResponseStart(
      status=200,
      headers=[("content-length", entry.body.length().to_string()), ..headers],
      trailers=false,
    ),
  )
  let body = if verb == "HEAD" { b"" } else { entry.body }
  send(@moonasgi.Event::HttpResponseBody(body~, more_body=false))
  true
}
