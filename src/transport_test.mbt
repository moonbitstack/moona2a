// The per-call header methods have defaults: a transport that implements only the three
// original calls keeps working, and a shared client still answers each task it is given.

///|
/// A transport from before per-call headers existed. It implements `exchange`, `stream`
/// and `discover` and nothing else.
struct Table {
  answers : Map[String, Json]
  calls : Ref[Array[String]]
}

///|
impl @moona2a.Transport for Table with fn exchange(self, message) {
  match message {
    @moonjrpc.Call(id~, name~, ..) => {
      self.calls.val.push(name)
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
impl @moona2a.Transport for Table with fn stream(self, message, out) {
  ignore(self)
  ignore(message)
  ignore(out)
}

///|
impl @moona2a.Transport for Table with fn discover(self) {
  ignore(self)
  @moona2a.AgentCard::new(
    "canned",
    "answers from a table",
    "1.0.0",
    "https://canned.test",
    [],
  ).to_json()
}

///|
pub extend Table with @moona2a.Transport::{exchange, stream, discover}

///|
fn table(answers : Array[(String, Json)]) -> Table {
  let map : Map[String, Json] = Map([])
  for pair in answers {
    map[pair.0] = pair.1
  }
  { answers: map, calls: Ref([]), }
}

///|
async test "transport: the original three methods still answer a call with headers" {
  let task = @moona2a.Task::new("t-1", "c-1")
  let transport = table([("GetTask", task.to_json())])
  let client = @moona2a.Client::new(transport)
  let answer = client.get_task("t-1", headers=[("x-tenant", "t-1")])
  assert_eq(answer.id, "t-1")
  assert_eq(transport.calls.val, ["GetTask"])
}

///|
async test "transport: several tasks share one client and each gets an answer" {
  let task = @moona2a.Task::new("t-1", "c-1")
  let transport = table([("GetTask", task.to_json())])
  let client = @moona2a.Client::new(transport)
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      client.get_task("t-1", headers=[("x-call", "first")]) |> ignore
    }
    group.spawn_bg() <| () => {
      client.get_task("t-2", headers=[("x-call", "second")]) |> ignore
    }
  }
  assert_eq(transport.calls.val.length(), 2)
}

///|
test "transport: merged headers keep the last value for a name, in any case" {
  let merged = @moona2a.merge_headers(
    [("accept", "application/json"), ("X-Tenant", "host")],
    [("x-tenant", "call"), ("x-call", "one")],
  )
  assert_eq(merged, [
    ("accept", "application/json"),
    ("x-tenant", "call"),
    ("x-call", "one"),
  ])
  assert_eq(@moona2a.merge_headers([], []), ([] : @moona2a.Headers))
}
