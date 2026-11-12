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
/// The headers this transport sends with a request: what the protocol asks for, then what
/// the host supplies for this moment, then what this one call asked for. A name that
/// appears twice is sent once, with the last value, so a per-call `traceparent` cannot
/// leave an older one beside it on the wire.
fn HttpTransport::headers_for(
  self : HttpTransport,
  own : Array[(String, String)],
  per_call : Array[(String, String)],
) -> Array[(String, String)] {
  @moona2a.merge_headers(@moona2a.merge_headers(own, (self.extra)()), per_call)
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
    headers=self.headers_for(
      [("content-type", "application/json"), ("accept", "application/json")],
      headers,
    ),
  )
  let text = response.text()
  @json.from_json(
    @moonjson.loads(text, @moonjson.strict) catch {
      _ => raise WrongShape("the answer is not JSON: \{text}")
    },
  ) catch {
    _ => raise WrongShape("the answer is not a JSON-RPC message: \{text}")
  }
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
/// Send the request and hand each server-sent event to `out`.
///
/// The answer is read to its end before the events are handed over: the HTTP client this library
/// depends on has no incremental body, so a frame waits for the response to finish. The sink is
/// still the seam a host with a streaming client delivers into as frames arrive.
async fn HttpTransport::deliver(
  self : HttpTransport,
  message : @moonjrpc.Message,
  out : &@moona2a.ReplySink,
  headers : Array[(String, String)],
) -> Unit {
  let body = @moonfetch.Body::Text(@moonjson.dumps(message.to_json()))
  let response = self.client.post(
    self.path,
    body~,
    headers=self.headers_for(
      [("content-type", "application/json"), ("accept", "text/event-stream")],
      headers,
    ),
  )
  let text = response.text()
  if !is_event_stream(response) {
    // A server that refuses before opening the stream answers with one JSON-RPC body.
    let reply : @moonjrpc.Message = @json.from_json(
      @moonjson.loads(text, @moonjson.strict) catch {
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
      @moonjson.loads(event.data, @moonjson.strict) catch {
        _ => raise WrongShape("a frame is not JSON: \{event.data}")
      },
    ) catch {
      _ => raise WrongShape("a frame is not a JSON-RPC message: \{event.data}")
    }
    out.reply(reply)
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
async fn HttpTransport::card(
  self : HttpTransport,
  headers : Array[(String, String)],
) -> Json {
  let response = self.client.get(
    self.card_path,
    headers=self.headers_for([("accept", "application/json")], headers),
  )
  @moonjson.loads(response.text(), @moonjson.strict) catch {
    _ => raise WrongShape("the card is not JSON")
  }
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
