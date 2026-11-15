// The gRPC binding driven without a socket: the handlers it registers, called with a context
// and a responder, and their answers read back through `a2a.proto`.

///|
/// A registrar that keeps what is registered on it.
struct Table {
  handlers : Map[String, @stream.Handler]
}

///|
impl @stream.Registrar for Table with fn register_handler(self, path, handler) {
  self.handlers[path] = handler
}

///|
/// An agent that works every message to the end in two steps.
struct Echo {}

///|
impl @moona2a.Executor for Echo with fn execute(self, ctx, out) {
  ignore(self)
  out.emit(ctx.status(@moona2a.Working))
  out.emit(ctx.status(@moona2a.Completed))
}

///|
impl @moona2a.Executor for Echo with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
/// A server registered on a fresh table.
fn table_of() -> Table {
  let card = @moona2a.AgentCard::new(
    "tester",
    "an agent for tests",
    "1.0.0",
    "http://127.0.0.1:8000",
    [],
  ).capable(@moona2a.AgentCapabilities::streaming_and_push())
  let table = Table::{ handlers: Map([]), }
  @grpc.register(table, @moona2a.Server::new(Echo::{ }, card))
  table
}

///|
/// What one call came to: the messages sent, the status it failed with, and its details.
struct Outcome {
  replies : Array[Bytes]
  failed : (Int32, String)?
  details : Array[Bytes]
}

///|
/// Call `rpc` with `request`, under the version header a 1.0 client sends unless told otherwise.
async fn call(
  table : Table,
  rpc : @moona2a.Method,
  request : Bytes,
  metadata? : Array[@header.Header],
) -> Outcome {
  guard table.handlers.get(rpc.grpc_path()) is Some(Pushed(handler)) else {
    abort("\{rpc.name()} is not registered as a pushed handler")
  }
  let ctx = {
    ..@stream.RpcContext::empty(),
    metadata: metadata.unwrap_or([{ name: b"a2a-version", value: b"1.0", }]),
  }
  let replies : Array[Bytes] = []
  handler(ctx, [request], {
    send: messages => replies.append(messages),
    finish: () => (),
  })
  { replies, failed: ctx.status_fail, details: ctx.error_details, }
}

///|
/// A `SendMessageRequest` of one text message, in its binary form.
fn send_request(message_id : String) -> Bytes raise {
  @grpc.encode(
    "lf.a2a.v1.SendMessageRequest",
    @moonjson.loads(
      "{\"message\":{\"messageId\":\"\{message_id}\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"hi\"}]}}",
      @moonjson.strict,
    ),
  )
}

///|
/// A field of an object, or a failure naming it.
fn field(json : Json, name : String) -> Json raise {
  guard json is Object(fields) && fields.get(name) is Some(value) else {
    fail("no \{name} in \{@moonjson.dumps(json)}")
  }
  value
}

///|
/// What kind of event a `StreamResponse` is: the task, or the state a status update moves to.
fn kind_of(reply : Json) -> String {
  guard reply is Object(fields) else { return "other" }
  if fields.get("task") is Some(_) {
    return "task"
  }
  if fields.get("statusUpdate") is Some(Object(update)) &&
    update.get("status") is Some(Object(status)) &&
    status.get("state") is Some(String(state)) {
    return state
  }
  "other"
}

///|
test "grpc: every method of A2AService is registered at its path" {
  let table = table_of()
  assert_eq(table.handlers.length(), 11)
  assert_true(
    table.handlers.get("/lf.a2a.v1.A2AService/SendStreamingMessage") is Some(_),
  )
}

///|
test "grpc: every method's types are the ones a2a.proto declares" {
  assert_eq(
    @grpc.types_of(SendMessage),
    ("lf.a2a.v1.SendMessageRequest", "lf.a2a.v1.SendMessageResponse"),
  )
  assert_eq(
    @grpc.types_of(SubscribeToTask),
    ("lf.a2a.v1.SubscribeToTaskRequest", "lf.a2a.v1.StreamResponse"),
  )
  assert_eq(
    @grpc.types_of(DeletePushConfig),
    (
      "lf.a2a.v1.DeleteTaskPushNotificationConfigRequest", "google.protobuf.Empty",
    ),
  )
}

///|
test "grpc: a task with every kind of part survives the binary form" {
  let text =
    #|{"id":"t1","contextId":"c1","status":{"state":"TASK_STATE_COMPLETED","timestamp":"2025-11-09T10:30:00Z"},"history":[{"messageId":"m1","role":"ROLE_USER","parts":[{"text":"hi"},{"raw":"AAE=","mediaType":"application/octet-stream"},{"url":"https://example.com/a.txt","filename":"a.txt"},{"data":{"k":[1,"x",null]}}]}],"metadata":{"a":true}}
  let json = @moonjson.loads(text, @moonjson.strict)
  let bytes = @grpc.encode("lf.a2a.v1.Task", json)
  assert_eq(@grpc.decode("lf.a2a.v1.Task", bytes), json)
}

