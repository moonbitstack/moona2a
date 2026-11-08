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
  /// Where the headers of the call in flight go, when the transport can carry them.
  inject : ((Array[(String, String)]) -> Unit)?
}

///|
/// `transport`, with each call recorded.
///
/// `inject` is how a trace crosses to the other side: the wrapper hands it the headers of
/// the call it is about to make, and the transport under it puts them on the request. Pass
/// `injector.setting()` from an `Injector`, which is also what that transport asks for its
/// headers. Without it the spans are still right, but a callee sees no parent and starts a
/// trace of its own.
pub fn Tracing::calling(
  self : Tracing,
  transport : &@moona2a.Transport,
  inject? : (Array[(String, String)]) -> Unit,
) -> TracedTransport {
  { tracing: self, inner: transport, inject, }
}

///|
/// Write the headers of the call in flight, or clear them for a call that has no span.
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
pub impl @moona2a.Transport for TracedTransport with fn exchange(self, message) {
  let (name, attributes) = self.shape(message)
  let span = self.tracing.begin(name, @trace.Client, attributes)
  match span {
    None => {
      self.carrying(None)
      self.inner.exchange(message)
    }
    Some(span) => {
      self.carrying(Some(span.context()))
      let outcome = Ok(self.inner.exchange(message)) catch {
        error => Err(error)
      }
      self.carrying(None)
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
      match outcome {
        Ok(answer) => answer
        Err(error) => raise error
      }
    }
  }
}

///|
pub impl @moona2a.Transport for TracedTransport with fn stream(
  self,
  message,
  out,
) {
  let (name, attributes) = self.shape(message)
  let span = self.tracing.begin(name, @trace.Client, attributes)
  match span {
    None => {
      self.carrying(None)
      self.inner.stream(message, out)
    }
    Some(span) => {
      self.carrying(Some(span.context()))
      let watch : Watch = {
        span,
        now: self.tracing.now,
        settings: self.tracing.settings,
        state: None,
        answer: None,
      }
      let outcome = try {
        self.inner.stream(message, Watching::{ watch, out, })
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
pub impl @moona2a.Transport for TracedTransport with fn discover(self) {
  let span = self.tracing.begin(
    discover_span,
    @trace.Client,
    self.tracing.identity_attributes(),
  )
  match span {
    None => {
      self.carrying(None)
      self.inner.discover()
    }
    Some(span) => {
      self.carrying(Some(span.context()))
      let outcome = Ok(self.inner.discover()) catch { error => Err(error) }
      self.carrying(None)
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
      match outcome {
        Ok(card) => card
        Err(error) => raise error
      }
    }
  }
}

///|
pub extend TracedTransport with @moona2a.Transport::{exchange, stream, discover}
