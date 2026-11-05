// A server answers the protocol's methods: it opens tasks, folds what the agent says into them,
// refuses what the specification says to refuse, and streams the same events a caller can follow.

///|
/// An agent that works a request according to the first word of its message, so a test can ask for
/// a finished task, an interrupted one, or a plain message.
struct Scripted {}

///|
impl @moona2a.Executor for Scripted with fn execute(self, ctx, out) {
  ignore(self)
  match ctx.message.text() {
    "hello" => {
      out.emit(ctx.status(@moona2a.Working))
      out.emit(ctx.artifact(@moona2a.Artifact::text("a-1", "done")))
      out.emit(ctx.status(@moona2a.Completed))
    }
    "wait" => out.emit(ctx.status(@moona2a.InputRequired))
    "auth" => out.emit(ctx.status(@moona2a.AuthRequired))
    "several" => {
      out.emit(ctx.status(@moona2a.Working))
      out.emit(
        ctx.artifact(@moona2a.Artifact::text("a-1", "first"), last_chunk=false),
      )
      out.emit(
        ctx.artifact(
          @moona2a.Artifact::text("a-1", "second"),
          append=true,
          last_chunk=true,
        ),
      )
      out.emit(ctx.status(@moona2a.Completed))
    }
    "boom" => raise ScriptError("the agent fell over")
    _ => out.emit(ctx.replying([@moona2a.Part::text("hi")]))
  }
}

///|
impl @moona2a.Executor for Scripted with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
suberror ScriptError {
  ScriptError(String)
}

///|
pub extend Scripted with @moona2a.Executor::{execute, cancel}

///|
/// The card a test server publishes.
fn test_card() -> @moona2a.AgentCard {
  @moona2a.AgentCard::new(
    "tester",
    "an agent for tests",
    "1.0.0",
    "https://agent.test",
    [@moona2a.AgentSkill::new("echo", "Echo", "says things back", ["test"])],
  ).capable(@moona2a.AgentCapabilities::streaming_and_push())
}

///|
/// A sink that keeps every reply, for checking what a stream carried.
struct Recorder {
  replies : Array[@moonjrpc.Message]
}

///|
impl @moona2a.ReplySink for Recorder with fn reply(self, message) {
  self.replies.push(message)
}

///|
pub extend Recorder with @moona2a.ReplySink::{reply}

///|
/// The string under `key`, when it is one.
fn field_str(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
/// The integer under `key`, when it is one.
fn field_int(fields : Map[String, Json], key : String) -> Int32? {
  match fields.get(key) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
/// Whether `key` holds true.
fn field_bool(fields : Map[String, Json], key : String) -> Bool {
  match fields.get(key) {
    Some(True) => true
    _ => false
  }
}

///|
/// One JSON-RPC call to a server, as text.
fn call_text(id : Int32, name : String, params : String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\{id},\"method\":\"\{name}\",\"params\":\{params}}"
}

///|
/// The `result` of an answer, which must be present.
fn result_of(answer : String?) -> Json raise {
  let text = match answer {
    Some(text) => text
    None => fail("the server answered nothing")
  }
  let json = @json.parse(text) catch {
    _ => fail("the answer is not JSON: \{text}")
  }
  match json {
    Object(fields) =>
      match fields.get("result") {
        Some(result) => result
        None => fail("the answer is an error: \{text}")
      }
    _ => fail("the answer is not an object: \{text}")
  }
}

///|
/// The `error` code of an answer, which must be an error.
fn error_code_of(answer : String?) -> Int32 raise {
  let text = match answer {
    Some(text) => text
    None => fail("the server answered nothing")
  }
  let json = @json.parse(text) catch {
    _ => fail("the answer is not JSON: \{text}")
  }
  match json {
    Object(fields) =>
      match fields.get("error") {
        Some(Object(error)) =>
          match error.get("code") {
            Some(Number(code, ..)) => code.to_int()
            _ => 0
          }
        _ => fail("the answer is not an error: \{text}")
      }
    _ => fail("the answer is not an object: \{text}")
  }
}

///|
/// The task inside a send answer.
fn task_of(result : Json) -> @moona2a.Task raise {
  let fields = match result {
    Object(fields) => fields
    _ => fail("the result is not an object")
  }
  match fields.get("task") {
    Some(task) => {
      let read : @moona2a.Task = @json.from_json(task) catch {
        _ => fail("the task does not read")
      }
      read
    }
    None => fail("the result carries no task")
  }
}

///|
/// The task a method answers with directly, as `GetTask` and `CancelTask` do.
fn bare_task_of(result : Json) -> @moona2a.Task raise {
  let read : @moona2a.Task = @json.from_json(result) catch {
    _ => fail("the result is not a task")
  }
  read
}

///|
/// A send of one text message, as the protocol writes it.
fn send_params(text : String, message_id : String) -> String {
  "{\"message\":{\"messageId\":\"\{message_id}\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"\{text}\"}]}}"
}

///|
async test "server: a send opens a task and works it to the end" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let answer = server.answer(
    call_text(1, "SendMessage", send_params("hello", "m-1")),
  )
  let task = task_of(result_of(answer))
  assert_eq(task.status.state.wire(), "TASK_STATE_COMPLETED")
  assert_eq(task.artifacts.length(), 1)
  assert_eq(task.artifacts[0].text_of(), "done")
  // The message that started the task is its history.
  assert_eq(task.history.length(), 1)
  assert_eq(task.history[0].text(), "hello")
  // Section 3.6.1: an answer carries the version it speaks.
  assert_eq(server.card().supported_interfaces[0].protocol_version, "1.0")
}

///|
async test "server: an agent that only answers with a message opens no task" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let answer = server.answer(
    call_text(1, "SendMessage", send_params("say something", "m-1")),
  )
  let result = result_of(answer)
  let fields = match result {
    Object(fields) => fields
    _ => fail("the result is not an object")
  }
  assert_true(fields.contains("message"))
  assert_false(fields.contains("task"))
}

