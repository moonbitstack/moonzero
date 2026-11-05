///|
/// A route group: registers a set of routes on an underlying `moonapi.App` under
/// a shared path prefix and a shared set of route options, so related endpoints
/// (everything under `/api/v1`, say) are declared without repeating either.
pub struct Group {
  app : @moonapi.App
  prefix : String
  options : RouteOptions
}

///|
/// Open a group that prefixes every route it registers with `prefix` on `app`.
pub fn Group::new(app : @moonapi.App, prefix : String) -> Group {
  { app, prefix, options: RouteOptions::new(), }
}

///|
/// The prefix this group joins onto each registered route.
pub fn Group::prefix(self : Group) -> String {
  self.prefix
}

///|
/// The options every route in this group inherits.
pub fn Group::options(self : Group) -> RouteOptions {
  self.options
}

///|
/// A group that keeps this one's prefix and app with `options` in place of the
/// inherited set. The prefixes still join, so
/// `Group::new(app, "/api").options_(RouteOptions::new().under("/v1"))` serves
/// `/api/v1/...`.
pub fn Group::options_(self : Group, options : RouteOptions) -> Group {
  { app: self.app, prefix: self.prefix, options, }
}

///|
/// A sub-group under `prefix`, inheriting every option.
pub fn Group::sub(self : Group, prefix : String) -> Group {
  {
    app: self.app,
    prefix: join_prefix(self.prefix, prefix),
    options: self.options,
  }
}

///|
/// Register a route for an explicit method under the group's prefix and options.
pub fn Group::route(
  self : Group,
  verb : @moonapi.Method,
  path : String,
  handler : @moonapi.ApiHandler,
  summary~ : String = "",
) -> Unit {
  let full = template(
    join_prefix(join_prefix(self.prefix, self.options.prefix), path),
  )
  self.app.route(verb, full, handler, summary~, hoops=hoops_of(self.options))
}

///|
/// Register a `GET` route under the group's prefix.
pub fn Group::get(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary~ : String = "",
) -> Unit {
  self.route(Get, path, handler, summary~)
}

///|
/// Register a `POST` route under the group's prefix.
pub fn Group::post(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary~ : String = "",
) -> Unit {
  self.route(Post, path, handler, summary~)
}

///|
/// Register a `PUT` route under the group's prefix.
pub fn Group::put(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary~ : String = "",
) -> Unit {
  self.route(Put, path, handler, summary~)
}

///|
/// Register a `PATCH` route under the group's prefix.
pub fn Group::patch(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary~ : String = "",
) -> Unit {
  self.route(Patch, path, handler, summary~)
}

///|
/// Register a `DELETE` route under the group's prefix.
pub fn Group::delete(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary~ : String = "",
) -> Unit {
  self.route(Delete, path, handler, summary~)
}

///|
/// Register a server-sent-events route: a `GET` that answers with
/// `text/event-stream` and is not cached.
pub fn Group::sse(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary~ : String = "",
) -> Unit {
  self.options_(self.options.sse()).get(path, handler, summary~)
}

///|
/// A go-zero path as moonapi writes it: go-zero names a path parameter `:id`,
/// moonapi `{id}`, so a route copied from an `.api` file registers unchanged.
fn template(path : String) -> String {
  path
  .split("/")
  .map(segment => {
    if segment.has_prefix(":") {
      "{" + segment.exact_view(start=1).to_owned() + "}"
    } else {
      segment.to_owned()
    }
  })
  .collect()
  .join("/")
}
