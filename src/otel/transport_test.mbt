// The other side of the same wire: a call is a client span, a streamed answer puts
// every event on it, and a refusal is the error the caller gets.

///|
/// A transport that answers from a table, the way a test's does.
struct Remote {
  answers : Map[String, Json]
  card : Json
}

///|
impl @moona2a.Transport for Remote with fn exchange(self, message) {
  match message {
    @moonjrpc.Call(id~, name~, ..) =>
      match self.answers.get(name) {
        Some(result) => @moonjrpc.Message::Reply(id~, result~)
        None =>
          @moonjrpc.Message::Refusal(id~, failure={
            code: -32001,
            message: "Task not found",
            data: None,
          })
      }
    _ => @moonjrpc.Message::unreadable()
  }
}

///|
impl @moona2a.Transport for Remote with fn stream(self, message, out) {
  ignore(self)
  match message {
    @moonjrpc.Call(id~, ..) => {
      let task = @moona2a.Task::new("t-1", "c-1")
      for
        event in [
          @moona2a.StreamEvent::TaskSnapshot(task),
          @moona2a.StreamEvent::StatusChange(
            @moona2a.TaskStatusUpdate::of("t-1", "c-1", @moona2a.Completed),
          ),
        ] {
        out.reply(@moonjrpc.Message::Reply(id~, result=event.to_json()))
      }
    }
    _ => ()
  }
}

///|
impl @moona2a.Transport for Remote with fn discover(self) {
  self.card
}

///|
pub extend Remote with @moona2a.Transport::{exchange, stream, discover}

///|
/// A transport that refuses one method and answers nothing else.
fn remote(answers : Map[String, Json]) -> Remote {
  let card = summariser_card()
  { answers, card: card.to_json(), }
}

///|
/// A reply sink that keeps the replies it was handed.
struct Kept {
  replies : Array[@moonjrpc.Message]
}

///|
impl @moona2a.ReplySink for Kept with fn reply(self, message) {
  self.replies.push(message)
}

///|
async test "otel: a call is a client span named for the method it calls" {
  let sink = @trace.Recorder::new()
  let task = @moona2a.Task::new("t-1", "c-1")
  let transport = remote(map_of([("GetTask", task.to_json())]))
  let client = @moona2a.Client::new(tracing(sink).calling(transport))
  client.get_task("t-1") |> ignore
  let span = span_at(sink.spans(), 0)
  assert_eq(span.name, "a2a.call")
  assert_eq(span.kind, @trace.Client)
  assert_eq(text_attribute_of(span, "a2a.method"), Some("GetTask"))
  assert_eq(text_attribute_of(span, "gen_ai.agent.name"), Some("summariser"))
  assert_eq(span.status, @trace.Ok)
}

///|
async test "otel: sending a message is an agent invocation, on this side too" {
  let sink = @trace.Recorder::new()
  let task = @moona2a.Task::new("t-1", "c-1")
  let transport = remote(
    map_of([("SendMessage", Json::object({ "task": task.to_json() }))]),
  )
  let client = @moona2a.Client::new(tracing(sink).calling(transport))
  client.send_message(@moona2a.Message::user("m-1", "summarise this")) |> ignore
  let span = span_at(sink.spans(), 0)
  assert_eq(span.name, "invoke_agent summariser")
  assert_eq(span.kind, @trace.Client)
  assert_eq(
    text_attribute_of(span, "gen_ai.operation.name"),
    Some("invoke_agent"),
  )
  assert_eq(attribute_of(span, "gen_ai.input.messages"), None)
}

///|
async test "otel: a streamed answer is one span with an event per frame" {
  let sink = @trace.Recorder::new()
  let client = @moona2a.Client::new(tracing(sink).calling(remote(Map([]))))
  let kept : Kept = { replies: [], }
  client.send_streaming_message(@moona2a.Message::user("m-1", "hi"), kept)
  assert_eq(kept.replies.length(), 2)
  let span = span_at(sink.spans(), 0)
  assert_eq(span.name, "invoke_agent summariser")
  assert_eq(span.kind, @trace.Client)
  assert_eq(event_names(span), ["a2a.task.status", "a2a.task.status"])
  assert_eq(
    text_attribute_of(span, "a2a.task.state"),
    Some("TASK_STATE_COMPLETED"),
  )
  assert_eq(span.status, @trace.Ok)
}

///|
async test "otel: a refused call is an error span, and still the caller's error" {
  let sink = @trace.Recorder::new()
  let client = @moona2a.Client::new(tracing(sink).calling(remote(Map([]))))
  let refused = try {
    client.get_task("ghost") |> ignore
    false
  } catch {
    @moona2a.TaskNotFound(_) => true
    _ => false
  }
  assert_true(refused)
  let span = span_at(sink.spans(), 0)
  match span.status {
    @trace.Error(_) => ()
    _ => fail("a refused call should be an error span")
  }
}

///|
async test "otel: reading a card is its own span" {
  let sink = @trace.Recorder::new()
  let client = @moona2a.Client::new(tracing(sink).calling(remote(Map([]))))
  let card = client.discover()
  assert_eq(card.name, "summariser")
  let span = span_at(sink.spans(), 0)
  assert_eq(span.name, "a2a.discover")
  assert_eq(span.kind, @trace.Client)
  assert_eq(
    text_attribute_of(span, "gen_ai.agent.id"),
    Some("https://summariser.example.com"),
  )
}

///|
/// A map of method name to the result that method answers with.
fn map_of(pairs : Array[(String, Json)]) -> Map[String, Json] {
  let map : Map[String, Json] = Map([])
  for pair in pairs {
    map[pair.0] = pair.1
  }
  map
}
