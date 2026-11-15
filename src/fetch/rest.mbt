// A client that speaks the HTTP+JSON binding (section 11): each call goes to its own verb and
// path, and an answer or a refusal comes back as the JSON-RPC message the client reads.

///|
/// The HTTP+JSON endpoint of one agent.
pub(all) struct RestTransport {
  client : @moonfetch.Client
  /// The path the card is served at.
  card_path : String
  /// Headers to add to every request, read as each one is built.
  extra : () -> Array[(String, String)]
}

///|
/// A transport to the agent whose HTTP+JSON routes hang off `url`, as its card's interface gives
/// it. The `headers` callback supplies headers for every request; the headers a call names take
/// precedence over them.
pub fn RestTransport::new(
  url : String,
  card_path? : String,
  headers? : () -> Array[(String, String)],
) -> RestTransport raise {
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
    card_path: card_path.unwrap_or(@moona2a.card_path),
    extra: headers.unwrap_or(fn() { ([] : Array[(String, String)]) }),
  }
}

///|
/// One call laid out for the binding: the verb, the path with its identifiers and tenant filled
/// in, the query of a call without a body, and the body of one with.
priv struct Request {
  verb : @method.Method
  path : String
  query : Array[(String, String)]
  body : @moonfetch.Body?
}

///|
/// Lay out a call of `rpc` with `params`, the JSON form of its request message.
fn request_of(rpc : @moona2a.Method, params : Json) -> Request raise {
  let fields = match params {
    Object(fields) => fields
    Null => Map([])
    _ => raise WrongShape("the parameters of \{rpc.name()} are not an object")
  }
  let (verb, template) = rpc.rest()
  // The task's id is `id` in a task request and `taskId` in a push configuration's.
  let (task_key, config_key) = if template.contains("{configId}") ||
    template.contains("pushNotificationConfigs") {
    ("taskId", Some("id"))
  } else {
    ("id", None)
  }
  let in_path : Array[String] = ["tenant"]
  let mut path = template
  if template.contains("{id}") {
    path = path.replace(old="{id}", new=escaped(fields, task_key))
    in_path.push(task_key)
  }
  if template.contains("{configId}") && config_key is Some(key) {
    path = path.replace(old="{configId}", new=escaped(fields, key))
    in_path.push(key)
  }
  if fields.get("tenant") is Some(String(tenant)) && tenant != "" {
    path = "/\{@moonurl.escape_text(tenant)}\{path}"
  }
  if verb == "POST" {
    let body = Map([])
    fields.each((name, value) => {
      if !in_path.contains(name) {
        body[name] = value
      }
    })
    return {
      verb: Post,
      path,
      query: [],
      body: Some(@moonfetch.Body::Text(@moonjson.dumps(Json::object(body)))),
    }
  }
  let query : Array[(String, String)] = []
  fields.each((name, value) => {
    if in_path.contains(name) {
      return
    }
    match value {
      String(text) => query.push((name, text))
      Number(_, repr=Some(text)) => query.push((name, text))
      Number(number, ..) => query.push((name, number.to_int64().to_string()))
      True => query.push((name, "true"))
      False => query.push((name, "false"))
      _ => ()
    }
  })
  {
    verb: if verb == "DELETE" {
      Delete
    } else {
      Get
    },
    path,
    query,
    body: None,
  }
}

///|
/// The value of `key` as one path segment.
fn escaped(fields : Map[String, Json], key : String) -> String raise {
  match fields.get(key) {
    Some(String(text)) => @moonurl.escape_text(text)
    _ => raise WrongShape("the call names no \{key}")
  }
}

///|
/// The JSON-RPC failure an error answer of the binding stands for.
fn refusal_of(status : Int32, text : String) -> @moonjrpc.Failure {
  let body = @moonjson.loads(text, @moonjson.strict) catch { _ => Json::null() }
  let error = match body {
    Object(body) => body.get("error")
    _ => None
  }
  match error {
    Some(Object(error)) => {
      let grpc = match error.get("status") {
        Some(String(name)) => grpc_of(name, status)
        _ => grpc_of("", status)
      }
      let message = match error.get("message") {
        Some(String(message)) => message
        _ => "HTTP \{status}"
      }
      let details = match error.get("details") {
        Some(Array(details)) => details
        _ => []
      }
      @moona2a.failure_of_status(grpc, message, details)
    }
    _ => @moona2a.failure_of_status(grpc_of("", status), text, [])
  }
}

