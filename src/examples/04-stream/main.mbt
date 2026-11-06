// Stream a task: the agent works while the caller watches, one event at a time.

///|
/// An agent that reports each step as it takes it.
struct Steps {}

///|
impl @moona2a.Executor for Steps with fn execute(self, ctx, out) {
  ignore(self)
  out.emit(ctx.status(@moona2a.Working))
  out.emit(ctx.artifact(@moona2a.Artifact::text("plan", "1. read the input\n")))
  out.emit(
    ctx.artifact(
      @moona2a.Artifact::text("plan", "2. write the answer\n"),
      append=true,
      last_chunk=false,
    ),
  )
  out.emit(ctx.status(@moona2a.Completed))
}

///|
impl @moona2a.Executor for Steps with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
pub extend Steps with @moona2a.Executor::{execute, cancel}

///|
/// A sink that prints each reply as it arrives, which is what a streamed answer is for.
struct Printer {}

///|
impl @moona2a.ReplySink for Printer with fn reply(self, message) {
  ignore(self)
  match message {
    @moonjrpc.Reply(result~, ..) => {
      let event : @moona2a.StreamEvent = @json.from_json(result) catch {
        _ =>
          @moona2a.StreamEvent::TaskMessage(@moona2a.Message::agent("?", "?"))
      }
      match event {
        @moona2a.TaskSnapshot(task) =>
          println("task \{task.id}: \{task.status.state.wire()}")
        @moona2a.StatusChange(update) =>
          println("status: \{update.status.state.wire()}")
        @moona2a.ArtifactChunk(update) =>
          println("artifact: \{update.artifact.text_of()}")
        @moona2a.TaskMessage(message) => println("message: \{message.text()}")
      }
    }
    @moonjrpc.Refusal(failure~, ..) => println("refused: \{failure.message}")
    _ => ()
  }
}

///|
pub extend Printer with @moona2a.ReplySink::{reply}

///|
async fn main {
  let card = @moona2a.AgentCard::new(
    "planner",
    "thinks out loud",
    "1.0.0",
    "https://planner.example.com",
    [@moona2a.AgentSkill::new("plan", "Plan", "writes a plan", ["plan"])],
  ).capable(@moona2a.AgentCapabilities::streaming_and_push())
  let server = @moona2a.Server::new(Steps::{ }, card)
  let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendStreamingMessage\",\"params\":{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"plan my day\"}]}}}"
  server.answer_stream(body, Printer::{ }, version="1.0")
}
