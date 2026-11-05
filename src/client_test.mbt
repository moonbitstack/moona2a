// A client asks for what the protocol says to ask for, and reads the answers back into types. The
// transport is faked here, so what is under test is the client, not the network.

///|
struct Fake {
  calls : Array[String]
  asked : Array[Json]
  answers : Map[String, Json]
  card : Json
}

///|
impl @moona2a.Transport for Fake with fn exchange(self, message) {
  match message {
    @moonjrpc.Call(id~, name~, params~) => {
      self.calls.push(name)
      self.asked.push(params.unwrap_or(Json::null()))
      match self.answers.get(name) {
        Some(result) => @moonjrpc.Message::Reply(id~, result~)
        None =>
          @moonjrpc.Message::Refusal(id~, failure={
            code: -32001,
            message: "Task not found",
            data: None,
          })
      }
    }
    _ => @moonjrpc.Message::unreadable()
  }
}

///|
impl @moona2a.Transport for Fake with fn stream(self, message, out) {
  match message {
    @moonjrpc.Call(id~, name~, ..) => {
      self.calls.push(name)
      let task = @moona2a.Task::new("t-1", "c-1")
      out.reply(
        @moonjrpc.Message::Reply(
          id~,
          result=@moona2a.StreamEvent::TaskSnapshot(task).to_json(),
        ),
      )
      out.reply(
        @moonjrpc.Message::Reply(
          id~,
          result=@moona2a.StreamEvent::StatusChange(
            @moona2a.TaskStatusUpdate::of("t-1", "c-1", @moona2a.Completed),
          ).to_json(),
        ),
      )
    }
    _ => ()
  }
}

///|
impl @moona2a.Transport for Fake with fn discover(self) {
  self.card
}

///|
pub extend Fake with @moona2a.Transport::{exchange, stream, discover}

///|
fn fake(answers : Map[String, Json]) -> Fake {
  {
    calls: [],
    asked: [],
    answers,
    card: @moona2a.AgentCard::new("n", "d", "1", "https://a.test", []).to_json(),
  }
}

///|
async test "client: a send asks for SendMessage and reads the task it gets" {
  let task = @moona2a.Task::new("t-1", "c-1").with_state(@moona2a.Completed)
  let transport = fake(
    map_of([("SendMessage", Json::object({ "task": task.to_json() }))]),
  )
  let client = @moona2a.Client::new(transport)
  let answer = client.send_message(@moona2a.Message::user("m-1", "hi"))
  match answer {
    @moona2a.TaskSnapshot(read) => assert_eq(read.id, "t-1")
    _ => fail("a send that answers with a task should read as one")
  }
  assert_eq(transport.calls, ["SendMessage"])
  let params = match transport.asked[0] {
    Object(fields) => fields
    _ => fail("the parameters are not an object")
  }
  assert_true(params.contains("message"))
}

///|
async test "client: a send that answers with a message reads as one" {
  let message = @moona2a.Message::agent("m-1", "hello")
  let transport = fake(
    map_of([("SendMessage", Json::object({ "message": message.to_json() }))]),
  )
  let client = @moona2a.Client::new(transport)
  let answer = client.send_message(@moona2a.Message::user("m-2", "hi"))
  match answer {
    @moona2a.TaskMessage(read) => assert_eq(read.text(), "hello")
    _ => fail("a send that answers with a message should read as one")
  }
}

///|
async test "client: a send carries the configuration it was given" {
  let task = @moona2a.Task::new("t-1", "c-1")
  let transport = fake(
    map_of([("SendMessage", Json::object({ "task": task.to_json() }))]),
  )
  let client = @moona2a.Client::new(transport)
  client.send_message(
    @moona2a.Message::user("m-1", "hi"),
    configuration=@moona2a.SendMessageConfig::waiting().at_most(2),
  )
  |> ignore
  let params = match transport.asked[0] {
    Object(fields) => fields
    _ => fail("the parameters are not an object")
  }
  let configuration = match params.get("configuration") {
    Some(Object(fields)) => fields
    _ => fail("the request carries no configuration")
  }
  assert_eq(field_int(configuration, "historyLength"), Some(2))
}

