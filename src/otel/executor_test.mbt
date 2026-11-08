// A run, as a backend sees it: one span named for the operation and the agent, the
// task state it ended in, and an event for each thing the agent said.

///|
/// An agent that answers with the message it was given, the way the guide's does.
struct Echo {}

///|
impl @moona2a.Executor for Echo with fn execute(self, ctx, out) {
  ignore(self)
  out.emit(ctx.status(@moona2a.Working))
  out.emit(
    ctx.artifact(
      @moona2a.Artifact::text("answer", "You said: " + ctx.message.text()),
    ),
  )
  out.emit(ctx.status(@moona2a.Completed))
}

///|
impl @moona2a.Executor for Echo with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
pub extend Echo with @moona2a.Executor::{execute, cancel}

///|
/// An agent that trips over its own work, which the server has to record as a failure.
struct Broken {}

///|
impl @moona2a.Executor for Broken with fn execute(self, ctx, out) {
  ignore(self)
  ignore(ctx)
  ignore(out)
  raise @moona2a.InvalidAgentResponse("nothing to say")
}

///|
impl @moona2a.Executor for Broken with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
pub extend Broken with @moona2a.Executor::{execute, cancel}

///|
/// The request an agent is handed for a message on the task `t-1`.
fn request() -> @moona2a.RequestContext {
  {
    message: @moona2a.Message::user("m-1", "summarise this"),
    task_id: "t-1",
    context_id: "c-1",
    task: None,
  }
}

///|
async test "otel: a run is one span, named for the operation and the agent" {
  let sink = @trace.Recorder::new()
  let out = @moona2a.Collected::new()
  tracing(sink).executing(Echo::{ }).execute(request(), out)
  let spans = sink.spans()
  assert_eq(spans.length(), 1)
  let span = span_at(spans, 0)
  assert_eq(span.name, "invoke_agent summariser")
  assert_eq(span.kind, @trace.Internal)
  assert_eq(
    text_attribute_of(span, "gen_ai.operation.name"),
    Some("invoke_agent"),
  )
  assert_eq(text_attribute_of(span, "gen_ai.agent.name"), Some("summariser"))
  assert_eq(
    text_attribute_of(span, "gen_ai.agent.id"),
    Some("https://summariser.example.com"),
  )
  assert_eq(text_attribute_of(span, "gen_ai.conversation.id"), Some("c-1"))
  assert_eq(text_attribute_of(span, "a2a.task.id"), Some("t-1"))
  assert_eq(
    text_attribute_of(span, "a2a.task.state"),
    Some("TASK_STATE_COMPLETED"),
  )
  assert_eq(span.status, @trace.Ok)
  assert_true(span.end > span.start)
}

///|
async test "otel: every thing the agent said is an event on the span" {
  let sink = @trace.Recorder::new()
  tracing(sink)
  .executing(Echo::{ })
  .execute(request(), @moona2a.Collected::new())
  let span = span_at(sink.spans(), 0)
  assert_eq(event_names(span), [
    "a2a.task.status", "a2a.artifact.produced", "a2a.task.status",
  ])
  let status = span.events[2]
  assert_eq(
    status.attributes[0],
    ("a2a.task.state", @trace.Str("TASK_STATE_COMPLETED")),
  )
  assert_eq(span.events[1].attributes[0].1, @trace.Str("answer"))
}

///|
async test "otel: the message is not in the span unless the settings say so" {
  let quiet = @trace.Recorder::new()
  tracing(quiet)
  .executing(Echo::{ })
  .execute(request(), @moona2a.Collected::new())
  assert_eq(
    attribute_of(span_at(quiet.spans(), 0), "gen_ai.input.messages"),
    None,
  )
  assert_eq(
    attribute_of(span_at(quiet.spans(), 0), "gen_ai.output.messages"),
    None,
  )

  let loud = @trace.Recorder::new()
  tracing(loud)
  .recording_content()
  .executing(Echo::{ })
  .execute(request(), @moona2a.Collected::new())
  let span = span_at(loud.spans(), 0)
  assert_eq(
    text_attribute_of(span, "gen_ai.input.messages"),
    Some(
      "[{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"content\":\"summarise this\"}]}]",
    ),
  )
  assert_eq(
    text_attribute_of(span, "gen_ai.output.messages"),
    Some(
      "[{\"role\":\"assistant\",\"parts\":[{\"type\":\"text\",\"content\":\"You said: summarise this\"}]}]",
    ),
  )
}

///|
async test "otel: recorded text is cut at the limit the settings name" {
  let sink = @trace.Recorder::new()
  tracing(sink)
  .recording_content()
  .at_most(5)
  .executing(Echo::{ })
  .execute(request(), @moona2a.Collected::new())
  assert_eq(
    text_attribute_of(span_at(sink.spans(), 0), "gen_ai.input.messages"),
    Some(
      "[{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"content\":\"summa\"}]}]",
    ),
  )
}

///|
async test "otel: a run that raises is an error span, and the error still arrives" {
  let sink = @trace.Recorder::new()
  let traced = tracing(sink).executing(Broken::{ })
  let refused = try {
    traced.execute(request(), @moona2a.Collected::new())
    false
  } catch {
    @moona2a.InvalidAgentResponse(_) => true
    _ => false
  }
  assert_true(refused)
  let span = span_at(sink.spans(), 0)
  match span.status {
    @trace.Error(_) => ()
    _ => fail("a run that raised should be an error span")
  }
  assert_eq(span.events[span.events.length() - 1].name, "exception")
}

///|
async test "otel: a broken source of ids leaves the run going, untraced" {
  let sink = @trace.Recorder::new()
  let tracing = @otel.Tracing::new(
    tracer=broken_tracer(sink),
    now=clock(),
    agent=@otel.Agent::of_card(summariser_card()),
  )
  let out = @moona2a.Collected::new()
  tracing.executing(Echo::{ }).execute(request(), out)
  assert_eq(sink.spans().length(), 0)
  assert_eq(out.events().length(), 3)
}

///|
async test "otel: a cancellation is its own span" {
  let sink = @trace.Recorder::new()
  tracing(sink).executing(Echo::{ }).cancel("t-1")
  let span = span_at(sink.spans(), 0)
  assert_eq(span.name, "a2a.cancel_task")
  assert_eq(span.kind, @trace.Internal)
  assert_eq(text_attribute_of(span, "a2a.task.id"), Some("t-1"))
  assert_eq(span.status, @trace.Ok)
}
