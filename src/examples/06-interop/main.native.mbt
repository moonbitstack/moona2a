///|
/// A sink that prints each event as it arrives.
struct Printer {}

///|
impl @moona2a.ReplySink for Printer with fn reply(self, message) {
  ignore(self)
  match message {
    @moonjrpc.Reply(result~, ..) => {
      let event : @moona2a.StreamEvent = @json.from_json(result) catch {
        _ =>
          @moona2a.StreamEvent::TaskMessage(@moona2a.Message::agent("?", "?"))
      }
      match event {
        @moona2a.TaskSnapshot(task) =>
          println("  stream: task \{task.id} \{task.status.state.wire()}")
        @moona2a.StatusChange(update) =>
          println("  stream: status \{update.status.state.wire()}")
        @moona2a.ArtifactChunk(update) =>
          println("  stream: artifact \{update.artifact.text_of()}")
        @moona2a.TaskMessage(message) =>
          println("  stream: message \{message.text()}")
      }
    }
    @moonjrpc.Refusal(failure~, ..) =>
      println("  stream: refused \{failure.message}")
    _ => ()
  }
}

///|
pub extend Printer with @moona2a.ReplySink::{reply}

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
async fn main {
  let argv = @env.args()
  let endpoint = if argv.length() > 1 {
    argv[1]
  } else {
    "http://127.0.0.1:9999/"
  }
  let (url, path) = split_endpoint(endpoint)
  let transport = @fetch.HttpTransport::new(url, path~)
  let client = @moona2a.Client::new(transport)

  let card = client.discover()
  println(
    "card: \{card.name} \{card.version}, streaming \{card.capabilities.streaming}",
  )

  match
    client.send_message(
      @moona2a.Message::user("interop-1", "hello from MoonBit"),
    ) {
    @moona2a.TaskSnapshot(task) => {
      println("send: task \{task.id} \{task.status.state.wire()}")
      for artifact in task.artifacts {
        println("  artifact: \{artifact.text_of()}")
      }
      println("  history: \{task.history.length()} message(s)")
    }
    @moona2a.TaskMessage(message) => println("send: message \{message.text()}")
    @moona2a.StatusChange(update) =>
      println("send: status \{update.status.state.wire()}")
    @moona2a.ArtifactChunk(update) =>
      println("send: artifact \{update.artifact.text_of()}")
  }

  if card.capabilities.streaming {
    println("stream:")
    let sink = Printer::{ }
    client.send_streaming_message(
      @moona2a.Message::user("interop-2", "hello again"),
      sink,
    )
  }
}
