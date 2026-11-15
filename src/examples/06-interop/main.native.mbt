///|
/// Stop the run: a check did not hold.
fn refuse(what : String) -> Unit {
  println("  FAIL \{what}")
  abort(what)
}

///|
/// A sink that keeps the state of every status change and prints each event as it arrives.
struct Watcher {
  states : Array[String]
  mut refused : Bool
}

///|
impl @moona2a.ReplySink for Watcher with fn reply(self, message) {
  match message {
    @moonjrpc.Reply(result~, ..) => {
      let event : @moona2a.StreamEvent = @json.from_json(result) catch {
        _ => {
          refuse("an event does not read: \{result.stringify()}")
          return
        }
      }
      match event {
        @moona2a.TaskSnapshot(task) =>
          println("  stream: task \{task.id} \{task.status.state.wire()}")
        @moona2a.StatusChange(update) => {
          self.states.push(update.status.state.wire())
          println("  stream: status \{update.status.state.wire()}")
        }
        @moona2a.ArtifactChunk(update) =>
          println("  stream: artifact \{update.artifact.text_of()}")
        @moona2a.TaskMessage(message) =>
          println("  stream: message \{message.text()}")
      }
    }
    @moonjrpc.Refusal(failure~, ..) => {
      self.refused = true
      println("  stream: refused \{failure.message}")
    }
    _ => ()
  }
}

///|
pub extend Watcher with @moona2a.ReplySink::{reply}

///|
/// Split an endpoint into the base the transport connects to and the path the methods answer on.
fn split_endpoint(url : String) -> (String, String) {
  let after_scheme = match url.find("://") {
    Some(at) => at + 3
    None => 0
  }
  let rest = url[after_scheme:].to_owned()
  match rest.find("/") {
    Some(slash) =>
      (url[:after_scheme + slash].to_owned(), rest[slash:].to_owned())
    None => (url, "/")
  }
}

///|
/// The transport for the interface of `binding` the card at `base` lists.
async fn transport_for(
  base : String,
  binding : @moona2a.Binding,
  group : @async.TaskGroup[Unit],
) -> &@moona2a.Transport {
  let reader = @moona2a.Client::new(@fetch.HttpTransport::new(base))
  let card = reader.discover()
  println(
    "card: \{card.name} \{card.version}, \{card.supported_interfaces.map(i => i.protocol_binding).join(", ")}",
  )
  guard card.choose([binding]) is Some(interface) else {
    refuse("the card lists no \{binding.code()} interface")
    abort("unreachable")
  }
  println("speaking \{binding.code()} at \{interface.url}")
  match binding {
    JsonRpc => {
      let (url, path) = split_endpoint(interface.url)
      @fetch.HttpTransport::new(url, path~) as &@moona2a.Transport
    }
    HttpJson => @fetch.RestTransport::new(interface.url) as &@moona2a.Transport
    Grpc =>
      @channel.GrpcTransport::connect(interface.url, group, card=card.to_json())
      as &@moona2a.Transport
  }
}

///|
async fn main {
  let argv = @env.args()
  let base = if argv.length() > 1 { argv[1] } else { "http://127.0.0.1:8001" }
  let binding = match argv.get(2) {
    Some(name) => @moona2a.Binding::of(name).unwrap_or(JsonRpc)
    None => @moona2a.JsonRpc
  }
  @async.with_task_group(async fn(group) {
    let client = @moona2a.Client::new(transport_for(base, binding, group))
    let task = match
      client.send_message(
        @moona2a.Message::user("interop-1", "hello from MoonBit"),
      ) {
      @moona2a.TaskSnapshot(task) => task
      _ => {
        refuse("a send did not answer with a task")
        abort("unreachable")
      }
    }
    println("send: task \{task.id} \{task.status.state.wire()}")
    if task.status.state.wire() != "TASK_STATE_COMPLETED" {
      refuse("the task finished \{task.status.state.wire()}")
    }
    if !task.artifacts
      .iter()
      .any(a => a.text_of() == "python heard: hello from MoonBit") {
      refuse("the agent's artifact is missing")
    }

    let watcher = Watcher::{ states: [], refused: false, }
    client.send_streaming_message(
      @moona2a.Message::user("interop-2", "hello again"),
      watcher,
    )
    if watcher.refused ||
      !watcher.states.contains("TASK_STATE_WORKING") ||
      watcher.states.last() != Some("TASK_STATE_COMPLETED") {
      refuse("the stream carried \{watcher.states.join(", ")}")
    }

    let read = client.get_task(task.id)
    println("get_task: \{read.status.state.wire()}")
    if read.status.state.wire() != "TASK_STATE_COMPLETED" {
      refuse("the task reads back as \{read.status.state.wire()}")
    }

    let missing = try {
      ignore(client.get_task("interop-no-such-task"))
      false
    } catch {
      @moona2a.TaskNotFound(_) => true
      _ => false
    }
    if !missing {
      refuse("an unknown task was not TaskNotFound")
    }
    println("refusal: an unknown task is TaskNotFound")

    let finished = try {
      ignore(client.cancel_task(task.id))
      false
    } catch {
      @moona2a.TaskNotCancelable(_) => true
      _ => false
    }
    if !finished {
      refuse("cancelling a finished task was not TaskNotCancelable")
    }
    println("refusal: a finished task is TaskNotCancelable")
    println("moonbit client over \{binding.code()}: ok")
    group.return_immediately(())
  })
}
