// A traced transport is a handle, not a turnstile: several tasks can call through the
// same one at once and each request still carries the context of its own span.

///|
/// A tracer whose ids change on every span, so two calls cannot be told apart by
/// accident. The fixed source the other tests use makes every trace id the same.
fn varying_tracing(sink : &@trace.Sink) -> @otel.Tracing {
  let serial : Ref[Int32] = Ref(1)
  let tracer = @trace.Tracer::new(
    rand=fn(width) {
      serial.val = serial.val + 1
      Bytes::make(width, serial.val.to_byte())
    },
    sink~,
    sampler=@trace.always,
  )
  @otel.Tracing::new(
    tracer~,
    now=clock(),
    agent=@otel.Agent::of_card(summariser_card()),
  )
}

///|
/// Read `name` out of a call's headers, whatever case the name was written in.
fn header_of(headers : @moona2a.Headers, name : String) -> String? {
  for pair in headers {
    if pair.0.to_lower() == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Whether `value` is in `values`.
fn among(values : Array[String], value : String) -> Bool {
  for item in values {
    if item == value {
      return true
    }
  }
  false
}

///|
/// A transport that holds two calls at the same point before either one reads its
/// headers. A shared cell would show the second call's context to both here; an
/// argument of the call cannot.
struct Crossing {
  arrived : Ref[Int32]
  seen : Ref[Array[(String, @moona2a.Headers)]]
}

///|
fn crossing() -> Crossing {
  { arrived: Ref(0), seen: Ref([]), }
}

///|
/// Wait until both calls are in the transport. This is a barrier, not a race on a
/// clock: neither call can finish until the other has arrived.
async fn Crossing::hold(self : Crossing) -> Unit {
  self.arrived.val = self.arrived.val + 1
  for _ in 0..<500 {
    if self.arrived.val >= 2 {
      return
    }
    @async.sleep(1)
  }
  fail("the two calls never reached the transport together")
}

///|
/// The one answer both calls read: a task, which is enough for `get_task` to return.
fn crossing_task() -> Json {
  @moona2a.Task::new("t-1", "c-1").with_state(@moona2a.Completed).to_json()
}

///|
async fn Crossing::reply(
  self : Crossing,
  message : @moonjrpc.Message,
  headers : @moona2a.Headers,
) -> @moonjrpc.Message {
  self.hold()
  match message {
    @moonjrpc.Call(id~, name~, ..) => {
      self.seen.val.push((name, headers))
      @moonjrpc.Message::Reply(id~, result=crossing_task())
    }
    _ => @moonjrpc.Message::unreadable()
  }
}

///|
impl @moona2a.Transport for Crossing with fn exchange(self, message) {
  self.reply(message, [])
}

///|
impl @moona2a.Transport for Crossing with fn exchange_with(
  self,
  message,
  headers,
) {
  self.reply(message, headers)
}

///|
async fn Crossing::deliver(
  self : Crossing,
  message : @moonjrpc.Message,
  out : &@moona2a.ReplySink,
  headers : @moona2a.Headers,
) -> Unit {
  match message {
    @moonjrpc.Call(id~, name~, ..) => {
      self.seen.val.push((name, headers))
      out.reply(@moonjrpc.Message::Reply(id~, result=crossing_task()))
    }
    _ => ()
  }
}

///|
impl @moona2a.Transport for Crossing with fn stream(self, message, out) {
  self.deliver(message, out, [])
}

///|
impl @moona2a.Transport for Crossing with fn stream_with(
  self,
  message,
  out,
  headers,
) {
  self.deliver(message, out, headers)
}

///|
fn Crossing::card(self : Crossing, headers : @moona2a.Headers) -> Json {
  self.seen.val.push(("GetAgentCard", headers))
  summariser_card().to_json()
}

///|
impl @moona2a.Transport for Crossing with fn discover(self) {
  self.card([])
}

///|
impl @moona2a.Transport for Crossing with fn discover_with(self, headers) {
  self.card(headers)
}

///|
pub extend Crossing with @moona2a.Transport::{
  exchange,
  exchange_with,
  stream,
  stream_with,
  discover,
  discover_with,
}

///|
/// A reply sink that keeps nothing; the test reads what the transport saw.
struct Empty {}

///|
impl @moona2a.ReplySink for Empty with fn reply(self, message) {
  ignore(self)
  ignore(message)
}

///|
async test "otel: two tasks share one traced transport and keep their own traces" {
  let sink = @trace.Recorder::new()
  let transport = crossing()
  // The old observation channel is attached too: it must not decide what goes on
  // the wire, even when two calls overlap.
  let observer = @otel.Injector::new()
  let client = @moona2a.Client::new(
    varying_tracing(sink).calling(transport, inject=observer.setting()),
  )
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      client.get_task("t-1", headers=[("x-call", "first")]) |> ignore
    }
    group.spawn_bg() <| () => {
      client.get_task("t-2", headers=[("x-call", "second")]) |> ignore
    }
  }
  let seen = transport.seen.val
  assert_eq(seen.length(), 2)
  let calls : Array[String] = []
  let parents : Array[String] = []
  for pair in seen {
    calls.push(header_of(pair.1, "x-call").unwrap_or(""))
    match header_of(pair.1, "traceparent") {
      Some(parent) => parents.push(parent)
      None => fail("a call reached the transport without its trace context")
    }
  }
  assert_true(among(calls, "first"))
  assert_true(among(calls, "second"))
  assert_true(parents[0] != parents[1])
  let spans = sink.spans()
  assert_eq(spans.length(), 2)
  assert_true(spans[0].context != spans[1].context)
  let expected = spans.map(fn(span) { span.context.to_traceparent() })
  assert_true(among(expected, parents[0]))
  assert_true(among(expected, parents[1]))
  assert_eq(observer.current(), [])
}

///|
async test "otel: a stream and a card read carry the headers of their own call" {
  let sink = @trace.Recorder::new()
  let transport = crossing()
  let client = @moona2a.Client::new(varying_tracing(sink).calling(transport))
  client.send_streaming_message(
    @moona2a.Message::user("m-1", "hi"),
    Empty::{ },
    headers=[("x-call", "stream")],
  )
  client.discover(headers=[("x-call", "card")]) |> ignore
  let seen = transport.seen.val
  assert_eq(seen.length(), 2)
  assert_eq(header_of(seen[0].1, "x-call"), Some("stream"))
  assert_eq(header_of(seen[1].1, "x-call"), Some("card"))
  let streamed = header_of(seen[0].1, "traceparent").unwrap_or("")
  let card = header_of(seen[1].1, "traceparent").unwrap_or("")
  assert_true(streamed.has_prefix("00-"))
  assert_true(card.has_prefix("00-"))
  assert_true(streamed != card)
  let expected = sink.spans().map(fn(span) { span.context.to_traceparent() })
  assert_true(among(expected, streamed))
  assert_true(among(expected, card))
}

///|
async test "otel: a caller's own traceparent is replaced by this call's span" {
  let sink = @trace.Recorder::new()
  let transport = crossing()
  let client = @moona2a.Client::new(varying_tracing(sink).calling(transport))
  client.discover(headers=[
    ("x-call", "card"),
    ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
  ])
  |> ignore
  let seen = transport.seen.val
  assert_eq(seen.length(), 1)
  let sent = header_of(seen[0].1, "traceparent").unwrap_or("")
  assert_true(sent.has_prefix("00-"))
  assert_true(sent != "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
  let expected = sink.spans().map(fn(span) { span.context.to_traceparent() })
  assert_true(among(expected, sent))
  let count = seen[0].1.length()
  assert_eq(count, 2)
}
