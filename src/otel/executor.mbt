// An agent run, recorded: the span opens when the executor is handed the request and
// closes when it stops emitting, with the state the task reached on it.

///|
/// What the span of one run accumulates while the run happens.
priv struct Watch {
  span : @trace.Span
  now : () -> Int64
  settings : Settings
  /// The last state the task was seen in, or none for a run that never spoke of one.
  mut state : @moona2a.TaskState?
  /// The agent's answer, when the settings ask for message text.
  mut answer : String?
}

///|
/// Record `event` on the watch's span and fold it into the state the span will end
/// with. Each update is a point in time inside the run, which is what a span event is.
fn Watch::event(self : Watch, event : @moona2a.StreamEvent) -> Unit {
  match event {
    @moona2a.TaskSnapshot(task) => self.moved(task.status.state)
    @moona2a.StatusChange(update) => self.moved(update.status.state)
    @moona2a.TaskMessage(message) =>
      if self.settings.record_content {
        self.answer = Some(clipped(message.text(), self.settings.text_limit))
      }
    @moona2a.ArtifactChunk(update) => {
      self.span.add_event(
        a2a_artifact_event,
        attributes=[(a2a_artifact_id, @trace.Str(update.artifact.artifact_id))],
        at=(self.now)(),
      )
      if self.settings.record_content {
        let text = clipped(update.artifact.text_of(), self.settings.text_limit)
        self.answer = Some(
          if update.append {
            self.answer.unwrap_or("") + text
          } else {
            text
          },
        )
      }
    }
  }
}

///|
/// The task moved to `state`: an event on the span now, an attribute when it closes.
fn Watch::moved(self : Watch, state : @moona2a.TaskState) -> Unit {
  self.state = Some(state)
  self.span.add_event(
    a2a_task_status_event,
    attributes=[(a2a_task_state, @trace.Str(state.wire()))],
    at=(self.now)(),
  )
}

///|
/// Close the span: the state the task ended in, the answer when text was recorded, and
/// the status the run earned. A run that raised is the failure, whatever the task says.
fn Watch::finish(self : Watch, failure : Error?) -> Unit {
  match self.state {
    Some(state) =>
      self.span.set_attribute(a2a_task_state, @trace.Str(state.wire()))
    None => ()
  }
  if self.settings.record_content {
    match self.answer {
      Some(text) =>
        self.span.set_attribute(
          @semconv.gen_ai_output_messages,
          @trace.Str(answer_json(text, self.settings.text_limit)),
        )
      None => ()
    }
  }
  match failure {
    Some(error) => {
      self.span.record_exception(message="\{error}", at=(self.now)())
      self.span.set_status(@trace.Error("the run raised"))
    }
    None =>
      match self.state {
        Some(state) =>
          if state == @moona2a.Failed || state == @moona2a.Rejected {
            self.span.set_status(@trace.Error(state.wire()))
          } else if state.terminal() {
            self.span.set_status(@trace.Ok)
          }
        None => ()
      }
  }
  self.span.finish(at=(self.now)())
}

///|
/// A sink that watches what the agent emits and passes it on untouched.
priv struct Recording {
  watch : Watch
  out : &@moona2a.EventSink
}

///|
impl @moona2a.EventSink for Recording with fn emit(self, event) {
  self.watch.event(event)
  self.out.emit(event)
}

///|
/// An executor that records each run as a span, then does what the agent would have
/// done. The span is `invoke_agent` and the agent's name, of kind `Internal`: the work
/// happens here, not on a caller's side of a network.
pub struct Traced {
  tracing : Tracing
  inner : &@moona2a.Executor
}

///|
/// `executor`, with each run recorded.
pub fn Tracing::executing(
  self : Tracing,
  executor : &@moona2a.Executor,
) -> Traced {
  { tracing: self, inner: executor, }
}

///|
pub impl @moona2a.Executor for Traced with fn execute(self, ctx, out) {
  let attributes = self.tracing.agent_attributes()
  attributes.push((@semconv.gen_ai_conversation_id, @trace.Str(ctx.context_id)))
  attributes.push((a2a_task_id, @trace.Str(ctx.task_id)))
  if self.tracing.settings.record_content {
    attributes.push(
      (
        @semconv.gen_ai_input_messages,
        @trace.Str(self.tracing.messages_json(ctx.message)),
      ),
    )
  }
  // The trace the caller was already in, when the request brought one: the run joins it
  // rather than starting a second one, so one trace covers both agents.
  let name = self.tracing.invocation_name()
  let span = match parent_of(ctx.headers) {
    Some(context) =>
      self.tracing.begin(name, @trace.Internal, attributes, parent=context)
    None => self.tracing.begin(name, @trace.Internal, attributes)
  }
  match span {
    None => self.inner.execute(ctx, out)
    Some(span) => {
      let watch : Watch = {
        span,
        now: self.tracing.now,
        settings: self.tracing.settings,
        state: None,
        answer: None,
      }
      let outcome = try {
        self.inner.execute(ctx, Recording::{ watch, out, })
        None
      } catch {
        error => Some(error)
      }
      watch.finish(outcome)
      match outcome {
        Some(error) => raise error
        None => ()
      }
    }
  }
}

///|
pub impl @moona2a.Executor for Traced with fn cancel(self, task_id) {
  let attributes : Array[(String, @trace.Value)] = [
    (a2a_task_id, @trace.Str(task_id)),
  ]
  let span = self.tracing.begin(cancel_span, @trace.Internal, attributes)
  match span {
    None => self.inner.cancel(task_id)
    Some(span) => {
      let outcome = try {
        self.inner.cancel(task_id)
        None
      } catch {
        error => Some(error)
      }
      match outcome {
        Some(error) => {
          span.record_exception(message="\{error}", at=(self.tracing.now)())
          span.set_status(@trace.Error("the cancel raised"))
        }
        None => span.set_status(@trace.Ok)
      }
      span.finish(at=(self.tracing.now)())
      match outcome {
        Some(error) => raise error
        None => ()
      }
    }
  }
}

///|
pub extend Traced with @moona2a.Executor::{execute, cancel}
