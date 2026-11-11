// An observer for the headers of a call in flight. The headers reach the transport as an
// argument of the call; this cell only lets a host see what a single call is carrying.

///|
/// A list of headers, in the spelling the wire uses: the name, then the value.
pub type Headers = @moona2a.Headers

///|
/// A cell a host can read while one call is in flight. It is not on the path to the wire:
/// `Transport` receives each call's headers as an argument, so a wrapper shared by several
/// tasks needs no cell and mixes no traces. Use `current()` to observe a single call — for
/// instance in a test or a diagnostic — and do not rely on it when calls overlap.
pub struct Injector {
  cell : Ref[Headers]
}

///|
/// An injector holding no headers.
pub fn Injector::new() -> Injector {
  { cell: Ref(([] : Headers)), }
}

///|
/// The headers the observer was last given. A transport that wants the headers of the
/// call it is making takes them from its `*_with` argument instead.
pub fn Injector::current(self : Injector) -> Headers {
  self.cell.val
}

///|
/// The sink `Tracing::calling` writes into when `inject` was supplied: the headers of
/// the call it is making, or none.
pub fn Injector::setting(self : Injector) -> (Headers) -> Unit {
  fn(headers) { self.cell.val = headers }
}
