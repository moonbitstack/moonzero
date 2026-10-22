///|
test "tracing middleware assembles into an AsgiApp" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let _ = tracing()(app.to_asgi())
}
