// The bridge to moonasgi's `mid` package.
//
// A layer there is `(AsgiApp) -> AsgiApp` and a middleware here is the same thing,
// so the two are one adapter apart. The adapter exists because the packages ship
// different ready-made layers: `mid` has the ones a plain ASGI host wants
// (body limits, proxy headers, https redirect), and this package has the ones a
// service wants (traces, access logs, breakers, shedding). A service that needs
// both should not have to keep two chains.

///|
/// A middleware as a layer of the `mid` stack.
struct AsLayer {
  middleware : Middleware
}

///|
impl @mid.Layer for AsLayer with fn wrap(
  self : AsLayer,
  app : @moonasgi.AsgiApp,
) {
  (self.middleware)(app)
}

///|
pub extend AsLayer with @mid.Layer::{wrap}

///|
/// This middleware as a `mid` layer, for a stack built by `@mid.stack`.
pub fn as_layer(middleware : Middleware) -> &@mid.Layer {
  AsLayer::{ middleware, }
}

///|
/// A `mid` layer as a middleware here, so a layer that package ships can sit in
/// this service's chain.
pub fn of_layer(layer : &@mid.Layer) -> Middleware {
  inner => layer.wrap(inner)
}
