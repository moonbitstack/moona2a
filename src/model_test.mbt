// The wire model round-trips: what a caller builds comes back the same after a trip through the
// JSON the protocol puts on the wire.

///|
test "part: text survives a round trip" {
  let part = @moona2a.Part::text("hello")
  let read : @moona2a.Part = @json.from_json(part.to_json()) catch {
    _ => fail("a text part does not read back")
  }
  assert_true(read == part)
  assert_eq(read.text_of(), Some("hello"))
}

///|
test "part: bytes travel as base64 and come back whole" {
  let bytes : Bytes = b"a2a!\xff"
  let part = @moona2a.Part::bytes(
    bytes,
    filename="note.txt",
    media_type="text/plain",
  )
  let json = part.to_json()
  let fields = match json {
    Object(fields) => fields
    _ => fail("a part is not an object")
  }
  assert_eq(field_str(fields, "raw"), Some("YTJhIf8="))
  let read : @moona2a.Part = @json.from_json(json) catch {
    _ => fail("a file part does not read back")
  }
  assert_true(read == part)
  assert_eq(read.media_type(), Some("text/plain"))
}

///|
test "part: a url travels as a url, with its name and media type" {
  let part = @moona2a.Part::uri(
    "https://example.test/a.png",
    filename="a.png",
    media_type="image/png",
  )
  let read : @moona2a.Part = @json.from_json(part.to_json()) catch {
    _ => fail("a url part does not read back")
  }
  assert_true(read == part)
}

///|
test "part: structured data keeps its shape" {
  let data = @json.parse("{\"count\":42,\"tags\":[\"a\",\"b\"]}") catch {
    _ => fail("the fixture is not JSON")
  }
  let part = @moona2a.Part::data(data)
  let read : @moona2a.Part = @json.from_json(part.to_json()) catch {
    _ => fail("a data part does not read back")
  }
  assert_true(read == part)
}

///|
test "part: metadata rides along" {
  let metadata = @json.parse("{\"src\":\"unit test\"}") catch {
    _ => fail("the fixture is not JSON")
  }
  let part = @moona2a.Part::text("hi").with_metadata(metadata)
  let read : @moona2a.Part = @json.from_json(part.to_json()) catch {
    _ => fail("a part with metadata does not read back")
  }
  assert_eq(read.metadata, Some(metadata))
}

///|
test "part: a part with no content kind is refused" {
  let json = @json.parse("{\"metadata\":{}}") catch {
    _ => fail("the fixture is not JSON")
  }
  let outcome = try {
    let _ : @moona2a.Part = @json.from_json(json)
    false
  } catch {
    _ => true
  }
  assert_true(outcome)
}

///|
test "message: a message survives a round trip, ids and all" {
  let message = @moona2a.Message::user("m-1", "hello")
  let read : @moona2a.Message = @json.from_json(message.to_json()) catch {
    _ => fail("a message does not read back")
  }
  assert_true(read == message)
  assert_eq(read.role.wire(), "ROLE_USER")
  assert_eq(read.text(), "hello")
}

///|
test "message: a message that continues a task carries both ids" {
  let message = @moona2a.Message::user("m-2", "again").in_task("t-1", "c-1")
  let json = message.to_json()
  let fields = match json {
    Object(fields) => fields
    _ => fail("a message is not an object")
  }
  assert_eq(field_str(fields, "taskId"), Some("t-1"))
  assert_eq(field_str(fields, "contextId"), Some("c-1"))
  let read : @moona2a.Message = @json.from_json(json) catch {
    _ => fail("a message does not read back")
  }
  assert_true(read == message)
}

///|
test "message: the draft's bare role name is understood" {
  let json = @json.parse(
    "{\"messageId\":\"m-1\",\"role\":\"agent\",\"parts\":[{\"text\":\"hi\"}]}",
  ) catch {
    _ => fail("the fixture is not JSON")
  }
  let read : @moona2a.Message = @json.from_json(json) catch {
    _ => fail("a message with a bare role does not read back")
  }
  assert_eq(read.role.wire(), "ROLE_AGENT")
}

///|
test "message: every text part contributes to the text, and nothing else does" {
  let message = @moona2a.Message::new("m-1", @moona2a.Agent, [
    @moona2a.Part::text("one"),
    @moona2a.Part::data(@json.parse("{\"k\":1}") catch { _ => Json::null() }),
    @moona2a.Part::text("two"),
  ])
  assert_eq(message.text(), "onetwo")
}

