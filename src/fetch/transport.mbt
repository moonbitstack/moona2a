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
  /// Headers to add to every request, read as each one is built. This is where a trace
  /// context, a tenant or a credential the protocol does not model rides.
  extra : () -> Array[(String, String)]
}

///|
/// A transport to the agent at `url`, e.g. `https://agent.example.com`, answering JSON-RPC on the
/// root path and serving its card at the well-known one. The `headers` callback supplies headers
/// for every request; the headers a call names take precedence over them.
pub fn HttpTransport::new(
  url : String,
  path? : String,
  card_path? : String,
  headers? : () -> Array[(String, String)],
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
    extra: headers.unwrap_or(fn() { ([] : Array[(String, String)]) }),
  }
}

///|
/// Send the request and read the answer, which is one JSON-RPC document.
async fn HttpTransport::reply(
  self : HttpTransport,
  message : @moonjrpc.Message,
  headers : Array[(String, String)],
) -> @moonjrpc.Message {
  let body = @moonfetch.Body::Text(@moonjson.dumps(message.to_json()))
  let response = self.client.post(
    self.path,
    body~,
    headers=headers_for(
      self.extra,
      [("content-type", "application/json"), ("accept", "application/json")],
      headers,
    ),
  )
  message_of(response.text(), "the answer")
}

///|
pub impl @moona2a.Transport for HttpTransport with fn exchange(self, message) {
  self.reply(message, [])
}

///|
pub impl @moona2a.Transport for HttpTransport with fn exchange_with(
  self,
  message,
  headers,
) {
  self.reply(message, headers)
}

///|
/// Send the request and hand each server-sent event to `out` as it arrives.
async fn HttpTransport::deliver(
  self : HttpTransport,
  message : @moonjrpc.Message,
  out : &@moona2a.ReplySink,
  headers : Array[(String, String)],
) -> Unit {
  let body = @moonfetch.Body::Text(@moonjson.dumps(message.to_json()))
  let stream = self.client.stream(
    Post,
    self.path,
    body~,
    headers=headers_for(
      self.extra,
      [("content-type", "application/json"), ("accept", "text/event-stream")],
      headers,
    ),
  )
  defer stream.close()
  if !is_event_stream(stream.header("content-type")) {
    // A server that refuses before opening the stream answers with one JSON-RPC body.
    let text = stream.text()
    out.reply(message_of(text, "the answer"))
    return
  }
  each_event(stream, async fn(event) {
    if event.data.trim() != "" {
      out.reply(message_of(event.data, "a frame"))
    }
  })
}

///|
/// Read one JSON-RPC message, naming what it was when it does not read.
fn message_of(text : String, what : String) -> @moonjrpc.Message raise {
  @json.from_json(
    @moonjson.loads(text, @moonjson.strict) catch {
      _ => raise WrongShape("\{what} is not JSON: \{text}")
    },
  ) catch {
    _ => raise WrongShape("\{what} is not a JSON-RPC message: \{text}")
  }
}

///|
pub impl @moona2a.Transport for HttpTransport with fn stream(self, message, out) {
  self.deliver(message, out, [])
}

///|
pub impl @moona2a.Transport for HttpTransport with fn stream_with(
  self,
  message,
  out,
  headers,
) {
  self.deliver(message, out, headers)
}

///|
/// A reply that does not read as what the protocol says it is.
pub suberror WrongShape {
  WrongShape(String)
}

///|
/// Read the agent's card from its well-known address.
async fn HttpTransport::card(
  self : HttpTransport,
  headers : Array[(String, String)],
) -> Json {
  card_of(
    self.client,
    self.card_path,
    headers_for(self.extra, [("accept", "application/json")], headers),
  )
}

///|
pub impl @moona2a.Transport for HttpTransport with fn discover(self) {
  self.card([])
}

///|
pub impl @moona2a.Transport for HttpTransport with fn discover_with(
  self,
  headers,
) {
  self.card(headers)
}

///|
pub extend HttpTransport with @moona2a.Transport::{
  exchange,
  exchange_with,
  stream,
  stream_with,
  discover,
  discover_with,
}
