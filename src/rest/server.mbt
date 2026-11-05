// The assembled service: config, application, middleware chain, and the knobs
// that are set on the server rather than on a route.

///|
/// A moonzero service: its config plus the assembled application (a moonapi App
/// with any middleware already wrapped around it).
pub struct Server {
  conf : @conf.ServiceConf
  handler : @moonasgi.AsgiApp
  mounted : Array[String]
}

///|
/// Assemble a service from config and a moonapi application.
pub fn Server::new(conf : @conf.ServiceConf, app : @moonapi.App) -> Server {
  { conf, handler: app.to_asgi(), mounted: [], }
}

///|
/// Wrap the current application in another middleware layer (outermost last).
pub fn Server::use_(self : Server, mw : @handler.Middleware) -> Server {
  { conf: self.conf, handler: mw(self.handler), mounted: self.mounted, }
}

///|
/// The assembled `AsgiApp`, ready for a server (mooncat) to run.
pub fn Server::to_asgi(self : Server) -> @moonasgi.AsgiApp {
  self.handler
}

///|
/// A human-readable description of what this service binds to.
pub fn Server::describe(self : Server) -> String {
  self.conf.name +
  " listening on " +
  self.conf.host +
  ":" +
  self.conf.port.to_string()
}

///|
/// Serve `files` under `prefix`. The mount is a layer, so file responses still pass
/// through CORS, tracing and access logging.
pub fn Server::files(
  self : Server,
  prefix : String,
  files : @handler.Files,
) -> Server {
  {
    conf: self.conf,
    handler: @handler.file_server(files, prefix)(self.handler),
    mounted: [..self.mounted, prefix],
  }
}

///|
/// The prefixes this service serves files from.
pub fn Server::mounted(self : Server) -> Array[String] {
  self.mounted
}

///|
/// Replace the reply an unmatched request gets (← `WithNotFoundHandler`). The
/// handler runs inside the application, so the chain around it — tracing, access
/// logging, CORS — has already run.
pub fn not_found(
  app : @moonapi.App,
  handler : (@moonapi.Context) -> @http.Response,
) -> Unit {
  app.add_status_handler(404, handler)
}

///|
/// Replace the reply a request with a known path but an unsupported method gets
/// (← `WithNotAllowedHandler`), normally `405 Method Not Allowed`.
pub fn not_allowed(
  app : @moonapi.App,
  handler : (@moonapi.Context) -> @http.Response,
) -> Unit {
  app.add_status_handler(405, handler)
}
