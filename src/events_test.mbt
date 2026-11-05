// A streamed update is one object with one field naming what happened, as `StreamResponse` says.

///|
test "event: a task snapshot travels as the task alone" {
  let task = @moona2a.Task::new("t-1", "c-1")
  let event = @moona2a.StreamEvent::TaskSnapshot(task)
  let json = event.to_json()
  let fields = match json {
    Object(fields) => fields
    _ => fail("an event is not an object")
  }
  assert_true(fields.contains("task"))
  assert_false(fields.contains("statusUpdate"))
  let read : @moona2a.StreamEvent = @json.from_json(json) catch {
    _ => fail("a task event does not read back")
  }
  assert_true(read == event)
}

///|
test "event: a message travels as the message alone" {
  let event = @moona2a.StreamEvent::TaskMessage(
    @moona2a.Message::agent("m-1", "hi"),
  )
  let json = event.to_json()
  let read : @moona2a.StreamEvent = @json.from_json(json) catch {
    _ => fail("a message event does not read back")
  }
  assert_true(read == event)
}

///|
test "event: a status change carries the ids, the status and its timestamp" {
  let event = @moona2a.StreamEvent::StatusChange(
    @moona2a.TaskStatusUpdate::of("t-1", "c-1", @moona2a.Working),
  )
  let json = event.to_json()
  let fields = match json {
    Object(fields) => fields
    _ => fail("an event is not an object")
  }
  let update = match fields.get("statusUpdate") {
    Some(Object(update)) => update
    _ => fail("a status change is not an object")
  }
  assert_eq(field_str(update, "taskId"), Some("t-1"))
  assert_eq(field_str(update, "contextId"), Some("c-1"))
  let status = match update.get("status") {
    Some(Object(status)) => status
    _ => fail("a status change has no status")
  }
  assert_eq(field_str(status, "state"), Some("TASK_STATE_WORKING"))
  assert_true(field_str(status, "timestamp") is Some(_))
  let read : @moona2a.StreamEvent = @json.from_json(json) catch {
    _ => fail("a status change does not read back")
  }
  assert_true(read == event)
}

///|
test "event: an artifact chunk says whether it appends, and whether it is the last" {
  let first = @moona2a.TaskArtifactUpdate::of(
    "t-1",
    "c-1",
    @moona2a.Artifact::text("a-1", "part"),
    append=true,
    last_chunk=false,
  )
  let json = @moona2a.StreamEvent::ArtifactChunk(first).to_json()
  let fields = match json {
    Object(fields) => fields
    _ => fail("an event is not an object")
  }
  let update = match fields.get("artifactUpdate") {
    Some(Object(update)) => update
    _ => fail("an artifact chunk is not an object")
  }
  assert_true(field_bool(update, "append"))
  // A false flag is absent rather than written, which is what ProtoJSON does with a default.
  assert_false(update.contains("lastChunk"))
  let read : @moona2a.StreamEvent = @json.from_json(json) catch {
    _ => fail("an artifact chunk does not read back")
  }
  assert_true(read == @moona2a.StreamEvent::ArtifactChunk(first))
}

///|
test "event: only a terminal state ends a stream" {
  let running = @moona2a.StreamEvent::StatusChange(
    @moona2a.TaskStatusUpdate::of("t-1", "c-1", @moona2a.Working),
  )
  assert_false(running.is_final())
  let done = @moona2a.StreamEvent::StatusChange(
    @moona2a.TaskStatusUpdate::of("t-1", "c-1", @moona2a.Completed),
  )
  assert_true(done.is_final())
  let artifact = @moona2a.StreamEvent::ArtifactChunk(
    @moona2a.TaskArtifactUpdate::of(
      "t-1",
      "c-1",
      @moona2a.Artifact::text("a", "x"),
    ),
  )
  assert_false(artifact.is_final())
}

///|
test "event: an event that names none of the four kinds does not read" {
  let json = @json.parse("{\"something\":{}}") catch {
    _ => fail("the fixture is not JSON")
  }
  let outcome = try {
    let _ : @moona2a.StreamEvent = @json.from_json(json)
    false
  } catch {
    _ => true
  }
  assert_true(outcome)
}
