// Call an agent: send a message, then read the task it opened.

///|
/// An agent that answers every call from a table, so the example runs without a network.
struct Canned {
  task : @moona2a.Task
}

///|
impl @moona2a.Transport for Canned with fn exchange(self, message) {
  match message {
    @moonjrpc.Call(id~, ..) =>
      @moonjrpc.Message::Reply(
        id~,
        result=Json::object({ "task": self.task.to_json() }),
      )
    _ => @moonjrpc.Message::unreadable()
  }
}

///|
impl @moona2a.Transport for Canned with fn stream(self, message, out) {
  ignore(self)
  ignore(message)
  ignore(out)
  ()
}

///|
impl @moona2a.Transport for Canned with fn discover(self) {
  ignore(self)
  @moona2a.AgentCard::new(
    "canned",
    "an agent that answers from a table",
    "1.0.0",
    "https://canned.test",
    [],
  ).to_json()
}

///|
pub extend Canned with @moona2a.Transport::{exchange, stream, discover}

///|
async fn main {
  let task = @moona2a.Task::new("t-1", "c-1")
    .saying(@moona2a.Message::user("m-1", "summarise this"))
    .taking(@moona2a.Artifact::text("a-1", "A short paragraph."), false)
    .with_state(@moona2a.Completed)
  let transport : Canned = { task, }
  let client = @moona2a.Client::new(transport)
  let answer = client.send_message(
    @moona2a.Message::user("m-2", "summarise this"),
  )
  match answer {
    @moona2a.TaskSnapshot(read) => {
      println("task \{read.id} is \{read.status.state.wire()}")
      for artifact in read.artifacts {
        println(artifact.text_of())
      }
    }
    @moona2a.TaskMessage(message) => println(message.text())
    _ => println("the agent answered with something else")
  }
}
