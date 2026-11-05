///|
/// An executor that completes each request with a task echoing the message.
struct Echo {}

///|
impl @moona2a.AgentExecutor for Echo with fn execute(_self, ctx) {
  @moona2a.ResultTask({
    id: ctx.task_id,
    context_id: ctx.context_id,
    status: { state: Completed, message: Some(ctx.message), timestamp: None, },
    history: None,
    artifacts: None,
    metadata: None,
  })
}

///|
impl @moona2a.AgentExecutor for Echo with fn cancel(_self, task_id) {
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
struct Loopback {
  server : @moona2a.A2AServer
}

///|
impl @moona2a.A2ATransport for Loopback with fn round_trip(self, request) {
  self.server.handle(request)
}

///|
/// An event source returning a fixed SSE body.
struct SseSource {
  body : String
}

///|
impl @moona2a.EventStream for SseSource with fn open_stream(self, _request) {
  self.body
}

///|
fn show_stream_event(ev : @moona2a.StreamEvent) -> String {
  match ev {
    StreamStatusUpdate(e) =>
      "status=" + e.status.state.wire() + " final=" + e.is_final.to_string()
    StreamTask(t) => "task=" + t.id
    StreamMessage(m) => "message=" + m.message_id
    StreamArtifactUpdate(e) => "artifact=" + e.artifact.artifact_id
  }
}

///|
/// The A2A JSON-RPC protocol end to end: an `A2AClient` whose transport is a real
/// `A2AServer` over an `AgentExecutor` and a task store. `message/send`, `tasks/get`,
/// `tasks/cancel`, and the push-notification config methods travel the actual
/// protocol; `@sse.events` reads a raw event stream and `stream_message` turns
/// JSON-RPC frames into typed `StreamEvent`s.
///
///     moon run examples/25-a2a-protocol --target native
#coverage.skip
fn main {
  let server = @moona2a.A2AServer::new(Echo::{ }, @moona2a.InMemoryTaskStore::new())
  let client = @moona2a.A2AClient::new(Loopback::{ server, })
  try {
    // message/send resolves to a completed task, which the store persists.
    match client.send_message(@moona2a.Message::user_text("m1", "hello")) {
      ResultTask(t) =>
        println("send -> task " + t.id + " state=" + t.status.state.wire())
      ResultMessage(m) => println("send -> message " + m.message_id)
    }
    println("get_task(m1) state = " + client.get_task("m1").status.state.wire())
    println(
      "cancel_task(m1) state = " + client.cancel_task("m1").status.state.wire(),
    )

    // Push-notification config: set, get, list, delete.
    let cfg : @moona2a.TaskPushConfig = {
      task_id: "m1",
      config: {
        id: Some("cfg-1"),
        url: "https://callback.example/hook",
        token: Some("heke1228"),
        authentication: None,
      },
    }
    let _ = client.set_push_config(cfg)
    println(
      "push set: id=" +
      client.get_push_config("m1", config_id="cfg-1").config.url,
    )
    println("push list: \{client.list_push_configs("m1").length()} config(s)")
    client.delete_push_config("m1", "cfg-1")
    println(
      "after delete: \{client.list_push_configs("m1").length()} config(s)",
    )
  } catch {
    e => println("protocol error: " + e.to_string())
  }

  // The event stream on its own: comments dropped, multi-line data joined, id kept.
  let raw =
    #|: a comment
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
  let events = @sse.events(raw)
  println("@sse.events -> \{events.length()} events")
  for e in events {
    let kind = e.kind.unwrap_or("message")
    let id = e.id.unwrap_or("-")
    println("  event=" + kind + " id=" + id + " data=" + e.data)
  }

  // Streaming: JSON-RPC status-update frames become typed events.
  let body =
    #|data: {"jsonrpc":"2.0","id":1,"result":{"kind":"status-update","taskId":"t","contextId":"c","status":{"state":"working"},"final":false}}
    #|
    #|data: {"jsonrpc":"2.0","id":1,"result":{"kind":"status-update","taskId":"t","contextId":"c","status":{"state":"completed"},"final":true}}
    #|
  try {
    let stream = @moona2a.stream_message(
      SseSource::{ body, },
      @moona2a.Message::user_text("m2", "go"),
    )
    println("stream_message -> \{stream.length()} events")
    for ev in stream {
      println("  " + show_stream_event(ev))
    }
  } catch {
    e => println("stream error: " + e.to_string())
  }
}
