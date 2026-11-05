// A2A streaming: the event stream reads the way an EventSource dispatches it, and the streaming
// client turns an SSE body of JSON-RPC frames into typed StreamEvents through an injectable event
// source.

///|
/// An event source returning a canned SSE body.
struct MockEventStream {
  body : String
}

///|
impl @a2a.EventStream for MockEventStream with fn open_stream(self, _request) {
  self.body
}

///|
test "sse: comments dropped, event types kept, multi-line data joined, the id persisted" {
  let stream =
    #|: this is a comment
    #|event: status
    #|data: {"a":1}
    #|
    #|data: line1
    #|data: line2
    #|
    #|id: 42
    #|event: done
    #|data: bye
    #|
  let events = @sse.events(stream)
  assert_eq(events.length(), 3)
  assert_eq(events[0], @sse.Event::new(data="{\"a\":1}", kind="status"))
  assert_eq(events[1], @sse.Event::new(data="line1\nline2", kind="message"))
  assert_eq(events[2], @sse.Event::new(data="bye", kind="done", id="42"))
}

///|
test "a2a streaming: message/stream yields typed status-update events, ending on final" {
  let body =
    #|data: {"jsonrpc":"2.0","id":1,"result":{"kind":"status-update","taskId":"t","contextId":"c","status":{"state":"working"},"final":false}}
    #|
    #|data: {"jsonrpc":"2.0","id":1,"result":{"kind":"status-update","taskId":"t","contextId":"c","status":{"state":"completed"},"final":true}}
    #|
  let events = @a2a.stream_message(
    MockEventStream::{ body, },
    @a2a.Message::user_text("m1", "go"),
  )
  assert_eq(events.length(), 2)
  match events[0] {
    @a2a.StreamStatusUpdate(e) => {
      assert_eq(e.status.state, @a2a.Working)
      assert_eq(e.is_final, false)
    }
    _ => fail("expected a status-update")
  }
  match events[1] {
    @a2a.StreamStatusUpdate(e) => {
      assert_eq(e.status.state, @a2a.Completed)
      assert_eq(e.is_final, true)
    }
    _ => fail("expected a status-update")
  }
}

///|
test "a2a streaming: status-update and artifact-update events round-trip" {
  let status : @a2a.TaskStatusUpdateEvent = {
    task_id: "t",
    context_id: "c",
    status: { state: Working, message: None, timestamp: None, },
    is_final: false,
    metadata: None,
  }
  assert_eq(@a2a.TaskStatusUpdateEvent::from_json(status.to_json()), status)
  let artifact : @a2a.TaskArtifactUpdateEvent = {
    task_id: "t",
    context_id: "c",
    artifact: {
      artifact_id: "a1",
      name: Some("out"),
      description: None,
      parts: [TextPart("chunk")],
      extensions: None,
      metadata: None,
    },
    append: Some(true),
    last_chunk: Some(false),
    metadata: None,
  }
  assert_eq(
    @a2a.TaskArtifactUpdateEvent::from_json(artifact.to_json()),
    artifact,
  )
}
