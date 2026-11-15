// The HTTP+JSON binding: routes, request messages from path, query and body, and refusals.

///|
/// A request of the binding, with the version header a 1.0 client sends.
fn rest_scope(
  verb : String,
  path : String,
  query? : String,
  headers? : Array[(String, String)],
) -> @moonasgi.Scope {
  guard scope_of(verb, path, headers.unwrap_or([("a2a-version", "1.0")]))
    is @spec.Http(http) else {
    abort("scope_of builds an HTTP scope")
  }
  @spec.Http({ ..http, query_string: @utf8.encode(query.unwrap_or("")), })
}

///|
/// The JSON of a response body.
fn json_of(body : String) -> Json raise {
  @moonjson.loads(body, @moonjson.strict) catch {
    _ => fail("the body is not JSON: \{body}")
  }
}

///|
/// A field of an object, or a failure naming it.
fn field(json : Json, name : String) -> Json raise {
  guard json is Object(fields) && fields.get(name) is Some(value) else {
    fail("no \{name} in \{@moonjson.dumps(json)}")
  }
  value
}

///|
/// A send of one text message as the HTTP+JSON body.
fn rest_send(message_id : String) -> Bytes {
  @utf8.encode(
    "{\"message\":{\"messageId\":\"\{message_id}\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"hi\"}]}}",
  )
}

///|
/// Send one message and return the id of the task it opened.
async fn sent_task(app : @moonasgi.AsgiApp) -> String {
  let (status, _, body) = response_of(
    drive(app, rest_scope("POST", "/message:send"), rest_send("m-1")),
  )
  let id = Some(field(field(json_of(body), "task"), "id")) catch { _ => None }
  guard status == 200 && id is Some(String(id)) else {
    abort("the send did not open a task: \{status} \{body}")
  }
  id
}

///|
/// The status, gRPC name and `ErrorInfo` reason of a refusal body.
fn refusal_of(body : String) -> (Int32, String, String) raise {
  let error = field(json_of(body), "error")
  guard field(error, "code") is Number(code, ..) &&
    field(error, "status") is String(name) &&
    field(error, "details") is Array(details) &&
    details.length() > 0 &&
    field(details[0], "reason") is String(reason) &&
    field(details[0], "domain") is String("a2a-protocol.org") else {
    fail("not a google.rpc.Status with an ErrorInfo: \{body}")
  }
  (code.to_int(), name, reason)
}

///|
async test "rest: a send answers with the task under the A2A media type" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let (status, headers, body) = response_of(
    drive(app, rest_scope("POST", "/message:send"), rest_send("m-1")),
  )
  assert_eq(status, 200)
  assert_eq(head_of(headers, "content-type"), Some("application/a2a+json"))
  let task = field(json_of(body), "task")
  assert_eq(
    field(field(task, "status"), "state"),
    Json::string("TASK_STATE_COMPLETED"),
  )
}

///|
async test "rest: a task is read back from its path, the query cutting its history" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let id = sent_task(app)
  let (status, _, body) = response_of(
    drive(app, rest_scope("GET", "/tasks/\{id}", query="historyLength=0"), b""),
  )
  assert_eq(status, 200)
  let task = json_of(body)
  assert_eq(field(task, "id"), Json::string(id))
  let kept = task is Object(fields) &&
    fields.get("history") is Some(Array([_, ..]))
  assert_false(kept)
}

///|
async test "rest: an unknown task is a 404 carrying TASK_NOT_FOUND" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let (status, headers, body) = response_of(
    drive(app, rest_scope("GET", "/tasks/ghost"), b""),
  )
  assert_eq(status, 404)
  assert_eq(head_of(headers, "content-type"), Some("application/a2a+json"))
  assert_eq(refusal_of(body), (404, "NOT_FOUND", "TASK_NOT_FOUND"))
}

///|
async test "rest: cancelling a finished task is a 400 FAILED_PRECONDITION" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let id = sent_task(app)
  let (status, _, body) = response_of(
    drive(app, rest_scope("POST", "/tasks/\{id}:cancel"), b""),
  )
  assert_eq(status, 400)
  assert_eq(
    refusal_of(body),
    (400, "FAILED_PRECONDITION", "TASK_NOT_CANCELABLE"),
  )
}

///|
async test "rest: a caller without the version header is refused as a 0.3 client" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let (status, _, body) = response_of(
    drive(app, rest_scope("GET", "/tasks", headers=[]), b""),
  )
  assert_eq(status, 400)
  assert_eq(
    refusal_of(body),
    (400, "FAILED_PRECONDITION", "VERSION_NOT_SUPPORTED"),
  )
}

///|
async test "rest: a query number that does not read is INVALID_ARGUMENT" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let (status, _, body) = response_of(
    drive(app, rest_scope("GET", "/tasks", query="pageSize=many"), b""),
  )
  assert_eq(status, 400)
  assert_eq(refusal_of(body), (400, "INVALID_ARGUMENT", "INVALID_PARAMS"))
}

