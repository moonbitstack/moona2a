// The HTTP+JSON binding (section 11): a method per verb and path, the request message from the
// path, the query and the body, and a refusal as a `google.rpc.Status` with HTTP's own code.

///|
/// The media type of every body this binding writes (section 11.1).
let rest_media : String = "application/a2a+json"

///|
/// What a verb and a path come to.
priv enum Found {
  /// A method, with the request fields the path carries.
  Call(@moona2a.Method, Map[String, Json])
  /// A known path asked with a verb it does not answer; the verbs it does.
  Verb(Array[String])
  /// No method lives here.
  Nowhere
}

///|
/// The methods a path of the binding answers, by verb, and the fields the path names. A path
/// that is not one of the table's is tried again with its first segment as the tenant, which is
/// how `a2a.proto` lets `/{tenant}` prefix every route.
fn shape(
  segments : ArrayView[String],
) -> (Array[(String, @moona2a.Method)], Map[String, Json])? {
  match segments {
    ["message:send"] => Some(([("POST", SendMessage)], Map([])))
    ["message:stream"] => Some(([("POST", SendStreamingMessage)], Map([])))
    ["tasks"] => Some(([("GET", ListTasks)], Map([])))
    ["extendedAgentCard"] => Some(([("GET", GetExtendedCard)], Map([])))
    ["tasks", named] =>
      match named.rev_find(":") {
        Some(colon) => {
          let id = named.exact_view(start=0, end=colon).to_owned()
          match named.exact_view(start=colon + 1, end=named.length()) {
            "cancel" =>
              Some(([("POST", CancelTask)], { "id": Json::string(id) }))
            "subscribe" =>
              Some(
                (
                  [("POST", SubscribeToTask), ("GET", SubscribeToTask)],
                  { "id": Json::string(id) },
                ),
              )
            _ => Some(([("GET", GetTask)], { "id": Json::string(named) }))
          }
        }
        None => Some(([("GET", GetTask)], { "id": Json::string(named) }))
      }
    ["tasks", task_id, "pushNotificationConfigs"] =>
      Some(
        (
          [("POST", CreatePushConfig), ("GET", ListPushConfigs)],
          { "taskId": Json::string(task_id) },
        ),
      )
    ["tasks", task_id, "pushNotificationConfigs", id] =>
      Some(
        (
          [("GET", GetPushConfig), ("DELETE", DeletePushConfig)],
          { "taskId": Json::string(task_id), "id": Json::string(id) },
        ),
      )
    [tenant, .. rest] if tenant != "" && rest.length() > 0 =>
      match shape(rest) {
        Some((verbs, fields)) => {
          fields["tenant"] = Json::string(tenant)
          Some((verbs, fields))
        }
        None => None
      }
    _ => None
  }
}

///|
/// The method `verb` and `path` ask for, under `prefix`.
fn find(verb : String, path : String, prefix : String) -> Found {
  guard path.has_prefix(prefix) else { return Nowhere }
  let rest = path.exact_view(start=prefix.length(), end=path.length())
  guard rest.has_prefix("/") else { return Nowhere }
  let segments = rest
    .exact_view(start=1, end=rest.length())
    .split("/")
    .map(segment => segment.to_owned())
    .collect()
  match shape(segments[:]) {
    Some((verbs, fields)) =>
      match verbs.iter().find_first(pair => pair.0 == verb) {
        Some((_, rpc)) => Call(rpc, fields)
        None => Verb(verbs.map(pair => pair.0))
      }
    None => Nowhere
  }
}

///|
/// The query fields `a2a.proto` types as numbers and as booleans; every other one is a string,
/// which is how an enum and a timestamp travel too (section 11.5).
fn query_value(name : String, text : String) -> Json raise @moonjrpc.Failed {
  match name {
    "historyLength" | "pageSize" => {
      let value = @string.parse_int(text) catch {
        _ =>
          raise @moona2a.InvalidParams("\{name} is not a whole number: \{text}").as_failed()
      }
      Json::number(value.to_double(), repr=text)
    }
    "includeArtifacts" =>
      match text {
        "true" => Json::boolean(true)
        "false" => Json::boolean(false)
        _ =>
          raise @moona2a.InvalidParams("\{name} is not true or false: \{text}").as_failed()
      }
    _ => Json::string(text)
  }
}

///|
/// The request message: the body's fields, then the query's, then the path's, each later one
/// winning, as the Python SDK fills a request from the path after parsing the rest.
fn request_of(
  body : Bytes,
  query : Bytes,
  fields : Map[String, Json],
) -> Json raise @moonjrpc.Failed {
  let request : Map[String, Json] = Map([])
  if body.length() > 0 {
    let text = @utf8.decode(body) catch {
      _ => raise @moona2a.InvalidRequest("the body is not UTF-8").as_failed()
    }
    let json = @moonjson.loads(text, @moonjson.strict) catch {
      _ => raise @moona2a.InvalidRequest("the body is not JSON").as_failed()
    }
    guard json is Object(given) else {
      raise @moona2a.InvalidRequest("the body is not a JSON object").as_failed()
    }
    given.each((name, value) => request[name] = value)
  }
  if query.length() > 0 {
    let pairs = @moonurl.Query::decode(query) catch {
      _ =>
        raise @moona2a.InvalidRequest("the query does not decode").as_failed()
    }
    for pair in pairs.entries() {
      request[pair.0] = query_value(pair.0, pair.1)
    }
  }
  fields.each((name, value) => request[name] = value)
  Json::object(request)
}