///|
async test "server: the task a send answers can be read back" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = task_of(
    result_of(
      server.answer(call_text(1, "SendMessage", send_params("hello", "m-1"))),
    ),
  )
  let answer = server.answer(call_text(2, "GetTask", "{\"id\":\"\{task.id}\"}"))
  let read = bare_task_of(result_of(answer))
  assert_eq(read.id, task.id)
  assert_eq(read.status.state.wire(), "TASK_STATE_COMPLETED")
}

///|
async test "server: reading a task that does not exist is a task-not-found refusal" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let answer = server.answer(call_text(1, "GetTask", "{\"id\":\"nope\"}"))
  assert_eq(error_code_of(answer), -32001)
}

///|
async test "server: a task in a terminal state takes no more messages" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = task_of(
    result_of(
      server.answer(call_text(1, "SendMessage", send_params("hello", "m-1"))),
    ),
  )
  let follow_up = "{\"message\":{\"messageId\":\"m-2\",\"role\":\"ROLE_USER\",\"taskId\":\"\{task.id}\",\"parts\":[{\"text\":\"again\"}]}}"
  let answer = server.answer(call_text(2, "SendMessage", follow_up))
  assert_eq(error_code_of(answer), -32004)
}

///|
async test "server: a message to an unknown task is a task-not-found refusal" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let message = "{\"message\":{\"messageId\":\"m-2\",\"role\":\"ROLE_USER\",\"taskId\":\"ghost\",\"parts\":[{\"text\":\"hi\"}]}}"
  let answer = server.answer(call_text(2, "SendMessage", message))
  assert_eq(error_code_of(answer), -32001)
}

///|
async test "server: a context that does not belong to the task is refused" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = task_of(
    result_of(
      server.answer(call_text(1, "SendMessage", send_params("wait", "m-1"))),
    ),
  )
  let message = "{\"message\":{\"messageId\":\"m-2\",\"role\":\"ROLE_USER\",\"taskId\":\"\{task.id}\",\"contextId\":\"elsewhere\",\"parts\":[{\"text\":\"hi\"}]}}"
  let answer = server.answer(call_text(2, "SendMessage", message))
  assert_eq(error_code_of(answer), -32602)
}

///|
async test "server: a message that names only the task inherits its context" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = task_of(
    result_of(
      server.answer(call_text(1, "SendMessage", send_params("wait", "m-1"))),
    ),
  )
  // "wait" leaves the task interrupted, so it takes another message.
  let message = "{\"message\":{\"messageId\":\"m-2\",\"role\":\"ROLE_USER\",\"taskId\":\"\{task.id}\",\"parts\":[{\"text\":\"hello\"}]}}"
  let continued = task_of(
    result_of(server.answer(call_text(2, "SendMessage", message))),
  )
  assert_eq(continued.id, task.id)
  assert_eq(continued.context_id, task.context_id)
  assert_eq(continued.status.state.wire(), "TASK_STATE_COMPLETED")
  // The history keeps both turns, in the order they happened.
  assert_eq(continued.history.length(), 2)
}

///|
async test "server: an interrupted task accepts another message" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = task_of(
    result_of(
      server.answer(call_text(1, "SendMessage", send_params("wait", "m-1"))),
    ),
  )
  assert_eq(task.status.state.wire(), "TASK_STATE_INPUT_REQUIRED")
  assert_false(task.status.state.terminal())
}

///|
async test "server: a media type the card does not offer is refused when the agent asks for it" {
  let config : @moona2a.ServerConfig = {
    ..@moona2a.ServerConfig::new(),
    refuse_unknown_media: true,
  }
  let server = @moona2a.Server::new(Scripted::{ }, test_card()).under(config)
  let params = "{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[{\"raw\":\"dGNr\",\"mediaType\":\"application/x-nope\"}]}}"
  let answer = server.answer(call_text(1, "SendMessage", params))
  assert_eq(error_code_of(answer), -32005)
}

///|
async test "server: a media type the card offers is accepted" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let params = "{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[{\"raw\":\"dGNr\",\"mediaType\":\"text/plain\"}]}}"
  let answer = server.answer(call_text(1, "SendMessage", params))
  // The agent answers a part with no text with a message; what matters is that the part was
  // accepted rather than refused.
  assert_true(result_of(answer) is Object(_))
}

///|
async test "server: a message with no parts is refused" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let params = "{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[]}}"
  let answer = server.answer(call_text(1, "SendMessage", params))
  assert_eq(error_code_of(answer), -32602)
}

///|
async test "server: a method nobody answers is a method-not-found refusal" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let answer = server.answer(call_text(1, "DeleteEverything", "{}"))
  assert_eq(error_code_of(answer), -32601)
}

///|
async test "server: a body that is not JSON is a parse error" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  assert_eq(error_code_of(server.answer("not json")), -32700)
}

///|
async test "server: a body that is not a JSON-RPC message is an invalid request" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  assert_eq(error_code_of(server.answer("{\"hello\":1}")), -32600)
}
