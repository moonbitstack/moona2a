// The one piece of state a traced call needs: the headers of the call in flight.
//
// The wrapper knows the span; the transport is what puts headers on the wire, and the
// protocol's `Transport` trait has no room for them. So the wrapper writes the headers
// here, the transport reads them as it builds the request, and the wrapper clears them
// when the call returns.

///|
/// A list of headers, in the spelling the wire uses: the name, then the value.
pub type Headers = Array[(String, String)]

///|
/// A cell between a traced transport and the transport under it: `Tracing::calling` writes
/// the headers of the call it is about to make, and the transport reads them when it builds
/// the request.
///
/// One call at a time. The headers ride on the transport rather than on the call, because
/// the protocol trait has no per-call place for them, so a transport shared by several tasks
/// at once would put one call's `traceparent` on another's request. A host that fans out
/// gives each task its own transport, which is a handle and costs a struct.
pub struct Injector {
  cell : Ref[Headers]
}

///|
/// An injector holding no headers.
pub fn Injector::new() -> Injector {
  { cell: Ref(([] : Headers)), }
}

///|
/// The headers of the call in flight, which a transport reads while it builds the request:
/// `@fetch.HttpTransport::new(url, headers=fn() { injector.current() })`.
pub fn Injector::current(self : Injector) -> Headers {
  self.cell.val
}

///|
/// The sink `Tracing::calling` writes into: the headers of the call it is making, or none.
pub fn Injector::setting(self : Injector) -> (Headers) -> Unit {
  fn(headers) { self.cell.val = headers }
}