///|
async test "grpc: a send answers with a SendMessageResponse holding the finished task" {
  let outcome = call(table_of(), SendMessage, send_request("m-1"))
  assert_true(outcome.failed is None)
  assert_eq(outcome.replies.length(), 1)
  let reply = @grpc.decode("lf.a2a.v1.SendMessageResponse", outcome.replies[0])
  assert_eq(
    field(field(field(reply, "task"), "status"), "state"),
    Json::string("TASK_STATE_COMPLETED"),
  )
}

///|
async test "grpc: an unknown task fails NOT_FOUND with a TASK_NOT_FOUND ErrorInfo" {
  let request = @grpc.encode(
    "lf.a2a.v1.GetTaskRequest",
    Json::object({ "id": Json::string("ghost") }),
  )
  let outcome = call(table_of(), GetTask, request)
  assert_eq(outcome.replies.length(), 0)
  assert_eq(outcome.failed.map(failed => failed.0), Some(5))
  assert_eq(outcome.details.length(), 1)
  let detail = @grpc.decode("google.protobuf.Any", outcome.details[0])
  assert_eq(
    detail,
    Json::object({
      "@type": Json::string("type.googleapis.com/google.rpc.ErrorInfo"),
      "reason": Json::string("TASK_NOT_FOUND"),
      "domain": Json::string("a2a-protocol.org"),
      "metadata": Json::object({ "detail": Json::string("ghost") }),
    }),
  )
}

///|
async test "grpc: a call without a2a-version is refused as a 0.3 client, FAILED_PRECONDITION" {
  let outcome = call(table_of(), SendMessage, send_request("m-2"), metadata=[])
  assert_eq(outcome.failed.map(failed => failed.0), Some(9))
}

///|
async test "grpc: a request that does not read is INVALID_ARGUMENT" {
  let outcome = call(table_of(), SendMessage, b"\xff\xff\xff")
  assert_eq(outcome.failed.map(failed => failed.0), Some(3))
}

///|
async test "grpc: a streaming send answers with StreamResponse messages in the order they happened" {
  let outcome = call(table_of(), SendStreamingMessage, send_request("m-3"))
  assert_true(outcome.failed is None)
  let kinds : Array[String] = []
  for bytes in outcome.replies {
    kinds.push(kind_of(@grpc.decode("lf.a2a.v1.StreamResponse", bytes)))
  }
  assert_eq(kinds, ["task", "TASK_STATE_WORKING", "TASK_STATE_COMPLETED"])
}

///|
async test "grpc: a push configuration is created, then deleted with an Empty answer" {
  let table = table_of()
  let sent = call(table, SendMessage, send_request("m-4"))
  guard sent.replies is [first] else { fail("the send answered nothing") }
  let reply = @grpc.decode("lf.a2a.v1.SendMessageResponse", first)
  guard field(field(reply, "task"), "id") is String(task_id) else {
    fail("no task id")
  }
  let config = @grpc.encode(
    "lf.a2a.v1.TaskPushNotificationConfig",
    Json::object({
      "taskId": Json::string(task_id),
      "id": Json::string("cfg-1"),
      "url": Json::string("https://hook.test/a"),
    }),
  )
  let created = call(table, CreatePushConfig, config)
  assert_true(created.failed is None)
  let deletion = @grpc.encode(
    "lf.a2a.v1.DeleteTaskPushNotificationConfigRequest",
    Json::object({
      "taskId": Json::string(task_id),
      "id": Json::string("cfg-1"),
    }),
  )
  let deleted = call(table, DeletePushConfig, deletion)
  assert_true(deleted.failed is None)
  assert_eq(deleted.replies, [b""])
}

///|
test "grpc: the details of a google.rpc.Status read back with their types" {
  let status = @grpc.encode(
    "google.rpc.Status",
    Json::object({
      "code": Json::number(5.0),
      "message": Json::string("Task not found"),
      "details": Json::array([
        Json::object({
          "@type": Json::string("type.googleapis.com/google.rpc.ErrorInfo"),
          "reason": Json::string("TASK_NOT_FOUND"),
          "domain": Json::string("a2a-protocol.org"),
        }),
      ]),
    }),
  )
  let details = @grpc.details_of(status)
  assert_eq(details.length(), 1)
  assert_eq(field(details[0], "reason"), Json::string("TASK_NOT_FOUND"))
}