///|
async test "rest: a body that is not JSON is INVALID_ARGUMENT" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let (status, _, body) = response_of(
    drive(app, rest_scope("POST", "/message:send"), b"{not json"),
  )
  assert_eq(status, 400)
  assert_eq(refusal_of(body), (400, "INVALID_ARGUMENT", "INVALID_REQUEST"))
}

///|
async test "rest: a page of tasks follows the query" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  ignore(sent_task(app))
  ignore(sent_task(app))
  let (status, _, body) = response_of(
    drive(app, rest_scope("GET", "/tasks", query="pageSize=1"), b""),
  )
  assert_eq(status, 200)
  guard field(json_of(body), "tasks") is Array(tasks) else { fail(body) }
  assert_eq(tasks.length(), 1)
  assert_eq(field(json_of(body), "totalSize"), Json::number(2.0))
}

///|
async test "rest: a tenant in front of a path reaches the same method" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let (status, _, body) = response_of(
    drive(app, rest_scope("POST", "/acme/message:send"), rest_send("m-2")),
  )
  assert_eq(status, 200)
  let id = field(field(json_of(body), "task"), "id")
  guard id is String(id) else { fail(body) }
  let (status, _, _) = response_of(
    drive(app, rest_scope("GET", "/acme/tasks/\{id}"), b""),
  )
  assert_eq(status, 200)
}

///|
async test "rest: a known path asked with another verb is a 405 naming the verbs it answers" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let (status, headers, _) = response_of(
    drive(app, rest_scope("DELETE", "/message:send"), b""),
  )
  assert_eq(status, 405)
  assert_eq(head_of(headers, "allow"), Some("POST"))
}

///|
async test "rest: push configurations are created, read, listed and deleted by path" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let id = sent_task(app)
  let base = "/tasks/\{id}/pushNotificationConfigs"
  let (status, _, body) = response_of(
    drive(
      app,
      rest_scope("POST", base),
      @utf8.encode("{\"id\":\"cfg-1\",\"url\":\"https://hook.test/a\"}"),
    ),
  )
  assert_eq(status, 200)
  assert_eq(field(json_of(body), "taskId"), Json::string(id))
  let (status, _, body) = response_of(
    drive(app, rest_scope("GET", "\{base}/cfg-1"), b""),
  )
  assert_eq(status, 200)
  assert_eq(field(json_of(body), "url"), Json::string("https://hook.test/a"))
  let (_, _, body) = response_of(drive(app, rest_scope("GET", base), b""))
  guard field(json_of(body), "configs") is Array([_]) else { fail(body) }
  let (status, _, body) = response_of(
    drive(app, rest_scope("DELETE", "\{base}/cfg-1"), b""),
  )
  assert_eq(status, 200)
  assert_eq(body, "{}")
  let (_, _, body) = response_of(drive(app, rest_scope("GET", base), b""))
  guard field(json_of(body), "configs") is Array([]) else { fail(body) }
}

///|
async test "rest: a streaming send answers with StreamResponse events in the order they happened" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let (status, headers, text) = response_of(
    drive(app, rest_scope("POST", "/message:stream"), rest_send("m-3")),
  )
  assert_eq(status, 200)
  assert_eq(head_of(headers, "content-type"), Some("text/event-stream"))
  let kinds : Array[String] = []
  for line in text.split("\n") {
    guard line.strip_prefix("data: ") is Some(data) else { continue }
    match json_of(data.to_owned()) {
      Object(fields) =>
        if fields.get("task") is Some(_) {
          kinds.push("task")
        } else if fields.get("statusUpdate") is Some(update) {
          guard field(field(update, "status"), "state") is String(state) else {
            fail(data.to_owned())
          }
          kinds.push(state)
        }
      _ => fail(data.to_owned())
    }
  }
  assert_eq(kinds, ["task", "TASK_STATE_WORKING", "TASK_STATE_COMPLETED"])
}

///|
async test "rest: subscribing to a finished task is refused before any stream opens" {
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()))
  let id = sent_task(app)
  let (status, headers, body) = response_of(
    drive(app, rest_scope("POST", "/tasks/\{id}:subscribe"), b""),
  )
  assert_eq(status, 400)
  assert_eq(head_of(headers, "content-type"), Some("application/a2a+json"))
  assert_eq(
    refusal_of(body),
    (400, "FAILED_PRECONDITION", "UNSUPPORTED_OPERATION"),
  )
}

///|
async test "rest: with no REST path only JSON-RPC answers" {
  let options = { ..@asgi.Options::new(), rest_path: None, }
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()), options~)
  let (status, _, _) = response_of(
    drive(app, rest_scope("POST", "/message:send"), rest_send("m-4")),
  )
  assert_eq(status, 404)
}

///|
async test "rest: the routes hang off the configured path" {
  let options = { ..@asgi.Options::new(), rest_path: Some("/v1"), }
  let app = @asgi.to_asgi(@moona2a.Server::new(Echo::{ }, card_of()), options~)
  let (status, _, _) = response_of(
    drive(app, rest_scope("POST", "/v1/message:send"), rest_send("m-5")),
  )
  assert_eq(status, 200)
  let (status, _, _) = response_of(
    drive(app, rest_scope("POST", "/message:send"), rest_send("m-6")),
  )
  assert_eq(status, 404)
}
