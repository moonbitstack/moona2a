// A2A: round-trip the message/task model through its JSON wire form, and drive the client's
// message/send, tasks/get, and tasks/cancel over a mock JSON-RPC transport.

///|
/// A transport answering each A2A method from a canned result.
struct MockA2A {
  send_result : Json
  get_result : Json
  cancel_result : Json
}

///|
impl @a2a.A2ATransport for MockA2A with fn round_trip(self, request) {
  let rpc_method = match request {
    Object(o) =>
      match o.get("method") {
        Some(String(m)) => m
        _ => ""
      }
    _ => ""
  }
  let result = match rpc_method {
    "message/send" => self.send_result
    "tasks/get" => self.get_result
    "tasks/cancel" => self.cancel_result
    _ => Json::object({})
  }
  { "jsonrpc": "2.0", "id": Json::number(1.0), "result": result }
}

///|
test "a2a model: a message with text, file and data parts round-trips through its wire form" {
  let message : @a2a.Message = {
    message_id: "m1",
    role: Agent,
    parts: [
      TextPart("hello"),
      FilePart(FileBytes(bytes="AAAA", name=Some("a.bin"), mime_type=None)),
      FilePart(
        FileUri(uri="https://x/y", name=None, mime_type=Some("text/plain")),
      ),
      DataPart({ "k": "v" }),
    ],
    extensions: Some(["ext-1"]),
    task_id: Some("t1"),
    reference_task_ids: None,
    context_id: Some("c1"),
    metadata: None,
  }
  assert_eq(@a2a.Message::from_json(message.to_json()), message)
}

///|
test "a2a model: a task round-trips, and TaskState terminal/wire agree" {
  let task : @a2a.Task = {
    id: "t1",
    context_id: "c1",
    status: {
      state: InputRequired,
      message: Some(@a2a.Message::user_text("m1", "need input")),
      timestamp: Some("2026-07-31T00:00:00Z"),
    },
    history: Some([@a2a.Message::user_text("m0", "start")]),
    artifacts: Some([
      {
        artifact_id: "a1",
        name: Some("out"),
        description: None,
        parts: [TextPart("done")],
        extensions: None,
        metadata: None,
      },
    ]),
    metadata: None,
  }
  assert_eq(@a2a.Task::from_json(task.to_json()), task)
  assert_eq((@a2a.Completed : @a2a.TaskState).terminal(), true)
  assert_eq((@a2a.Working : @a2a.TaskState).terminal(), false)
  assert_eq(@a2a.TaskState::from_wire("input-required"), @a2a.InputRequired)
  assert_eq((@a2a.InputRequired : @a2a.TaskState).wire(), "input-required")
}

///|
test "a2a client: message/send resolves a Task, tasks/get and tasks/cancel return updated state" {
  let working_task : @a2a.Task = {
    id: "t9",
    context_id: "c9",
    status: { state: Working, message: None, timestamp: None, },
    history: None,
    artifacts: None,
    metadata: None,
  }
  let canceled = @json.parse(
    (
      #|{ "kind": "task", "id": "t9", "contextId": "c9",
      #|  "status": { "state": "canceled" } }
    ),
  )
  let transport = MockA2A::{
    send_result: working_task.to_json(),
    get_result: working_task.to_json(),
    cancel_result: canceled,
  }
  let client = @a2a.A2AClient::new(transport)
  let sent = client.send_message(@a2a.Message::user_text("m1", "go"))
  assert_eq(sent, @a2a.ResultTask(working_task))
  assert_eq(client.get_task("t9").status.state, @a2a.Working)
  assert_eq(client.cancel_task("t9").status.state, @a2a.Canceled)
}

///|
test "a2a client: a direct message reply resolves to ResultMessage" {
  let reply = @json.parse(
    (
      #|{ "kind": "message", "messageId": "r1", "role": "agent",
      #|  "parts": [ { "kind": "text", "text": "hi" } ] }
    ),
  )
  let transport = MockA2A::{
    send_result: reply,
    get_result: Json::object({}),
    cancel_result: Json::object({}),
  }
  let client = @a2a.A2AClient::new(transport)
  match client.send_message(@a2a.Message::user_text("m1", "go")) {
    ResultMessage(m) => {
      assert_eq(m.message_id, "r1")
      assert_eq(m.role, @a2a.Agent)
      assert_eq(m.parts, [TextPart("hi")])
    }
    ResultTask(_) => fail("expected a message reply")
  }
}
