///|
/// A moonzero service: its config plus the assembled application (a moonapi App
/// with any middleware already wrapped around it).
pub struct Server {
  conf : @conf.ServiceConf
  handler : @moonasgi.AsgiApp
}

///|
/// Assemble a service from config and a moonapi application.
pub fn Server::new(conf : @conf.ServiceConf, app : @moonapi.App) -> Server {
  { conf, handler: app.to_asgi(), }
}

///|
/// Wrap the current application in another middleware layer (outermost last).
pub fn Server::use_(self : Server, mw : @handler.Middleware) -> Server {
  { conf: self.conf, handler: mw(self.handler), }
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
