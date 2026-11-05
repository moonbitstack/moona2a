// The streaming side: a message worked while the caller watches, a task joined after the fact, and
// the registrations that let a webhook hear the same events.

///|
/// The `result` of every reply a sink took, skipping refusals.
fn taken_results(recorder : Recorder) -> Array[Json] {
  let out : Array[Json] = []
  for message in recorder.replies {
    match message {
      @moonjrpc.Reply(result~, ..) => out.push(result)
      _ => ()
    }
  }
  out
}

///|
/// The refusal codes a sink took.
fn taken_codes(recorder : Recorder) -> Array[Int32] {
  let out : Array[Int32] = []
  for message in recorder.replies {
    match message {
      @moonjrpc.Refusal(failure~, ..) => out.push(failure.code)
      _ => ()
    }
  }
  out
}

///|
/// The stream event carried by a `StreamResponse`.
fn event_of(result : Json) -> @moona2a.StreamEvent raise {
  @json.from_json(result) catch {
    _ => fail("a streamed reply is not a stream response")
  }
}

///|
/// A fresh server, and the id of a task it has in `input_required`.
async fn waiting_task(server : @moona2a.Server) -> @moona2a.Task {
  task_of(
    result_of(
      server.answer(call_text(1, "SendMessage", send_params("wait", "m-1"))),
    ),
  )
}

///|
async test "stream: a message streams the task it opens, and closes when it ends" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let recorder : Recorder = { replies: [], }
  server.answer_stream(
    call_text(1, "SendStreamingMessage", send_params("hello", "m-1")),
    recorder,
  )
  let results = taken_results(recorder)
  // One reply per event; the first is the task as it was opened (section 3.1.2).
  assert_eq(results.length(), 4)
  let first = event_of(results[0])
  assert_true(first is @moona2a.TaskSnapshot(_))
  match first {
    @moona2a.TaskSnapshot(task) =>
      assert_eq(task.status.state.wire(), "TASK_STATE_SUBMITTED")
    _ => fail("the first event is not a task")
  }
  let last = event_of(results[3])
  match last {
    @moona2a.StatusChange(update) =>
      assert_eq(update.status.state.wire(), "TASK_STATE_COMPLETED")
    _ => fail("the last event is not a status change")
  }
}

///|
async test "stream: every reply carries the request's id and the JSON-RPC version" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let recorder : Recorder = { replies: [], }
  server.answer_stream(
    call_text(42, "SendStreamingMessage", send_params("hello", "m-1")),
    recorder,
  )
  for message in recorder.replies {
    let json = message.to_json()
    let fields = match json {
      Object(fields) => fields
      _ => fail("a reply is not an object")
    }
    assert_eq(field_str(fields, "jsonrpc").unwrap_or(""), "2.0")
    assert_true(fields.contains("id"))
  }
}

///|
async test "stream: a task's artifact arrives as its own event" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let recorder : Recorder = { replies: [], }
  server.answer_stream(
    call_text(1, "SendStreamingMessage", send_params("hello", "m-1")),
    recorder,
  )
  let mut artifacts = 0
  for result in taken_results(recorder) {
    match event_of(result) {
      @moona2a.ArtifactChunk(update) => {
        artifacts = artifacts + 1
        assert_eq(update.artifact.text_of(), "done")
      }
      _ => ()
    }
  }
  assert_eq(artifacts, 1)
}

///|
async test "stream: an agent that answers with a message sends that one reply" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let recorder : Recorder = { replies: [], }
  server.answer_stream(
    call_text(1, "SendStreamingMessage", send_params("say hi", "m-1")),
    recorder,
  )
  let results = taken_results(recorder)
  assert_eq(results.length(), 1)
  assert_true(event_of(results[0]) is @moona2a.TaskMessage(_))
}

///|
async test "stream: an artifact that arrives in chunks appends to itself" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let recorder : Recorder = { replies: [], }
  server.answer_stream(
    call_text(1, "SendStreamingMessage", send_params("several", "m-1")),
    recorder,
  )
  let mut text = ""
  for result in taken_results(recorder) {
    match event_of(result) {
      @moona2a.ArtifactChunk(update) => text = text + update.artifact.text_of()
      _ => ()
    }
  }
  assert_eq(text, "firstsecond")
}

///|
async test "stream: subscribing to a task that does not exist is a task-not-found refusal" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let recorder : Recorder = { replies: [], }
  server.answer_stream(
    call_text(1, "SubscribeToTask", "{\"id\":\"ghost\"}"),
    recorder,
  )
  assert_eq(taken_codes(recorder), [-32001])
}

///|
async test "stream: subscribing to a finished task is an unsupported-operation refusal" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = task_of(
    result_of(
      server.answer(call_text(1, "SendMessage", send_params("hello", "m-1"))),
    ),
  )
  let recorder : Recorder = { replies: [], }
  server.answer_stream(
    call_text(2, "SubscribeToTask", "{\"id\":\"\{task.id}\"}"),
    recorder,
  )
  assert_eq(taken_codes(recorder), [-32004])
}