///|
/// The gRPC code an error answer names in `status`, else the one its HTTP status stands for.
fn grpc_of(name : String, http : Int32) -> Int32 {
  match name {
    "INVALID_ARGUMENT" => 3
    "NOT_FOUND" => 5
    "FAILED_PRECONDITION" => 9
    "UNIMPLEMENTED" => 12
    "INTERNAL" => 13
    _ =>
      match http {
        400 => 3
        404 => 5
        405 | 501 => 12
        _ => 13
      }
  }
}

///|
/// Send one call and read the answer.
async fn RestTransport::reply(
  self : RestTransport,
  message : @moonjrpc.Message,
  headers : Array[(String, String)],
) -> @moonjrpc.Message {
  guard message is Call(id~, name~, params~) else {
    raise WrongShape("only a call has an answer")
  }
  guard @moona2a.Method::from_name(name) is Some(rpc) else {
    return @moonjrpc.Message::Refusal(id~, failure={
      code: @moonjrpc.method_not_found,
      message: "the HTTP+JSON binding has no \{name}",
      data: None,
    })
  }
  let request = request_of(rpc, params.unwrap_or(Json::null()))
  let response = self.client.request(
    request.verb,
    request.path,
    query=request.query,
    headers=headers_for(
      self.extra,
      [("content-type", "application/a2a+json"), ("accept", "application/json")],
      headers,
    ),
    body?=request.body,
  )
  let text = response.text()
  if !response.is_success() {
    return @moonjrpc.Message::Refusal(
      id~,
      failure=refusal_of(response.status, text),
    )
  }
  let result = if text.trim() == "" {
    Json::object({})
  } else {
    @moonjson.loads(text, @moonjson.strict) catch {
      _ => raise WrongShape("the answer is not JSON: \{text}")
    }
  }
  @moonjrpc.Message::Reply(id~, result~)
}

///|
/// Send one streaming call and hand each event to `out` as it arrives, as the reply the JSON-RPC
/// binding would have sent for it.
async fn RestTransport::deliver(
  self : RestTransport,
  message : @moonjrpc.Message,
  out : &@moona2a.ReplySink,
  headers : Array[(String, String)],
) -> Unit {
  guard message is Call(id~, name~, params~) &&
    @moona2a.Method::from_name(name) is Some(rpc) else {
    out.reply(self.reply(message, headers))
    return
  }
  let request = request_of(rpc, params.unwrap_or(Json::null()))
  let stream = self.client.stream(
    request.verb,
    request.path,
    query=request.query,
    headers=headers_for(
      self.extra,
      [
        ("content-type", "application/a2a+json"),
        ("accept", "text/event-stream"),
      ],
      headers,
    ),
    body?=request.body,
  )
  defer stream.close()
  if !is_event_stream(stream.header("content-type")) {
    let text = stream.text()
    out.reply(
      @moonjrpc.Message::Refusal(id~, failure=refusal_of(stream.status(), text)),
    )
    return
  }
  each_event(stream, async fn(event) {
    if event.data.trim() == "" {
      return
    }
    if event.kind == Some("error") {
      out.reply(
        @moonjrpc.Message::Refusal(id~, failure=refusal_of(500, event.data)),
      )
      return
    }
    let result = @moonjson.loads(event.data, @moonjson.strict) catch {
      _ => raise WrongShape("an event is not JSON: \{event.data}")
    }
    out.reply(@moonjrpc.Message::Reply(id~, result~))
  })
}

///|
pub impl @moona2a.Transport for RestTransport with fn exchange(self, message) {
  self.reply(message, [])
}

///|
pub impl @moona2a.Transport for RestTransport with fn exchange_with(
  self,
  message,
  headers,
) {
  self.reply(message, headers)
}

///|
pub impl @moona2a.Transport for RestTransport with fn stream(self, message, out) {
  self.deliver(message, out, [])
}

///|
pub impl @moona2a.Transport for RestTransport with fn stream_with(
  self,
  message,
  out,
  headers,
) {
  self.deliver(message, out, headers)
}

///|
pub impl @moona2a.Transport for RestTransport with fn discover(self) {
  card_of(
    self.client,
    self.card_path,
    headers_for(self.extra, [("accept", "application/json")], []),
  )
}

///|
pub impl @moona2a.Transport for RestTransport with fn discover_with(
  self,
  headers,
) {
  card_of(
    self.client,
    self.card_path,
    headers_for(self.extra, [("accept", "application/json")], headers),
  )
}

///|
pub extend RestTransport with @moona2a.Transport::{
  exchange,
  exchange_with,
  stream,
  stream_with,
  discover,
  discover_with,
}
