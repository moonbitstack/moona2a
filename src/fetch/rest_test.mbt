// The HTTP+JSON client over a real socket: the verb, path and query a call goes out with, an
// error body read back as the A2A error it names, and a stream handed over event by event.

///|
/// What one request arrived as.
struct Seen {
  mut verb : String
  mut path : String
  mut body : String
}

///|
/// Answer the one request a test makes with `status`, `content_type` and `chunks`, written one
/// after another, and write down how the request arrived.
async fn serve_rest(
  listener : @http.Server,
  seen : Seen,
  status : Int32,
  content_type : String,
  chunks : Array[String],
) -> Unit {
  let (connection, _) = listener.accept()
  let request = connection.read_request()
  seen.verb = match request.meth {
    Get => "GET"
    Post => "POST"
    Delete => "DELETE"
    _ => "OTHER"
  }
  seen.path = request.path
  seen.body = @utf8.decode_lossy(connection.read_all().binary())
  let extra : Map[@http.CaseInsensitiveString, String] = Map([])
  extra[@http.CaseInsensitiveString("content-type")] = content_type
  connection.send_response(status, "OK", extra_headers=extra)
  for chunk in chunks {
    connection.write(@utf8.encode(chunk))
    connection.flush()
  }
  connection.end_response()
  connection.close()
}

///|
/// Run `call` against a server answering once as given, and return how the request arrived.
async fn against(
  status : Int32,
  content_type : String,
  chunks : Array[String],
  call : async (@moona2a.Client) -> Unit,
) -> Seen {
  let listener = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port()
  let seen = Seen::{ verb: "", path: "", body: "", }
  let client = @moona2a.Client::new(
    @fetch.RestTransport::new("http://127.0.0.1:\{port}"),
  )
  @async.with_task_group(async fn(group) {
    group.spawn_bg(allow_failure=true) <| () => {
      serve_rest(listener, seen, status, content_type, chunks)
    }
    call(client)
  })
  listener.close()
  seen
}

///|
/// A finished task as the binding writes it.
fn task_text(id : String) -> String {
  @moona2a.Task::new(id, "c-1")
  .with_state(@moona2a.Completed)
  .to_json()
  .stringify()
}

///|
async test "fetch rest: a task is asked for by its path, with the history in the query" {
  let seen = against(200, "application/a2a+json", [task_text("t 1")], async fn(
    client,
  ) {
    let task = client.get_task("t 1", history_length=2)
    assert_eq(task.id, "t 1")
  })
  assert_eq(seen.verb, "GET")
  assert_eq(seen.path, "/tasks/t%201?historyLength=2")
}

///|
async test "fetch rest: a cancellation posts to the task's cancel path" {
  let seen = against(200, "application/a2a+json", [task_text("t-2")], async fn(
    client,
  ) {
    ignore(client.cancel_task("t-2"))
  })
  assert_eq(seen.verb, "POST")
  assert_eq(seen.path, "/tasks/t-2:cancel")
  assert_eq(seen.body, "{}")
}

///|
async test "fetch rest: an error body reads back as the A2A error its ErrorInfo names" {
  let body =
    #|{"error":{"code":404,"status":"NOT_FOUND","message":"Task not found","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"TASK_NOT_FOUND","domain":"a2a-protocol.org"}]}}
  let refused = Ref(false)
  ignore(
    against(404, "application/a2a+json", [body], async fn(client) {
      try client.get_task("ghost") |> ignore catch {
        @moona2a.TaskNotFound(_) => refused.val = true
        _ => ()
      }
    }),
  )
  assert_true(refused.val)
}

///|
async test "fetch rest: a push configuration is deleted at its own path" {
  let seen = against(200, "application/a2a+json", ["{}"], async fn(client) {
    client.delete_push_config("t-3", "cfg 1")
  })
  assert_eq(seen.verb, "DELETE")
  assert_eq(seen.path, "/tasks/t-3/pushNotificationConfigs/cfg%201")
}

///|
/// A sink that keeps every reply.
struct Kept {
  replies : Array[@moonjrpc.Message]
}

///|
impl @moona2a.ReplySink for Kept with fn reply(self, message) {
  self.replies.push(message)
}

///|
async test "fetch rest: a streamed send hands over each event, a block split across chunks included" {
  let kept = Kept::{ replies: [], }
  let first = "data: {\"task\":\{task_text("t-4")}}\n\n"
  let seen = against(
    200,
    "text/event-stream",
    [
      first, "data: {\"statusUpdate\":{\"taskId\":\"t-4\",\"contextId\":\"c-1\",",
      "\"status\":{\"state\":\"TASK_STATE_COMPLETED\"}}}\r\n\r\n",
    ],
    async fn(client) {
      client.send_streaming_message(@moona2a.Message::user("m-1", "hi"), kept)
    },
  )
  assert_eq(seen.verb, "POST")
  assert_eq(seen.path, "/message:stream")
  assert_eq(kept.replies.length(), 2)
  assert_true(
    kept.replies.iter().all(reply => reply is @moonjrpc.Message::Reply(..)),
  )
}
