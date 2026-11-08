// The HTTP binding: what a request looks like inside, and what comes back out.

///|
/// A request scope for `method` and `path`.
fn scope_of(
  verb : String,
  path : String,
  headers : Array[(String, String)],
) -> @moonasgi.Scope {
  @spec.Http({
    http_version: "1.1",
    http_method: verb,
    scheme: "http",
    path,
    raw_path: None,
    query_string: b"",
    root_path: "",
    headers,
    client: Some(("127.0.0.1", 5000)),
    server: Some(("127.0.0.1", Some(8000))),
    asgi: @moonasgi.AsgiVersion::http(),
    extensions: {
      tls: None,
      http_response_push: false,
      http_response_trailers: false,
      http_response_pathsend: false,
      http_response_zerocopysend: false,
      http_response_early_hint: false,
      http_response_debug: false,
      websocket_http_response: false,
      custom: Map([]),
    },
    state: Map([]),
  })
}

///|
/// Drive an application once: the request body goes in, the events it sends come out.
async fn drive(
  app : @moonasgi.AsgiApp,
  scope : @moonasgi.Scope,
  body : Bytes,
) -> Array[@spec.Event] {
  let inbound = [@spec.HttpRequest(body~, more_body=false)]
  let mut cursor = 0
  let out : Array[@spec.Event] = []
  let receive : @moonasgi.Receive = fn() {
    if cursor < inbound.length() {
      let event = inbound[cursor]
      cursor = cursor + 1
      event
    } else {
      @spec.HttpDisconnect
    }
  }
  let send : @moonasgi.Send = fn(event) { out.push(event) }
  app(scope, receive, send)
  out
}

///|
/// What a run of events came to: the status, the headers and the body, all decoded for reading.
fn response_of(
  events : Array[@spec.Event],
) -> (Int32, Array[(String, String)], String) {
  let mut status = 0
  let headers : Array[(String, String)] = []
  let chunks : Array[Bytes] = []
  for event in events {
    match event {
      @spec.HttpResponseStart(status=code, headers=pairs, ..) => {
        status = code
        for pair in pairs {
          headers.push(pair)
        }
      }
      @spec.HttpResponseBody(body~, ..) => chunks.push(body)
      _ => ()
    }
  }
  let whole = chunks.fold(init=Bytes::new(0), fn(sum, chunk) { sum.add(chunk) })
  (status, headers, @utf8.decode(whole) catch { _ => "" })
}

