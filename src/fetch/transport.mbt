// A client that speaks the JSON-RPC binding over HTTP, and follows a streaming answer as the frames
// arrive.

///|
/// The JSON-RPC endpoint of one agent, reached over HTTP.
pub(all) struct HttpTransport {
  client : @moonfetch.Client
  /// The path the methods answer on.
  path : String
  /// The path the card is served at.
  card_path : String
}

///|
/// A transport to the agent at `url`, e.g. `https://agent.example.com`, answering JSON-RPC on the
/// root path and serving its card at the well-known one.
pub fn HttpTransport::new(
  url : String,
  path? : String,
  card_path? : String,
) -> HttpTransport raise {
  let base = if url.has_suffix("/") {
    url[:url.length() - 1].to_owned()
  } else {
    url
  }
  let client = @moonfetch.Client::new(base_url=base, headers=[
    ("a2a-version", @moona2a.protocol_version),
  ])
  {
    client,
    path: path.unwrap_or("/"),
    card_path: card_path.unwrap_or(@moona2a.card_path),
  }
}

///|
/// Send the request and read the answer, which is one JSON-RPC document.
pub impl @moona2a.Transport for HttpTransport with fn exchange(self, message) {
  let body = @moonfetch.Body::Text(message.to_json().stringify())
  let response = self.client.post(self.path, body~, headers=[
    ("content-type", "application/json"),
    ("accept", "application/json"),
  ])
  let text = response.text()
  @json.from_json(
    @json.parse(text) catch {
      _ => raise WrongShape("the answer is not JSON: \{text}")
    },
  ) catch {
    _ => raise WrongShape("the answer is not a JSON-RPC message: \{text}")
  }
}

///|
/// Send the request and hand each server-sent event to `out`.
///
/// The answer is read to its end before the events are handed over: the HTTP client this library
/// depends on has no incremental body, so a frame waits for the response to finish. The sink is
/// still the seam a host with a streaming client delivers into as frames arrive.
pub impl @moona2a.Transport for HttpTransport with fn stream(self, message, out) {
  let body = @moonfetch.Body::Text(message.to_json().stringify())
  let response = self.client.post(self.path, body~, headers=[
    ("content-type", "application/json"),
    ("accept", "text/event-stream"),
  ])
  let text = response.text()
  if !is_event_stream(response) {
    // A server that refuses before opening the stream answers with one JSON-RPC body.
    let reply : @moonjrpc.Message = @json.from_json(
      @json.parse(text) catch {
        _ => raise WrongShape("the answer is not JSON: \{text}")
      },
    ) catch {
      _ => raise WrongShape("the answer is not a JSON-RPC message: \{text}")
    }
    out.reply(reply)
    return
  }
  for event in @sse.events(text) {
    if event.data.trim() == "" {
      continue
    }
    let reply : @moonjrpc.Message = @json.from_json(
      @json.parse(event.data) catch {
        _ => raise WrongShape("a frame is not JSON: \{event.data}")
      },
    ) catch {
      _ => raise WrongShape("a frame is not a JSON-RPC message: \{event.data}")
    }
    out.reply(reply)
  }
}

///|
/// Whether the answer is a stream of events rather than one body.
fn is_event_stream(response : @moonfetch.Response) -> Bool {
  match response.header("content-type") {
    Some(value) => value.contains("text/event-stream")
    None => false
  }
}

///|
/// A reply that does not read as what the protocol says it is.
pub suberror WrongShape {
  WrongShape(String)
}

///|
/// Read the agent's card from its well-known address.
pub impl @moona2a.Transport for HttpTransport with fn discover(self) {
  let response = self.client.get(self.card_path, headers=[
    ("accept", "application/json"),
  ])
  @json.parse(response.text()) catch {
    _ => raise WrongShape("the card is not JSON")
  }
}

///|
pub extend HttpTransport with @moona2a.Transport::{exchange, stream, discover}
