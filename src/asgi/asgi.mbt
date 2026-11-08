// The ASGI application: the HTTP binding of the protocol, where a request body becomes a call and
// a streamed event becomes a frame.

///|
/// Where the endpoint answers, and how long a client may cache the card.
pub(all) struct Options {
  /// The path the JSON-RPC methods answer on.
  rpc_path : String
  /// The path the card is served at (section 8.2).
  card_path : String
  /// How long a client may keep the card, in seconds. The specification asks a server to say.
  cache_seconds : Int32
}

///|
/// The endpoint at `/`, the card at its well-known address, and a card a client may keep for five
/// minutes.
pub fn Options::new() -> Options {
  { rpc_path: "/", card_path: @moona2a.card_path, cache_seconds: 300, }
}

///|
/// The ASGI application for `server`: a GET of the card's well-known address answers with the card,
/// a POST of a JSON-RPC body answers with a body or, for a streaming method, with a stream of
/// server-sent events.
///
/// The application writes its events as it goes, rather than assembling one `Response`: a stream
/// answer is only worth having if each event leaves as it happens.
pub fn to_asgi(
  server : @moona2a.Server,
  options? : Options,
) -> @moonasgi.AsgiApp {
  let options = options.unwrap_or(Options::new())
  async fn(scope, receive, send) {
    match scope {
      @spec.Http(http) => serve(server, options, http, receive, send)
      @spec.WebSocket(_) | @spec.Lifespan(_) => ()
    }
  }
}

///|
/// Answer one HTTP request, streaming when the method asks for it.
async fn serve(
  server : @moona2a.Server,
  options : Options,
  http : @spec.HttpScope,
  receive : @moonasgi.Receive,
  send : @moonasgi.Send,
) -> Unit {
  let body = read_body(receive)
  if http.http_method == "GET" && http.path == options.card_path {
    send_response(send, card_response(server, options))
    return
  }
  if http.http_method != "POST" || http.path != options.rpc_path {
    send_response(send, @moonasgi.Response::text(status=404, "not found"))
    return
  }
  let text = @utf8.decode(body) catch {
    _ => {
      send_response(
        send,
        @moonasgi.Response::text(status=400, "the body is not UTF-8"),
      )
      return
    }
  }
  let extensions = extension_header(http.headers)
  // A request with no version header is a 0.3 client, which section 3.6.2 says to treat as such.
  let version = header_of(http.headers, "a2a-version").unwrap_or("")
  match @moona2a.request_method(text) {
    Some(name) =>
      if @moona2a.is_streaming_method(name) {
        let frames : Stream = { send, opened: false, refused: None, }
        server.answer_stream(
          text,
          frames,
          extensions~,
          version~,
          headers=http.headers,
        )
        match frames.refused {
          Some(refusal) =>
            // Nothing was streamed, so the answer is a plain JSON-RPC error body, with the id the
            // caller sent.
            send_response(send, json_response(refusal.to_json().stringify()))
          None =>
            if frames.opened {
              send_stop(send)
            } else {
              // A stream method that produced no event still answers with an empty stream.
              send_start(send) catch {
                _ => ()
              }
              send_stop(send)
            }
        }
      } else {
        let answer = server.answer(
          text,
          extensions~,
          version~,
          headers=http.headers,
        ) catch {
          _ => None
        }
        match answer {
          Some(answer) => send_response(send, json_response(answer))
          None => send_response(send, @moonasgi.Response::new(204, [], b""))
        }
      }
    None => {
      let answer = server.answer(
        text,
        extensions~,
        version~,
        headers=http.headers,
      ) catch {
        _ => None
      }
      match answer {
        Some(answer) => send_response(send, json_response(answer))
        None => send_response(send, @moonasgi.Response::new(204, [], b""))
      }
    }
  }
}

///|
/// A sink that writes each reply as a server-sent event. The response is opened by the first frame,
/// not before: a call that is refused before it starts (an unknown task, a version the interface
/// does not serve) is an ordinary JSON-RPC error answer, not a stream that carries one error.
struct Stream {
  send : @moonasgi.Send
  mut opened : Bool
  mut refused : @moonjrpc.Message?
}

