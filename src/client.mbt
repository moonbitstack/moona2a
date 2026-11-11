// The calling side: the methods a server answers, invoked over a transport that carries JSON-RPC.
// `moona2a/http` supplies one over HTTP; a test supplies one that answers from a table.

///|
/// Headers belonging to one call, in the spelling the wire uses: the name, then the value.
pub type Headers = Array[(String, String)]

///|
/// `overlay` on top of `base`: a name the two share keeps the overlay's value and spelling,
/// so one request never carries two values for a header the protocol reads. Header names are
/// case-insensitive on the wire.
pub fn merge_headers(base : Headers, overlay : Headers) -> Headers {
  let headers : Headers = []
  for pair in base {
    headers.push(pair)
  }
  for pair in overlay {
    let name = pair.0.to_lower()
    let mut placed = false
    for i in 0..<headers.length() {
      if headers[i].0.to_lower() == name {
        headers[i] = pair
        placed = true
        break
      }
    }
    if !placed {
      headers.push(pair)
    }
  }
  headers
}

///|
/// How a client reaches an agent. A transport carries JSON-RPC messages and finds the card; it
/// knows nothing about tasks.
///
/// The three `*_with` methods are the same calls with the headers of that call alone. Their
/// defaults drop the headers and reach the original three methods, so a transport written
/// before per-call headers existed still works. A transport that can put headers on the wire
/// overrides them; the order of precedence is the transport's own headers, then the host's,
/// then this call's, so a per-call `traceparent` or tenant cannot be shadowed.
pub(open) trait Transport {
  /// Send one message and return the answer.
  async fn exchange(Self, @moonjrpc.Message) -> @moonjrpc.Message
  /// Send one message and hand every reply to `out` as it arrives, for a method whose answer is a
  /// stream.
  async fn stream(Self, @moonjrpc.Message, &ReplySink) -> Unit
  /// Read the agent's card from its well-known address.
  async fn discover(Self) -> Json
  /// Send one message with the headers of this call, and return the answer.
  async fn exchange_with(Self, @moonjrpc.Message, Headers) -> @moonjrpc.Message = _
  /// Stream one message with the headers of this call.
  async fn stream_with(Self, @moonjrpc.Message, &ReplySink, Headers) -> Unit = _
  /// Read the card with the headers of this call.
  async fn discover_with(Self, Headers) -> Json = _
}

///|
impl Transport with fn exchange_with(self, message, headers) {
  ignore(headers)
  self.exchange(message)
}

///|
impl Transport with fn stream_with(self, message, out, headers) {
  ignore(headers)
  self.stream(message, out)
}

///|
impl Transport with fn discover_with(self, headers) {
  ignore(headers)
  self.discover()
}

///|
/// A caller's handle on a remote agent. One client can be shared by several tasks, so its
/// request identifiers are handed out under a lock. Every method takes `headers?`, the
/// headers of that one call; they travel with the call through the transport.
pub struct Client {
  transport : &Transport
  mut next : Int64
  ids : @async.Mutex
}

///|
/// A client talking to the agent behind `transport`.
pub fn Client::new(transport : &Transport) -> Client {
  { transport, next: 0L, ids: @async.Mutex(), }
}

///|
/// The next request identifier. Ids only have to be unique to this client, since the transport
/// pairs each answer with the request it sent.
async fn Client::take_id(self : Client) -> @moonjrpc.Id {
  self.ids.acquire()
  self.next = self.next + 1L
  let id = @moonjrpc.Id::int(self.next)
  self.ids.release()
  id
}

///|
/// Read what an agent sent. A shape this library cannot read is the agent's fault, not the
/// caller's, so it comes back as `InvalidAgentResponse` naming the path that would not read.
fn[T : @json.FromJson] read_reply(json : Json) -> T raise {
  @json.from_json(json) catch {
    @json.JsonDecodeError((path, reason)) =>
      raise InvalidAgentResponse("\{path}: \{reason}")
  }
}

///|
/// Send `message` and return what the agent answered with: a task, or a message.
pub async fn Client::send_message(
  self : Client,
  message : Message,
  configuration? : SendMessageConfig,
  metadata? : Json,
  tenant? : String,
  headers? : Headers,
) -> StreamEvent {
  let request : SendMessageRequest = {
    message,
    configuration,
    metadata,
    tenant,
  }
  let result = self.call(Method::SendMessage, request.to_json(), headers?)
  let event : StreamEvent = read_reply(result)
  match event {
    TaskSnapshot(_) | TaskMessage(_) => event
    StatusChange(update) =>
      raise InvalidAgentResponse(
        "SendMessage answered with a \{update.status.state.wire()} event",
      )
    ArtifactChunk(update) =>
      raise InvalidAgentResponse(
        "SendMessage answered with an artifact \{update.artifact.artifact_id}",
      )
  }
}

