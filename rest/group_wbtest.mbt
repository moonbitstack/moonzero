///|
test "join_path normalises prefix and route" {
  assert_eq(join_path("/api/v1", "/users"), "/api/v1/users")
  assert_eq(join_path("/api/v1/", "/users"), "/api/v1/users")
  assert_eq(join_path("/api/v1", "users"), "/api/v1/users")
  assert_eq(join_path("", "/users"), "/users")
  assert_eq(join_path("/api/v1", ""), "/api/v1")
  assert_eq(join_path("", ""), "/")
}

///|
test "group prefixes routes onto the underlying app" {
  let app = @moonapi.App::new()
  let g = Group::new(app, "/api/v1")
  assert_eq(g.prefix(), "/api/v1")
  g.get("/users", _ctx => @moonapi.text(200, "users"))
  g.post("orders", _ctx => @moonapi.text(201, "made"))
  g.delete("/users/:id", ctx => @moonapi.text(200, ctx.param("id").unwrap()))
  // prefixed paths route
  assert_eq(app.handle(mkreq("GET", "/api/v1/users")).status, 200)
  assert_eq(app.handle(mkreq("POST", "/api/v1/orders")).status, 201)
  assert_eq(app.handle(mkreq("DELETE", "/api/v1/users/42")).status, 200)
  // the un-prefixed path does NOT match
  assert_eq(app.handle(mkreq("GET", "/users")).status, 404)
  // right path, wrong method -> 405
  assert_eq(app.handle(mkreq("PUT", "/api/v1/users")).status, 405)
}