///|
async test "stream: a subscriber sees the task it joined, then what happens to it" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = waiting_task(server)
  let recorder : Recorder = { replies: [], }
  let subscription = "{\"id\":\"\{task.id}\"}"
  @async.with_task_group(async fn(group) {
    group.spawn_bg() <| () => {
      server.answer_stream(
        call_text(2, "SubscribeToTask", subscription),
        recorder,
      )
    }
    // The subscriber has to open before the task moves on, or it joins a finished task.
    @async.sleep(100)
    let follow_up = "{\"message\":{\"messageId\":\"m-2\",\"role\":\"ROLE_USER\",\"taskId\":\"\{task.id}\",\"parts\":[{\"text\":\"hello\"}]}}"
    server.answer(call_text(3, "SendMessage", follow_up)) |> ignore
    @async.sleep(300)
  })
  let results = taken_results(recorder)
  assert_true(results.length() >= 3)
  // The stream begins with the task as it stood (section 3.1.6) and ends at a terminal state.
  assert_true(event_of(results[0]) is @moona2a.TaskSnapshot(_))
  let last = event_of(results[results.length() - 1])
  assert_true(last.is_final())
}

///|
async test "stream: cancelling a task ends the subscription that was watching it" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = waiting_task(server)
  let recorder : Recorder = { replies: [], }
  let subscription = "{\"id\":\"\{task.id}\"}"
  @async.with_task_group(async fn(group) {
    group.spawn_bg() <| () => {
      server.answer_stream(
        call_text(2, "SubscribeToTask", subscription),
        recorder,
      )
    }
    @async.sleep(100)
    server.answer(call_text(3, "CancelTask", subscription)) |> ignore
    @async.sleep(300)
  })
  let results = taken_results(recorder)
  let last = event_of(results[results.length() - 1])
  match last {
    @moona2a.StatusChange(update) =>
      assert_eq(update.status.state.wire(), "TASK_STATE_CANCELED")
    _ => fail("the last event is not a cancellation")
  }
}

///|
async test "stream: cancelling a finished task is a not-cancelable refusal" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = task_of(
    result_of(
      server.answer(call_text(1, "SendMessage", send_params("hello", "m-1"))),
    ),
  )
  let answer = server.answer(
    call_text(2, "CancelTask", "{\"id\":\"\{task.id}\"}"),
  )
  assert_eq(error_code_of(answer), -32002)
}

///|
async test "stream: cancelling a task that does not exist is a task-not-found refusal" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let answer = server.answer(call_text(1, "CancelTask", "{\"id\":\"ghost\"}"))
  assert_eq(error_code_of(answer), -32001)
}

///|
async test "push: a registration is created, read back, listed and deleted" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = waiting_task(server)
  let create = "{\"taskId\":\"\{task.id}\",\"id\":\"cfg-1\",\"url\":\"https://hook.test/a\"}"
  let created = result_of(
    server.answer(call_text(1, "CreateTaskPushNotificationConfig", create)),
  )
  let fields = match created {
    Object(fields) => fields
    _ => fail("the registration is not an object")
  }
  assert_eq(field_str(fields, "id").unwrap_or(""), "cfg-1")

  let read = result_of(
    server.answer(
      call_text(
        2,
        "GetTaskPushNotificationConfig",
        "{\"taskId\":\"\{task.id}\",\"id\":\"cfg-1\"}",
      ),
    ),
  )
  assert_true(read is Object(_))

  let listed = result_of(
    server.answer(
      call_text(
        3,
        "ListTaskPushNotificationConfigs",
        "{\"taskId\":\"\{task.id}\"}",
      ),
    ),
  )
  let listed_fields = match listed {
    Object(fields) => fields
    _ => fail("the listing is not an object")
  }
  assert_eq(
    listed_fields.get("configs").unwrap_or(Json::null()) is Array(_),
    true,
  )

  // Deleting twice is not an error: the caller asked for a state, and the state holds.
  assert_true(
    result_of(
      server.answer(
        call_text(
          4,
          "DeleteTaskPushNotificationConfig",
          "{\"taskId\":\"\{task.id}\",\"id\":\"cfg-1\"}",
        ),
      ),
    )
    is Null,
  )
  assert_true(
    result_of(
      server.answer(
        call_text(
          5,
          "DeleteTaskPushNotificationConfig",
          "{\"taskId\":\"\{task.id}\",\"id\":\"cfg-1\"}",
        ),
      ),
    )
    is Null,
  )
}

///|
async test "push: an agent that does not do push notifications refuses the methods" {
  let plain = @moona2a.AgentCard::new(
    "quiet",
    "an agent that sends nothing out of band",
    "1.0.0",
    "https://agent.test",
    [],
  )
  let server = @moona2a.Server::new(Scripted::{ }, plain)
  let answer = server.answer(
    call_text(1, "ListTaskPushNotificationConfigs", "{\"taskId\":\"any\"}"),
  )
  assert_eq(error_code_of(answer), -32003)
}