///|
/// Answer one request of the binding.
async fn serve_rest(
  server : @moona2a.Server,
  http : @spec.HttpScope,
  body : Bytes,
  rpc : @moona2a.Method,
  fields : Map[String, Json],
  send : @moonasgi.Send,
) -> Unit {
  let extensions = extension_header(http.headers)
  let version = header_of(http.headers, "a2a-version").unwrap_or("")
  let params = request_of(body, http.query_string, fields) catch {
    error => {
      send_response(send, rest_refusal(@moona2a.failure_of(error)))
      return
    }
  }
  if rpc.streams() {
    let events = Events::{ send, opened: false, }
    server.invoke_stream(
      rpc,
      events,
      params~,
      extensions~,
      version~,
      headers=http.headers,
    ) catch {
      error => {
        let failure = @moona2a.failure_of(error)
        if events.opened {
          events.frame(@moonjson.dumps(rest_error(failure)), event="error") catch {
            _ => ()
          }
        } else {
          send_response(send, rest_refusal(failure))
          return
        }
      }
    }
    if !events.opened {
      events.open() catch {
        _ => ()
      }
    }
    send_stop(send)
    return
  }
  let answer = server.invoke(
    rpc,
    params~,
    extensions~,
    version~,
    headers=http.headers,
  ) catch {
    error => {
      send_response(send, rest_refusal(@moona2a.failure_of(error)))
      return
    }
  }
  // `DeleteTaskPushNotificationConfig` answers `google.protobuf.Empty`, which is `{}` in JSON.
  let shown = if answer is Null { Json::object({}) } else { answer }
  send_response(send, rest_response(200, @moonjson.dumps(shown)))
}

///|
/// A refusal as section 11.6 writes it: the HTTP status in `code`, the gRPC status name in
/// `status`, and the `ErrorInfo` the failure carries in `details`.
fn rest_error(failure : @moonjrpc.Failure) -> Json {
  let status = @moona2a.Status::of(failure.code)
  let details = match failure.data {
    Some(Array(items)) => items
    _ => []
  }
  Json::object({
    "error": Json::object({
      "code": Json::number(
        status.http.to_double(),
        repr=status.http.to_string(),
      ),
      "status": Json::string(status.name),
      "message": Json::string(failure.message),
      "details": Json::array(details),
    }),
  })
}

///|
/// The response that carries a refusal.
fn rest_refusal(failure : @moonjrpc.Failure) -> @moonasgi.Response {
  rest_response(
    @moona2a.Status::of(failure.code).http,
    @moonjson.dumps(rest_error(failure)),
  )
}

///|
/// A JSON answer of the binding.
fn rest_response(status : Int32, text : String) -> @moonasgi.Response {
  @moonasgi.Response::new(
    status,
    [("content-type", rest_media), ("cache-control", "no-store")],
    @utf8.encode(text),
  )
}

///|
/// The answer to a known path asked with the wrong verb.
fn rest_wrong_verb(verbs : Array[String]) -> @moonasgi.Response {
  let failure : @moonjrpc.Failure = {
    code: @moonjrpc.method_not_found,
    message: "this path answers \{verbs.join(", ")}",
    data: None,
  }
  let response = rest_refusal(failure)
  @moonasgi.Response::new(
    405,
    [..response.headers, ("allow", verbs.join(", "))],
    response.body,
  )
}

///|
/// A sink that writes each event as a server-sent event whose data is a `StreamResponse`. The
/// response opens with the first event, so a call refused before it starts is an ordinary error
/// answer rather than a stream that carries one.
struct Events {
  send : @moonasgi.Send
  mut opened : Bool
}

///|
async fn Events::open(self : Events) -> Unit {
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

///|
/// Write one event, opening the response the first time. A refusal mid-stream goes out under
/// the event name `error`, as the Python SDK writes it.
async fn Events::frame(self : Events, data : String, event? : String) -> Unit {
  if !self.opened {
    self.open()
  }
  let head = match event {
    Some(name) => "event: \{name}\n"
    None => ""
  }
  (self.send)(
    @spec.HttpResponseBody(
      body=@utf8.encode("\{head}data: \{data}\n\n"),
      more_body=true,
    ),
  )
}

///|
impl @moona2a.EventSink for Events with fn emit(self, event) {
  self.frame(@moonjson.dumps(event.to_json()))
}

///|
pub extend Events with @moona2a.EventSink::{emit}
