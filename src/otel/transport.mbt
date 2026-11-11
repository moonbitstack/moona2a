// The calling side, recorded: one span per call, of kind `Client`, with the agent it
// talks to on it and, for a stream, every event the agent sent.

///|
/// A reply sink that watches what a streamed answer carries and passes it on.
priv struct Watching {
  watch : Watch
  out : &@moona2a.ReplySink
}

///|
impl @moona2a.ReplySink for Watching with fn reply(self, message) {
  match message {
    @moonjrpc.Message::Reply(result~, ..) => {
      let event : @moona2a.StreamEvent = @json.from_json(result) catch {
        _ => return self.out.reply(message)
      }
      self.watch.event(event)
    }
    @moonjrpc.Message::Refusal(failure~, ..) =>
      self.watch.span.set_status(@trace.Error(failure.message))
    _ => ()
  }
  self.out.reply(message)
}

///|
/// A transport that records each call as a span, then carries it.
///
/// A message send is an agent invocation, so it gets the span the conventions name
/// for one: `invoke_agent` and the agent. Everything else gets `a2a.` and the method,
/// since no convention names reading a task.
pub struct TracedTransport {
  tracing : Tracing
  inner : &@moona2a.Transport
  /// An optional observer of the headers of a call in flight. The headers themselves
  /// travel as an argument of the call, not through this sink.
  inject : ((Array[(String, String)]) -> Unit)?
}

///|
/// `transport`, with each call recorded.
///
/// A call's `traceparent` is added to that call's own headers, which reach the transport
/// as an argument. One wrapper can therefore serve many tasks at once: a span opened by
/// one of them cannot appear on another's request. `inject` is an observer for a host
/// that wants to see those headers while a single call is in flight; it is not part of
/// the path to the wire, and a wrapper shared by tasks has no one call's headers to show.
pub fn Tracing::calling(
  self : Tracing,
  transport : &@moona2a.Transport,
  inject? : (Array[(String, String)]) -> Unit,
) -> TracedTransport {
  { tracing: self, inner: transport, inject, }
}

///|
/// Tell the observer the headers of the call in flight, or clear them for a call that
/// has no span. The transport is not read from here: it receives them as an argument.
fn TracedTransport::carrying(
  self : TracedTransport,
  context : @trace.TraceContext?,
) -> Unit {
  match self.inject {
    Some(sink) =>
      match context {
        Some(context) =>
          sink(
            @propagate.inject([], {
              context: Some(context),
              baggage: @propagate.empty_baggage,
            }),
          )
        None => sink([])
      }
    None => ()
  }
}

///|
/// The headers of this call, with the span's context added. Nothing here is shared
/// between calls, so a transport under several tasks sees one context per request.
fn TracedTransport::outgoing(
  self : TracedTransport,
  headers : @moona2a.Headers,
  context : @trace.TraceContext?,
) -> @moona2a.Headers {
  ignore(self)
  match context {
    Some(context) =>
      @moona2a.merge_headers(
        headers,
        @propagate.inject([], {
          context: Some(context),
          baggage: @propagate.empty_baggage,
        }),
      )
    None => headers
  }
}

///|
/// The span name and the attributes one outgoing message gets.
///
/// Sending a message is an agent invocation, so its span carries the operation name the
/// conventions require of one. Reading a task or a card is not, and a span that claimed
/// otherwise would be a lie a backend aggregates on.
fn TracedTransport::shape(
  self : TracedTransport,
  message : @moonjrpc.Message,
) -> (String, Array[(String, @trace.Value)]) {
  match message {
    @moonjrpc.Message::Call(name~, params~, ..) => {
      let invokes = match @moona2a.Method::from_name(name) {
        Some(rpc) =>
          rpc == @moona2a.SendMessage || rpc == @moona2a.SendStreamingMessage
        None => false
      }
      let attributes = if invokes {
        self.tracing.agent_attributes()
      } else {
        self.tracing.identity_attributes()
      }
      attributes.push((a2a_method, @trace.Str(name)))
      let span_name = if invokes {
        self.tracing.invocation_name()
      } else {
        call_span
      }
      if self.tracing.settings.record_content {
        match sent_message(params) {
          Some(sent) =>
            attributes.push(
              (
                @semconv.gen_ai_input_messages,
                @trace.Str(self.tracing.messages_json(sent)),
              ),
            )
          None => ()
        }
      }
      (span_name, attributes)
    }
    _ => (call_span, self.tracing.identity_attributes())
  }
}

///|
/// The message a call carries, for the two methods that carry one.
fn sent_message(params : Json?) -> @moona2a.Message? {
  let json = match params {
    Some(json) => json
    None => return None
  }
  let request : @moona2a.SendMessageRequest = @json.from_json(json) catch {
    _ => return None
  }
  Some(request.message)
}