///|
async test "client: get asks for GetTask with the id and the history it was given" {
  let task = @moona2a.Task::new("t-9", "c-1")
  let transport = fake(map_of([("GetTask", task.to_json())]))
  let client = @moona2a.Client::new(transport)
  let answer = client.get_task("t-9", history_length=3)
  assert_eq(answer.id, "t-9")
  let params = match transport.asked[0] {
    Object(fields) => fields
    _ => fail("the parameters are not an object")
  }
  assert_eq(field_str(params, "id"), Some("t-9"))
  assert_eq(field_int(params, "historyLength"), Some(3))
}

///|
async test "client: cancel asks for CancelTask" {
  let task = @moona2a.Task::new("t-9", "c-1").with_state(@moona2a.Canceled)
  let transport = fake(map_of([("CancelTask", task.to_json())]))
  let client = @moona2a.Client::new(transport)
  let answer = client.cancel_task("t-9")
  assert_eq(answer.status.state.wire(), "TASK_STATE_CANCELED")
  assert_eq(transport.calls, ["CancelTask"])
}

///|
async test "client: list asks for ListTasks and reads the page" {
  let page : @moona2a.TaskPage = {
    tasks: [@moona2a.Task::new("t-1", "c-1")],
    next_page_token: "1",
    page_size: 1,
    total_size: 2,
  }
  let transport = fake(map_of([("ListTasks", page.to_json())]))
  let client = @moona2a.Client::new(transport)
  let answer = client.list_tasks(
    @moona2a.ListTasksQuery::all().in_context("c-1"),
  )
  assert_eq(answer.tasks.length(), 1)
  assert_eq(answer.next_page_token, "1")
  let params = match transport.asked[0] {
    Object(fields) => fields
    _ => fail("the parameters are not an object")
  }
  assert_eq(field_str(params, "contextId"), Some("c-1"))
}

///|
async test "client: a refusal becomes the error it names, code and all" {
  let transport = fake(Map([]))
  let client = @moona2a.Client::new(transport)
  let refusal = try {
    client.get_task("ghost") |> ignore
    fail("the call should have been refused")
  } catch {
    @moona2a.TaskNotFound(_) => @moona2a.TaskNotFound("")
    _ => fail("the refusal was not a task-not-found")
  }
  assert_eq(refusal.code(), -32001)
}

///|
async test "client: a push registration is sent flattened, as 1.0 writes it" {
  let config = @moona2a.TaskPushConfig::new(
    "cfg-1", "t-1", "https://hook.test/a",
  )
  let transport = fake(
    map_of([("CreateTaskPushNotificationConfig", config.to_json())]),
  )
  let client = @moona2a.Client::new(transport)
  let answer = client.create_push_config(config)
  assert_eq(answer.id, "cfg-1")
  let params = match transport.asked[0] {
    Object(fields) => fields
    _ => fail("the parameters are not an object")
  }
  assert_eq(field_str(params, "taskId"), Some("t-1"))
  assert_eq(field_str(params, "url"), Some("https://hook.test/a"))
  assert_false(params.contains("pushNotificationConfig"))
}

///|
async test "client: the card is read from the agent's well-known address" {
  let transport = fake(Map([]))
  let client = @moona2a.Client::new(transport)
  let card = client.discover()
  assert_eq(card.name, "n")
  assert_eq(card.preferred().unwrap().protocol_binding, "JSONRPC")
}

///|
async test "client: a streamed answer reaches the sink event by event" {
  let transport = fake(Map([]))
  let client = @moona2a.Client::new(transport)
  let recorder : Recorder = { replies: [], }
  client.send_streaming_message(@moona2a.Message::user("m-1", "hi"), recorder)
  assert_eq(transport.calls, ["SendStreamingMessage"])
  assert_eq(recorder.replies.length(), 2)
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