///|
test "task state: the wire names are the proto names, and the drafts are read too" {
  assert_eq(@moona2a.TaskState::Working.wire(), "TASK_STATE_WORKING")
  assert_eq(
    @moona2a.TaskState::from_wire("TASK_STATE_INPUT_REQUIRED").wire(),
    "TASK_STATE_INPUT_REQUIRED",
  )
  assert_eq(
    @moona2a.TaskState::from_wire("input-required").wire(),
    "TASK_STATE_INPUT_REQUIRED",
  )
  assert_eq(
    @moona2a.TaskState::from_wire("something else").wire(),
    "TASK_STATE_UNSPECIFIED",
  )
}

///|
test "task state: terminal and interrupted are what the specification says" {
  for
    state in [
      @moona2a.Completed,
      @moona2a.Failed,
      @moona2a.Canceled,
      @moona2a.Rejected,
    ] {
    assert_true(state.terminal())
    assert_false(state.interrupted())
  }
  for state in [@moona2a.InputRequired, @moona2a.AuthRequired] {
    assert_true(state.interrupted())
    assert_false(state.terminal())
  }
  for state in [@moona2a.Submitted, @moona2a.Working, @moona2a.Unspecified] {
    assert_false(state.terminal())
    assert_false(state.interrupted())
  }
}

///|
test "task: a task survives a round trip with its history and artifacts" {
  let task = @moona2a.Task::new("t-1", "c-1")
    .saying(@moona2a.Message::user("m-1", "hello"))
    .with_state(@moona2a.Working)
    .taking(@moona2a.Artifact::text("a-1", "done"), false)
    .with_state(@moona2a.Completed)
  let read : @moona2a.Task = @json.from_json(task.to_json()) catch {
    _ => fail("a task does not read back")
  }
  assert_eq(read.id, "t-1")
  assert_eq(read.context_id, "c-1")
  assert_eq(read.status.state.wire(), "TASK_STATE_COMPLETED")
  assert_eq(read.history.length(), 1)
  assert_eq(read.artifacts.length(), 1)
  assert_true(read.status.timestamp is Some(_))
}

///|
test "task: an artifact that is appended to grows in place" {
  let task = @moona2a.Task::new("t-1", "c-1")
    .taking(@moona2a.Artifact::text("a-1", "first"), false)
    .taking(@moona2a.Artifact::text("a-1", "second"), true)
  assert_eq(task.artifacts.length(), 1)
  assert_eq(task.artifacts[0].text_of(), "firstsecond")
}

///|
test "task: an artifact replaced keeps only the new parts" {
  let task = @moona2a.Task::new("t-1", "c-1")
    .taking(@moona2a.Artifact::text("a-1", "first"), false)
    .taking(@moona2a.Artifact::text("a-1", "second"), false)
  assert_eq(task.artifacts.length(), 1)
  assert_eq(task.artifacts[0].text_of(), "second")
}

///|
test "task: a history asked for the last n messages gives exactly those" {
  let task = @moona2a.Task::new("t-1", "c-1")
    .saying(@moona2a.Message::user("m-1", "one"))
    .saying(@moona2a.Message::user("m-2", "two"))
    .saying(@moona2a.Message::user("m-3", "three"))
  assert_eq(task.recent(None).length(), 3)
  assert_eq(task.recent(Some(2)).length(), 2)
  assert_eq(task.recent(Some(2))[0].text(), "two")
  assert_eq(task.recent(Some(0)).length(), 0)
  assert_eq(task.recent(Some(10)).length(), 3)
}

///|
test "task: a bare view keeps the artifacts out" {
  let task = @moona2a.Task::new("t-1", "c-1").taking(
    @moona2a.Artifact::text("a-1", "done"),
    false,
  )
  let json = task.encode(view=@moona2a.View::bare())
  let fields = match json {
    Object(fields) => fields
    _ => fail("a task is not an object")
  }
  assert_false(fields.contains("artifacts"))
  assert_true(fields.contains("status"))
}

///|
test "artifact: a name and a description survive a round trip" {
  let artifact = @moona2a.Artifact::text("a-1", "done").named("report")
  let read : @moona2a.Artifact = @json.from_json(artifact.to_json()) catch {
    _ => fail("an artifact does not read back")
  }
  assert_true(read == artifact)
  assert_eq(read.name, Some("report"))
}
