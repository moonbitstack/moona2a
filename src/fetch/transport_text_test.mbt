// What the transport accepts from the other end: an answer is read as JSON, and then as the message
// the protocol says it is. Neither step repairs what it cannot read.

///|
/// Answer the one call a test makes with a body of its own.
async fn answer_with_body(listener : @http.Server, body : String) -> Unit {
  let (connection, _) = listener.accept()
  let _ = connection.read_request()
  let extra : Map[@http.CaseInsensitiveString, String] = Map([])
  extra[@http.CaseInsensitiveString("content-type")] = "application/json"
  connection.send_response(200, "OK", extra_headers=extra)
  connection.write(@utf8.encode(body))
  connection.end_response()
  connection.close()
}

///|
/// Read a task from a transport that answers with `body`, and hold the read to failing.
async fn reading_a_task_fails(body : String) -> Unit {
  let listener = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port()
  let client = @moona2a.Client::new(
    @fetch.HttpTransport::new("http://127.0.0.1:\{port}"),
  )
  @async.with_task_group(async fn(group) {
    group.spawn_bg(allow_failure=true) <| () => {
      answer_with_body(listener, body)
    }
    let refused = try {
      let _ = client.get_task("t-1")
      false
    } catch {
      _ => true
    }
    assert_true(refused)
  })
  listener.close()
}

///|
/// A task as an answer, which reads when nothing but the grammar says otherwise.
let answered_task : String = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"id\":\"t-1\",\"contextId\":\"c-1\",\"status\":{\"state\":\"TASK_STATE_COMPLETED\"}}}"

///|
async test "fetch: an answer that is not a JSON-RPC message is refused" {
  reading_a_task_fails("[1,2,3]")
}

///|
async test "fetch: an answer with a comment in it is refused" {
  reading_a_task_fails(
    "{\"jsonrpc\":\"2.0\",\"id\":1,/* a note */\"result\":{\"id\":\"t-1\",\"contextId\":\"c-1\",\"status\":{\"state\":\"TASK_STATE_COMPLETED\"}}}",
  )
}

///|
async test "fetch: an answer nested past the reader's bound is refused, not parsed" {
  let body = StringBuilder()
  for _ in 0..<600 {
    body.write_char('[')
  }
  for _ in 0..<600 {
    body.write_char(']')
  }
  reading_a_task_fails(body.to_string())
}

///|
async test "fetch: a task as an answer reads" {
  // The same body the refusals above are held against, so what differs is the text and not the
  // call: a reader that refused everything would pass those three and fail this one.
  let listener = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port()
  let client = @moona2a.Client::new(
    @fetch.HttpTransport::new("http://127.0.0.1:\{port}"),
  )
  @async.with_task_group(async fn(group) {
    group.spawn_bg(allow_failure=true) <| () => {
      answer_with_body(listener, answered_task)
    }
    let task = client.get_task("t-1")
    assert_eq(task.id, "t-1")
    assert_eq(task.status.state.wire(), "TASK_STATE_COMPLETED")
  })
  listener.close()
}
