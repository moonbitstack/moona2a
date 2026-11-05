// A2A end-to-end: an A2AClient whose transport is a real A2AServer.handle, so message/send,
// tasks/get, and tasks/cancel travel the actual JSON-RPC protocol between the two implementations.

///|
/// An executor that completes each request with a task echoing the incoming message.
struct EchoExecutor {}

///|
impl @a2a.AgentExecutor for EchoExecutor with fn execute(_self, context) {
  @a2a.ResultTask({
    id: context.task_id,
    context_id: context.context_id,
    status: {
      state: Completed,
      message: Some(context.message),
      timestamp: None,
    },
    history: None,
    artifacts: None,
    metadata: None,
  })
}

///|
impl @a2a.AgentExecutor for EchoExecutor with fn cancel(_self, task_id) {
  {
    id: task_id,
    context_id: task_id,
    status: { state: Canceled, message: None, timestamp: None, },
    history: None,
    artifacts: None,
    metadata: None,
  }
}

///|
/// A client transport that delivers each request straight into a server's handler.
struct LoopbackTransport {
  server : @a2a.A2AServer
}

///|
impl @a2a.A2ATransport for LoopbackTransport with fn round_trip(self, request) {
  self.server.handle(request)
}

///|
test "a2a e2e: client ↔ server round-trip over the real JSON-RPC handler" {
  let store = @a2a.InMemoryTaskStore::new()
  let server = @a2a.A2AServer::new(EchoExecutor::{ }, store)
  let client = @a2a.A2AClient::new(LoopbackTransport::{ server, })
  let sent = client.send_message(@a2a.Message::user_text("m1", "hi"))
  let task = match sent {
    @a2a.ResultTask(t) => t
    @a2a.ResultMessage(_) => fail("expected a task")
  }
  assert_eq(task.id, "m1")
  assert_eq(task.status.state, @a2a.Completed)
  // The completed task was persisted and is retrievable.
  assert_eq(client.get_task("m1").status.state, @a2a.Completed)
  // Cancelling routes through the executor and updates the store.
  assert_eq(client.cancel_task("m1").status.state, @a2a.Canceled)
}

///|
test "a2a e2e: tasks/get for an unknown task returns a JSON-RPC error the client surfaces" {
  let store = @a2a.InMemoryTaskStore::new()
  let server = @a2a.A2AServer::new(EchoExecutor::{ }, store)
  let client = @a2a.A2AClient::new(LoopbackTransport::{ server, })
  let failed = try {
    client.get_task("nope") |> ignore
    false
  } catch {
    _ => true
  }
  assert_eq(failed, true)
}