///|
/// The first header named `name`, matched without regard to case.
fn head_of(headers : Array[(String, String)], name : String) -> String? {
  for pair in headers {
    if pair.0.to_lower() == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// A test card.
fn card_of() -> @moona2a.AgentCard {
  @moona2a.AgentCard::new(
    "tester",
    "an agent for tests",
    "1.0.0",
    "http://127.0.0.1:8000",
    [@moona2a.AgentSkill::new("echo", "Echo", "says things back", ["test"])],
  ).capable(@moona2a.AgentCapabilities::streaming_and_push())
}

///|
/// An agent that answers every message with a finished task.
struct Echo {}

///|
impl @moona2a.Executor for Echo with fn execute(self, ctx, out) {
  ignore(self)
  out.emit(ctx.status(@moona2a.Working))
  out.emit(ctx.status(@moona2a.Completed))
}

///|
impl @moona2a.Executor for Echo with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
pub extend Echo with @moona2a.Executor::{execute, cancel}

///|
/// A send of one text message, as the protocol writes it.
fn send_body() -> Bytes {
  @utf8.encode(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendMessage\",\"params\":{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"hi\"}]}}}",
  )
}

///|
async test "asgi: the card is served at its well-known address, with cache headers" {
  let server = @moona2a.Server::new(Echo::{ }, card_of())
  let app = @asgi.to_asgi(server)
  let events = drive(
    app,
    scope_of("GET", "/.well-known/agent-card.json", []),
    b"",
  )
  let (status, headers, body) = response_of(events)
  assert_eq(status, 200)
  assert_eq(head_of(headers, "content-type"), Some("application/json"))
  assert_eq(head_of(headers, "cache-control"), Some("max-age=300"))
  assert_true(head_of(headers, "etag") is Some(_))
  let card : @moona2a.AgentCard = @json.from_json(
    @json.parse(body) catch {
      _ => fail("the card is not JSON")
    },
  ) catch {
    _ => fail("the card does not read")
  }
  assert_eq(card.name, "tester")
}

///|
async test "asgi: a call answers with a body under the JSON content type" {
  let server = @moona2a.Server::new(Echo::{ }, card_of())
  let app = @asgi.to_asgi(server)
  let events = drive(
    app,
    scope_of("POST", "/", [("a2a-version", "1.0")]),
    send_body(),
  )
  let (status, headers, body) = response_of(events)
  assert_eq(status, 200)
  assert_eq(head_of(headers, "content-type"), Some("application/json"))
  assert_true(body.contains("TASK_STATE_COMPLETED"))
}

///|
async test "asgi: a streaming call answers with events as they happen" {
  let server = @moona2a.Server::new(Echo::{ }, card_of())
  let app = @asgi.to_asgi(server)
  let body = @utf8.encode(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendStreamingMessage\",\"params\":{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"hi\"}]}}}",
  )
  let events = drive(app, scope_of("POST", "/", [("a2a-version", "1.0")]), body)
  let (status, headers, text) = response_of(events)
  assert_eq(status, 200)
  assert_eq(head_of(headers, "content-type"), Some("text/event-stream"))
  assert_eq(head_of(headers, "cache-control"), Some("no-cache"))
  // Each frame is one `data:` line holding one JSON-RPC reply.
  let mut frames = 0
  for line in text.split("\n") {
    if line.trim().has_prefix("data:") {
      frames = frames + 1
    }
  }
  assert_true(frames >= 2)
  // Every frame is closed by a blank line, which is what makes it a frame.
  assert_true(text.contains("\n\n"))
}

///|
async test "asgi: the events a stream carries are the JSON-RPC replies the protocol asks for" {
  let server = @moona2a.Server::new(Echo::{ }, card_of())
  let app = @asgi.to_asgi(server)
  let body = @utf8.encode(
    "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"SendStreamingMessage\",\"params\":{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"hi\"}]}}}",
  )
  let events = drive(app, scope_of("POST", "/", [("a2a-version", "1.0")]), body)
  let (_, _, text) = response_of(events)
  for frame in @sse.events(text) {
    if frame.data.trim() == "" {
      continue
    }
    let reply = @json.parse(frame.data) catch {
      _ => fail("a frame is not JSON")
    }
    let fields = match reply {
      Object(fields) => fields
      _ => fail("a frame is not an object")
    }
    assert_eq(head_of([], "x"), None)
    assert_true(fields.contains("jsonrpc"))
    assert_true(fields.contains("id"))
    assert_true(fields.contains("result"))
  }
}

///|
async test "asgi: a path the endpoint does not answer is a 404" {
  let server = @moona2a.Server::new(Echo::{ }, card_of())
  let app = @asgi.to_asgi(server)
  let events = drive(app, scope_of("GET", "/nope", []), b"")
  let (status, _, _) = response_of(events)
  assert_eq(status, 404)
}

///|
async test "asgi: a version this interface does not serve is refused" {
  let server = @moona2a.Server::new(Echo::{ }, card_of())
  let app = @asgi.to_asgi(server)
  let events = drive(
    app,
    scope_of("POST", "/", [("a2a-version", "99.0")]),
    send_body(),
  )
  let (status, _, body) = response_of(events)
  assert_eq(status, 200)
  assert_true(body.contains("-32009"))
}

///|
async test "asgi: a request with no version header is a 0.3 client, and is refused" {
  let server = @moona2a.Server::new(Echo::{ }, card_of())
  let app = @asgi.to_asgi(server)
  let events = drive(app, scope_of("POST", "/", []), send_body())
  let (_, _, body) = response_of(events)
  assert_true(body.contains("-32009"))
}

///|
async test "asgi: a declared extension header reaches the server" {
  let mut capabilities = @moona2a.AgentCapabilities::streaming_and_push()
  capabilities = {
    ..capabilities,
    extensions: [
      {
        uri: "https://example.test/ext/v1",
        description: None,
        required: true,
        params: None,
      },
    ],
  }
  let server = @moona2a.Server::new(Echo::{ }, card_of().capable(capabilities))
  let app = @asgi.to_asgi(server)
  let refused = drive(
    app,
    scope_of("POST", "/", [("a2a-version", "1.0")]),
    send_body(),
  )
  let (_, _, refused_body) = response_of(refused)
  assert_true(refused_body.contains("-32008"))
  let declared = drive(
    app,
    scope_of("POST", "/", [
      ("a2a-version", "1.0"),
      ("a2a-extensions", "https://example.test/ext/v1"),
    ]),
    send_body(),
  )
  let (_, _, declared_body) = response_of(declared)
  assert_true(declared_body.contains("TASK_STATE_COMPLETED"))
}

///|
/// An agent that writes down what the request carried outside the message.
struct Peeking {
  seen : Ref[Array[(String, String)]]
}

///|
impl @moona2a.Executor for Peeking with fn execute(self, ctx, out) {
  self.seen.val = ctx.headers
  out.emit(ctx.status(@moona2a.Completed))
}

///|
impl @moona2a.Executor for Peeking with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
pub extend Peeking with @moona2a.Executor::{execute, cancel}

///|
async test "asgi: the headers a request arrived with reach the agent" {
  let seen : Ref[Array[(String, String)]] = Ref([])
  let server = @moona2a.Server::new(Peeking::{ seen, }, card_of())
  let app = @asgi.to_asgi(server)
  let events = drive(
    app,
    scope_of("POST", "/", [
      ("a2a-version", "1.0"),
      ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
      ("x-tenant", "t-1"),
    ]),
    send_body(),
  )
  let (status, _, body) = response_of(events)
  assert_eq(status, 200)
  assert_true(body.contains("TASK_STATE_COMPLETED"))
  let headers = seen.val
  let mut tenant = None
  let mut trace = None
  for pair in headers {
    if pair.0.to_lower() == "x-tenant" {
      tenant = Some(pair.1)
    }
    if pair.0.to_lower() == "traceparent" {
      trace = Some(pair.1)
    }
  }
  assert_eq(tenant, Some("t-1"))
  assert_eq(
    trace,
    Some("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
  )
}