///|
/// One call and its span. The headers belong to the call, from the span that opens here
/// to the transport that sends them.
async fn TracedTransport::carry_call(
  self : TracedTransport,
  message : @moonjrpc.Message,
  headers : @moona2a.Headers,
) -> @moonjrpc.Message {
  let (name, attributes) = self.shape(message)
  let span = self.tracing.begin(name, @trace.Client, attributes)
  let context = match span {
    Some(opened) => Some(opened.context())
    None => None
  }
  self.carrying(context)
  let outcome = Ok(
    self.inner.exchange_with(message, self.outgoing(headers, context)),
  ) catch {
    error => Err(error)
  }
  self.carrying(None)
  match span {
    Some(span) => {
      match outcome {
        Ok(answer) =>
          match answer {
            @moonjrpc.Message::Refusal(failure~, ..) =>
              span.set_status(@trace.Error(failure.message))
            _ => span.set_status(@trace.Ok)
          }
        Err(error) => {
          span.record_exception(message="\{error}", at=(self.tracing.now)())
          span.set_status(@trace.Error("the call raised"))
        }
      }
      span.finish(at=(self.tracing.now)())
    }
    None => ()
  }
  match outcome {
    Ok(answer) => answer
    Err(error) => raise error
  }
}

///|
/// One streamed call and its span.
async fn TracedTransport::carry_stream(
  self : TracedTransport,
  message : @moonjrpc.Message,
  out : &@moona2a.ReplySink,
  headers : @moona2a.Headers,
) -> Unit {
  let (name, attributes) = self.shape(message)
  let span = self.tracing.begin(name, @trace.Client, attributes)
  let context = match span {
    Some(opened) => Some(opened.context())
    None => None
  }
  self.carrying(context)
  match span {
    None => {
      self.inner.stream_with(message, out, self.outgoing(headers, context))
      self.carrying(None)
    }
    Some(span) => {
      let watch : Watch = {
        span,
        now: self.tracing.now,
        settings: self.tracing.settings,
        state: None,
        answer: None,
      }
      let outcome = try {
        self.inner.stream_with(
          message,
          Watching::{ watch, out, },
          self.outgoing(headers, context),
        )
        None
      } catch {
        error => Some(error)
      }
      self.carrying(None)
      // A stream that ended on a refusal already set the status; a run that ended in
      // a state sets it here, and a stream that simply stopped leaves it alone.
      watch.finish(outcome)
      match outcome {
        Some(error) => raise error
        None => ()
      }
    }
  }
}

///|
/// Reading a card is its own call, with its own headers.
async fn TracedTransport::carry_card(
  self : TracedTransport,
  headers : @moona2a.Headers,
) -> Json {
  let span = self.tracing.begin(
    discover_span,
    @trace.Client,
    self.tracing.identity_attributes(),
  )
  let context = match span {
    Some(opened) => Some(opened.context())
    None => None
  }
  self.carrying(context)
  let outcome = Ok(self.inner.discover_with(self.outgoing(headers, context))) catch {
    error => Err(error)
  }
  self.carrying(None)
  match span {
    Some(span) => {
      match outcome {
        Ok(card) => {
          ignore(card)
          span.set_status(@trace.Ok)
        }
        Err(error) => {
          span.record_exception(message="\{error}", at=(self.tracing.now)())
          span.set_status(@trace.Error("the card could not be read"))
        }
      }
      span.finish(at=(self.tracing.now)())
    }
    None => ()
  }
  match outcome {
    Ok(card) => card
    Err(error) => raise error
  }
}

///|
pub impl @moona2a.Transport for TracedTransport with fn exchange(self, message) {
  self.carry_call(message, [])
}

///|
pub impl @moona2a.Transport for TracedTransport with fn exchange_with(
  self,
  message,
  headers,
) {
  self.carry_call(message, headers)
}

///|
pub impl @moona2a.Transport for TracedTransport with fn stream(
  self,
  message,
  out,
) {
  self.carry_stream(message, out, [])
}

///|
pub impl @moona2a.Transport for TracedTransport with fn stream_with(
  self,
  message,
  out,
  headers,
) {
  self.carry_stream(message, out, headers)
}

///|
pub impl @moona2a.Transport for TracedTransport with fn discover(self) {
  self.carry_card([])
}

///|
pub impl @moona2a.Transport for TracedTransport with fn discover_with(
  self,
  headers,
) {
  self.carry_card(headers)
}

///|
pub extend TracedTransport with @moona2a.Transport::{
  exchange,
  exchange_with,
  stream,
  stream_with,
  discover,
  discover_with,
}