///|
/// Send `message` and hand every event to `sink` as it arrives.
pub async fn Client::send_streaming_message(
  self : Client,
  message : Message,
  sink : &ReplySink,
  configuration? : SendMessageConfig,
  metadata? : Json,
  tenant? : String,
  headers? : Headers,
) -> Unit {
  let request : SendMessageRequest = {
    message,
    configuration,
    metadata,
    tenant,
  }
  let call = @moonjrpc.Message::Call(
    id=self.take_id(),
    name=Method::SendStreamingMessage.name(),
    params=Some(request.to_json()),
  )
  self.transport.stream_with(call, sink, headers.unwrap_or([]))
}

///|
/// Read a task as it stands.
pub async fn Client::get_task(
  self : Client,
  id : String,
  history_length? : Int32,
  headers? : Headers,
) -> Task {
  let params = object()
  params["id"] = Json::string(id)
  put_int(params, "historyLength", history_length)
  read_reply(self.call(Method::GetTask, Json::object(params), headers?))
}

///|
/// Read the tasks the caller may see.
pub async fn Client::list_tasks(
  self : Client,
  query : ListTasksQuery,
  headers? : Headers,
) -> TaskPage {
  read_reply(self.call(Method::ListTasks, query.to_json(), headers?))
}

///|
/// Ask the agent to stop a task.
pub async fn Client::cancel_task(
  self : Client,
  id : String,
  headers? : Headers,
) -> Task {
  let params = object()
  params["id"] = Json::string(id)
  read_reply(self.call(Method::CancelTask, Json::object(params), headers?))
}

///|
/// Join a task that is already running, and follow it to its end.
pub async fn Client::subscribe_to_task(
  self : Client,
  id : String,
  sink : &ReplySink,
  headers? : Headers,
) -> Unit {
  let params = object()
  params["id"] = Json::string(id)
  let call = @moonjrpc.Message::Call(
    id=self.take_id(),
    name=Method::SubscribeToTask.name(),
    params=Some(Json::object(params)),
  )
  self.transport.stream_with(call, sink, headers.unwrap_or([]))
}

///|
/// Register a webhook for a task's updates.
pub async fn Client::create_push_config(
  self : Client,
  config : TaskPushConfig,
  headers? : Headers,
) -> TaskPushConfig {
  read_reply(self.call(Method::CreatePushConfig, config.to_json(), headers?))
}

///|
/// Read one of a task's webhook registrations.
pub async fn Client::get_push_config(
  self : Client,
  task_id : String,
  id : String,
  headers? : Headers,
) -> TaskPushConfig {
  let params = object()
  params["taskId"] = Json::string(task_id)
  params["id"] = Json::string(id)
  read_reply(self.call(Method::GetPushConfig, Json::object(params), headers?))
}

///|
/// Read every webhook registration a task has.
pub async fn Client::list_push_configs(
  self : Client,
  task_id : String,
  headers? : Headers,
) -> Array[TaskPushConfig] {
  let params = object()
  params["taskId"] = Json::string(task_id)
  let page : PushConfigPage = read_reply(
    self.call(Method::ListPushConfigs, Json::object(params), headers?),
  )
  page.configs
}

///|
/// Remove a webhook registration. Removing one that is already gone is not an error.
pub async fn Client::delete_push_config(
  self : Client,
  task_id : String,
  id : String,
  headers? : Headers,
) -> Unit {
  let params = object()
  params["taskId"] = Json::string(task_id)
  params["id"] = Json::string(id)
  self.call(Method::DeletePushConfig, Json::object(params), headers?) |> ignore
}

///|
/// Read the card the agent shows only to authenticated callers.
pub async fn Client::extended_card(
  self : Client,
  headers? : Headers,
) -> AgentCard {
  read_reply(
    self.call(Method::GetExtendedCard, Json::object(Map([])), headers?),
  )
}

///|
/// Read the agent's public card.
pub async fn Client::discover(self : Client, headers? : Headers) -> AgentCard {
  read_reply(self.transport.discover_with(headers.unwrap_or([])))
}

///|
/// Make one call and return its result, turning a refusal into the error it names.
async fn Client::call(
  self : Client,
  rpc : Method,
  params : Json,
  headers? : Headers,
) -> Json {
  let call = @moonjrpc.Message::Call(
    id=self.take_id(),
    name=rpc.name(),
    params=Some(params),
  )
  let answer = self.transport.exchange_with(call, headers.unwrap_or([]))
  match answer {
    @moonjrpc.Message::Reply(result~, ..) => result
    @moonjrpc.Message::Refusal(failure~, ..) =>
      raise Refused::from_failure(failure)
    _ =>
      raise InvalidAgentResponse(
        "the transport answered a call with something that is not a reply",
      )
  }
}
