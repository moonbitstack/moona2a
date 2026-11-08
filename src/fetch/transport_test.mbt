// What goes on the wire: one call over a real socket, and the headers the server saw.
// A fake transport cannot tell whether a header was sent, which is why this one talks to a
// server on a port the system picks.

///|
/// The answer to any call: the task the client asked about. The id is the one a client
/// starts from, and nothing on either side pairs by it here.
fn answer_of() -> String {
  let task = @moona2a.Task::new("t-1", "c-1")
    .with_state(@moona2a.Completed)
    .to_json()
  Json::object({
    "jsonrpc": Json::string("2.0"),
    "id": Json::number(1.0),
    "result": task,
  }).stringify()
}

///|
/// Answer the one call a test makes, writing down the headers it arrived with.
async fn serve_one_call(
  listener : @http.Server,
  seen : Ref[Array[(String, String)]],
) -> Unit {
  let (connection, _) = listener.accept()
  let request = connection.read_request()
  let headers : Array[(String, String)] = []
  for pair in request.headers {
    headers.push((pair.0.to_string(), pair.1))
  }
  seen.val = headers
  let extra : Map[@http.CaseInsensitiveString, String] = Map([])
  extra[@http.CaseInsensitiveString("content-type")] = "application/json"
  connection.send_response(200, "OK", extra_headers=extra)
  connection.write(@utf8.encode(answer_of()))
  connection.end_response()
  connection.close()
}

///|
async test "fetch: the headers the host supplies ride on the request" {
  let listener = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port()
  let seen : Ref[Array[(String, String)]] = Ref([])
  let transport = @fetch.HttpTransport::new("http://127.0.0.1:\{port}", headers=fn() {
    [
      ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
      ("x-tenant", "t-1"),
    ]
  })
  let client = @moona2a.Client::new(transport)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(allow_failure=true) <| () => {
      serve_one_call(listener, seen)
    }
    let task = client.get_task("t-1")
    assert_eq(task.id, "t-1")
  })
  listener.close()
  let mut trace = None
  let mut tenant = None
  let mut version = None
  for pair in seen.val {
    match pair.0.to_lower() {
      "traceparent" => trace = Some(pair.1)
      "x-tenant" => tenant = Some(pair.1)
      "a2a-version" => version = Some(pair.1)
      _ => ()
    }
  }
  assert_eq(
    trace,
    Some("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
  )
  assert_eq(tenant, Some("t-1"))
  // What the transport always sent is still there.
  assert_eq(version, Some("1.0"))
}
