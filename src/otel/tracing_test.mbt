// What the instrumentation says about an agent, and what it leaves out. The tracer
// writes into a recorder, so a test reads the spans the way a backend would.

///|
/// A tracer whose ids are all one byte: nothing here is about ids, and a fixed source
/// makes a span's name and attributes the only thing a test can see.
fn tracer(sink : &@trace.Sink) -> @trace.Tracer {
  @trace.Tracer::new(
    rand=fn(width) { Bytes::make(width, b'\x01') },
    sink~,
    sampler=@trace.always,
  )
}

///|
/// A tracer whose ids are all zero, which a trace context refuses: a run has to go
/// ahead without a span rather than fail.
fn broken_tracer(sink : &@trace.Sink) -> @trace.Tracer {
  @trace.Tracer::new(
    rand=fn(width) { Bytes::make(width, b'\x00') },
    sink~,
    sampler=@trace.always,
  )
}

///|
/// A clock that moves a millisecond each time it is read, so a span has a duration.
fn clock() -> () -> Int64 {
  let now : Ref[Int64] = Ref(0L)
  fn() -> Int64 {
    now.val = now.val + 1_000_000L
    now.val
  }
}

///|
/// The span at `index`.
fn span_at(
  spans : Array[@trace.SpanData],
  index : Int32,
) -> @trace.SpanData raise {
  if index >= spans.length() {
    fail("the run left \{spans.length()} spans, and \{index} was asked for")
  }
  spans[index]
}

///|
/// What `key` holds on `span`, or none when the span does not carry it.
fn attribute_of(span : @trace.SpanData, key : String) -> @trace.Value? {
  for pair in span.attributes {
    if pair.0 == key {
      return Some(pair.1)
    }
  }
  None
}

///|
/// The attribute `key` as text, or none when it is absent or not text.
fn text_attribute_of(span : @trace.SpanData, key : String) -> String? {
  match attribute_of(span, key) {
    Some(@trace.Str(text)) => Some(text)
    _ => None
  }
}

///|
/// The names of the events a span carries, in order.
fn event_names(span : @trace.SpanData) -> Array[String] {
  span.events.map(fn(event) { event.name })
}

///|
/// A card for an agent that summarises documents, which is what a span is named after.
fn summariser_card() -> @moona2a.AgentCard {
  @moona2a.AgentCard::new(
    "summariser",
    "An agent that condenses documents",
    "1.0.0",
    "https://summariser.example.com",
    [@moona2a.AgentSkill::new("summarise", "Summarise", "condense", ["text"])],
  )
}

///|
/// The instrumentation a test runs with.
fn tracing(sink : &@trace.Sink) -> @otel.Tracing {
  @otel.Tracing::new(
    tracer=tracer(sink),
    now=clock(),
    agent=@otel.Agent::of_card(summariser_card()),
  )
}

///|
test "otel: an agent takes its identity from the card it publishes" {
  let agent = @otel.Agent::of_card(summariser_card())
  assert_eq(agent.id, "https://summariser.example.com")
  assert_eq(agent.name, "summariser")
  assert_eq(agent.description, Some("An agent that condenses documents"))
  assert_eq(agent.version, Some("1.0.0"))
}

///|
test "otel: message text is left out unless an operator asks for it" {
  assert_eq(@otel.settings.record_content, false)
  assert_eq(@otel.settings.text_limit, 512)
}
