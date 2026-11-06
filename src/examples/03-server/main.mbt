// Answer calls: a server turns a JSON-RPC body into a task and the task back into a body.

///|
/// An agent that looks the message up in a list of things it can say.
struct Scripted {}

///|
impl @moona2a.Executor for Scripted with fn execute(self, ctx, out) {
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
impl @moona2a.Executor for Scripted with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
pub extend Scripted with @moona2a.Executor::{execute, cancel}

///|
async fn main {
  let card = @moona2a.AgentCard::new(
    "echo",
    "repeats what it is told",
    "1.0.0",
    "https://echo.example.com",
    [@moona2a.AgentSkill::new("echo", "Echo", "repeats a message", ["echo"])],
  )
  let server = @moona2a.Server::new(Scripted::{ }, card)
  let send = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendMessage\",\"params\":{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"hello\"}]}}}"
  let answer = server.answer(send, version="1.0") catch { _ => None }
  match answer {
    Some(text) => {
      let result = @json.parse(text) catch { _ => Json::null() }
      let fields = match result {
        Object(fields) => fields
        _ => Map([])
      }
      match fields.get("result") {
        Some(Object(result)) =>
          match result.get("task") {
            Some(task) => {
              let read : @moona2a.Task = @json.from_json(task) catch {
                _ => @moona2a.Task::new("?", "?")
              }
              println(
                "the agent finished task \{read.id}: \{read.status.state.wire()}",
              )
              for artifact in read.artifacts {
                println(artifact.text_of())
              }
            }
            None => println("no task in the answer")
          }
        _ => println("the call was refused")
      }
    }
    None => println("nothing came back")
  }
}