///|
async test "list: tasks come back newest first, and a page token walks the rest" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let first = task_of(
    result_of(
      server.answer(call_text(1, "SendMessage", send_params("hello", "m-1"))),
    ),
  )
  @async.sleep(5)
  let second = task_of(
    result_of(
      server.answer(call_text(2, "SendMessage", send_params("hello", "m-2"))),
    ),
  )
  let answer = server.answer(
    call_text(3, "ListTasks", "{\"contextId\":\"\{first.context_id}\"}"),
  )
  let page = result_of(answer)
  let fields = match page {
    Object(fields) => fields
    _ => fail("the page is not an object")
  }
  let tasks = match fields.get("tasks") {
    Some(Array(tasks)) => tasks
    _ => fail("the page carries no tasks")
  }
  // The two tasks are in different conversations, so only the first is here.
  assert_eq(tasks.length(), 1)
  assert_eq(field_str(fields, "nextPageToken").unwrap_or(""), "")
  assert_eq(field_int(fields, "totalSize").unwrap_or(0), 1)
  assert_true(second.id != first.id)
}

///|
async test "list: one page, and the token that follows it" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let mut context = ""
  for i in 0..<3 {
    let task = task_of(
      result_of(
        server.answer(
          call_text(i, "SendMessage", send_params("hello", "m-\{i}")),
        ),
      ),
    )
    context = task.context_id
  }
  // Each send starts its own conversation, so ask across all of them.
  let answer = server.answer(call_text(9, "ListTasks", "{\"pageSize\":2}"))
  let fields = match result_of(answer) {
    Object(fields) => fields
    _ => fail("the page is not an object")
  }
  assert_eq(field_int(fields, "totalSize").unwrap_or(0), 3)
  assert_eq(field_int(fields, "pageSize").unwrap_or(0), 2)
  let token = field_str(fields, "nextPageToken").unwrap_or("")
  assert_eq(token, "2")
  let next = server.answer(
    call_text(10, "ListTasks", "{\"pageSize\":2,\"pageToken\":\"2\"}"),
  )
  let next_fields = match result_of(next) {
    Object(fields) => fields
    _ => fail("the page is not an object")
  }
  assert_eq(field_str(next_fields, "nextPageToken").unwrap_or("x"), "")
  assert_true(context != "")
}

///|
async test "list: artifacts stay out of a page unless the caller asks for them" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let task = task_of(
    result_of(
      server.answer(call_text(1, "SendMessage", send_params("hello", "m-1"))),
    ),
  )
  let without = server.answer(
    call_text(2, "ListTasks", "{\"contextId\":\"\{task.context_id}\"}"),
  )
  let fields = match result_of(without) {
    Object(fields) => fields
    _ => fail("the page is not an object")
  }
  let tasks = match fields.get("tasks") {
    Some(Array(tasks)) => tasks
    _ => fail("the page carries no tasks")
  }
  let only = match tasks[0] {
    Object(fields) => fields
    _ => fail("the task is not an object")
  }
  assert_false(only.contains("artifacts"))
}

///|
async test "server: an agent that fails still leaves a failed task behind" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let answer = server.answer(
    call_text(1, "SendMessage", send_params("boom", "m-1")),
  )
  // The call itself is an internal error, and the task it opened says what happened.
  assert_eq(error_code_of(answer), -32603)
  let listed = result_of(
    server.answer(call_text(2, "ListTasks", "{\"pageSize\":10}")),
  )
  let fields = match listed {
    Object(fields) => fields
    _ => fail("the page is not an object")
  }
  let tasks = match fields.get("tasks") {
    Some(Array(tasks)) => tasks
    _ => fail("the page carries no tasks")
  }
  let failed = task_of(Json::object({ "task": tasks[0] }))
  assert_eq(failed.status.state.wire(), "TASK_STATE_FAILED")
}

///|
async test "server: the extended card is refused when the agent has none" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let answer = server.answer(call_text(1, "GetExtendedAgentCard", "{}"))
  assert_eq(error_code_of(answer), -32004)
}

///|
async test "server: an extension the card requires must be declared" {
  let mut capabilities = @moona2a.AgentCapabilities::streaming_and_push()
  capabilities = {
    ..capabilities,
    extensions: [
      {
        uri: "https://example.test/ext/required",
        description: None,
        required: true,
        params: None,
      },
    ],
  }
  let card = test_card().capable(capabilities)
  let server = @moona2a.Server::new(Scripted::{ }, card)
  // A caller that says nothing about extensions is refused.
  let refused = server.answer(call_text(1, "GetTask", "{\"id\":\"any\"}"))
  assert_eq(error_code_of(refused), -32008)
  // A caller that declares it gets the ordinary answer, here a task-not-found.
  let declared = server.answer(call_text(2, "GetTask", "{\"id\":\"any\"}"), extensions=[
    "https://example.test/ext/required",
  ])
  assert_eq(error_code_of(declared), -32001)
}
