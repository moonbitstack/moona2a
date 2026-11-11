// Per-call headers on a real request: a fake transport cannot tell whether a header
// was sent twice, spelled twice, or sent at all. These talk to a server on a port the
// system picks and read back what it saw.

///|
/// Answer one request with `body`, writing down the headers it arrived with.
async fn serve_one_request(
  listener : @http.Server,
  seen : Ref[Array[(String, String)]],
  body : String,
  content_type : String,
) -> Unit {
  let (connection, _) = listener.accept()
  let request = connection.read_request()
  let headers : Array[(String, String)] = []
  for pair in request.headers {
    headers.push((pair.0.to_string(), pair.1))
  }
  seen.val = headers
  let extra : Map[@http.CaseInsensitiveString, String] = Map([])
  extra[@http.CaseInsensitiveString("content-type")] = content_type
  connection.send_response(200, "OK", extra_headers=extra)
  connection.write(@utf8.encode(body))
  connection.end_response()
  connection.close()
}

///|
/// A card the client can read from the well-known address.
fn card_body() -> String {
  @moona2a.AgentCard::new(
    "canned",
    "answers from a table",
    "1.0.0",
    "https://canned.test",
    [],
  )
  .to_json()
  .stringify()
}

///|
/// One server-sent event, carrying the task a stream opens with.
fn stream_body() -> String {
  let event = @moona2a.StreamEvent::TaskSnapshot(
    @moona2a.Task::new("t-1", "c-1"),
  )
  let reply = Json::object({
    "jsonrpc": Json::string("2.0"),
    "id": Json::number(1.0),
    "result": event.to_json(),
  })
  "data: " + reply.stringify() + "\n\n"
}

///|
/// A sink that keeps the replies a streamed answer carries.
struct Held {
  replies : Array[@moonjrpc.Message]
}

///|
impl @moona2a.ReplySink for Held with fn reply(self, message) {
  self.replies.push(message)
}

///|
/// Read `name` out of the headers a server saw, whatever case it arrived in.
fn seen_header(headers : Array[(String, String)], name : String) -> String? {
  for pair in headers {
    if pair.0.to_lower() == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// How many times `name` was sent, counted without assuming what case it had.
fn seen_times(headers : Array[(String, String)], name : String) -> Int32 {
  let mut count = 0
  for pair in headers {
    if pair.0.to_lower() == name {
      count += 1
    }
  }
  count
}

///|
async test "fetch: a call's own headers reach the wire, and the call wins a clash" {
  let listener = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port()
  let seen : Ref[Array[(String, String)]] = Ref([])
  let transport = @fetch.HttpTransport::new("http://127.0.0.1:\{port}", headers=fn() {
    [("x-tenant", "host"), ("x-mode", "host")]
  })
  let client = @moona2a.Client::new(transport)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(allow_failure=true) <| () => {
      serve_one_request(listener, seen, answer_of(), "application/json")
    }
    let task = client.get_task("t-1", headers=[
      ("x-call", "one"),
      ("x-tenant", "call"),
    ])
    assert_eq(task.id, "t-1")
  })
  listener.close()
  let headers = seen.val
  assert_eq(seen_header(headers, "x-call"), Some("one"))
  assert_eq(seen_header(headers, "x-mode"), Some("host"))
  // The host and this call both named the tenant; only the call's value is sent.
  assert_eq(seen_header(headers, "x-tenant"), Some("call"))
  assert_eq(seen_times(headers, "x-tenant"), 1)
  assert_eq(seen_header(headers, "a2a-version"), Some("1.0"))
}

///|
async test "fetch: reading a card carries the headers of that call" {
  let listener = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port()
  let seen : Ref[Array[(String, String)]] = Ref([])
  let transport = @fetch.HttpTransport::new("http://127.0.0.1:\{port}")
  let client = @moona2a.Client::new(transport)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(allow_failure=true) <| () => {
      serve_one_request(listener, seen, card_body(), "application/json")
    }
    let card = client.discover(headers=[("x-call", "card")])
    assert_eq(card.name, "canned")
  })
  listener.close()
  assert_eq(seen_header(seen.val, "x-call"), Some("card"))
  assert_eq(seen_header(seen.val, "a2a-version"), Some("1.0"))
}

///|
async test "fetch: a streamed call carries the headers of that call" {
  let listener = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port()
  let seen : Ref[Array[(String, String)]] = Ref([])
  let transport = @fetch.HttpTransport::new("http://127.0.0.1:\{port}")
  let client = @moona2a.Client::new(transport)
  let held : Held = { replies: [], }
  @async.with_task_group(async fn(group) {
    group.spawn_bg(allow_failure=true) <| () => {
      serve_one_request(listener, seen, stream_body(), "text/event-stream")
    }
    client.send_streaming_message(@moona2a.Message::user("m-1", "hi"), held, headers=[
      ("x-call", "stream"),
    ])
  })
  listener.close()
  assert_eq(held.replies.length(), 1)
  assert_eq(seen_header(seen.val, "x-call"), Some("stream"))
  assert_eq(seen_header(seen.val, "accept"), Some("text/event-stream"))
}