///|
impl @moona2a.ReplySink for Stream with fn reply(self, message) {
  match message {
    @moonjrpc.Refusal(..) =>
      if self.opened {
        // A refusal in the middle of a stream is one more event, and the stream ends after it.
        self.write_reply(message)
      } else {
        self.refused = Some(message)
      }
    _ => self.write_reply(message)
  }
}

///|
/// Write one reply as a frame, opening the response the first time.
async fn Stream::write_reply(
  self : Stream,
  message : @moonjrpc.Message,
) -> Unit {
  if !self.opened {
    self.opened = true
    (self.send)(
      @spec.HttpResponseStart(
        status=200,
        headers=[
          ("content-type", "text/event-stream"),
          ("cache-control", "no-cache"),
          ("connection", "keep-alive"),
        ],
        trailers=false,
      ),
    )
  }
  let frame = "data: \{message.to_json().stringify()}\n\n"
  (self.send)(@spec.HttpResponseBody(body=@utf8.encode(frame), more_body=true))
}

///|
pub extend Stream with @moona2a.ReplySink::{reply}

///|
/// Open the response for a stream, for a method that produced no event at all.
async fn send_start(send : @moonasgi.Send) -> Unit {
  send(
    @spec.HttpResponseStart(
      status=200,
      headers=[
        ("content-type", "text/event-stream"),
        ("cache-control", "no-cache"),
        ("connection", "keep-alive"),
      ],
      trailers=false,
    ),
  ) catch {
    _ => ()
  }
}

///|
/// Close the response.
async fn send_stop(send : @moonasgi.Send) -> Unit {
  send(@spec.HttpResponseBody(body=b"", more_body=false)) catch {
    _ => ()
  }
}

///|
/// Read the whole request body, which the protocol sends in one piece for a call.
async fn read_body(receive : @moonasgi.Receive) -> Bytes {
  let mut whole = Bytes::new(0)
  let mut reading = true
  while reading {
    match receive() {
      @spec.HttpRequest(body~, more_body~) => {
        whole = whole.add(body)
        reading = more_body
      }
      _ => reading = false
    }
  }
  whole
}

///|
/// Write a complete response.
async fn send_response(
  send : @moonasgi.Send,
  response : @moonasgi.Response,
) -> Unit {
  send(
    @spec.HttpResponseStart(
      status=response.status,
      headers=response.headers,
      trailers=false,
    ),
  ) catch {
    _ => ()
  }
  send(@spec.HttpResponseBody(body=response.body, more_body=false)) catch {
    _ => ()
  }
}

///|
/// A JSON answer.
fn json_response(text : String) -> @moonasgi.Response {
  @moonasgi.Response::new(
    200,
    [("content-type", "application/json"), ("cache-control", "no-store")],
    @utf8.encode(text),
  )
}

///|
/// The card, with the cache headers section 8.6 asks for. The `ETag` is derived from the card's own
/// bytes, so a card that changes gets a new one without anyone keeping a version by hand.
fn card_response(
  server : @moona2a.Server,
  options : Options,
) -> @moonasgi.Response {
  let text = server.card_json().stringify()
  let tag = "\"\{text.hash().to_string()}\""
  @moonasgi.Response::new(
    200,
    [
      ("content-type", "application/json"),
      ("cache-control", "max-age=\{options.cache_seconds}"),
      ("etag", tag),
    ],
    @utf8.encode(text),
  )
}

///|
/// The value of `name` in `headers`, matched without regard to case.
fn header_of(headers : Array[(String, String)], name : String) -> String? {
  for pair in headers {
    if pair.0.to_lower() == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// The extension URIs a caller declared, comma-separated in one header as section 9.2 says.
fn extension_header(headers : Array[(String, String)]) -> Array[String] {
  match header_of(headers, "a2a-extensions") {
    Some(value) => {
      let out : Array[String] = []
      for part in value.split(",") {
        let trimmed = part.trim().to_owned()
        if trimmed != "" {
          out.push(trimmed)
        }
      }
      out
    }
    None => []
  }
}
