// The calling side: the methods a server answers, invoked over a transport that carries JSON-RPC.
// `moona2a/http` supplies one over HTTP; a test supplies one that answers from a table.

///|
/// How a client reaches an agent. A transport carries JSON-RPC messages and finds the card; it
/// knows nothing about tasks.
pub(open) trait Transport {
  /// Send one message and return the answer.
  async fn exchange(Self, @moonjrpc.Message) -> @moonjrpc.Message
  /// Send one message and hand every reply to `out` as it arrives, for a method whose answer is a
  /// stream.
  async fn stream(Self, @moonjrpc.Message, &ReplySink) -> Unit
  /// Read the agent's card from its well-known address.
  async fn discover(Self) -> Json
}

///|
/// A caller's handle on a remote agent.
pub struct Client {
  transport : &Transport
  mut next : Int64
}

///|
/// A client talking to the agent behind `transport`.
pub fn Client::new(transport : &Transport) -> Client {
  { transport, next: 0L, }
}

///|
/// The next request identifier. Ids only have to be unique to this client, since the transport
/// pairs each answer with the request it sent.
fn Client::take_id(self : Client) -> @moonjrpc.Id {
  self.next = self.next + 1L
  @moonjrpc.Id::int(self.next)
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
) -> StreamEvent {
  let request : SendMessageRequest = {
    message,
    configuration,
    metadata,
    tenant,
  }
  let result = self.call(Method::SendMessage, request.to_json())
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
  self.transport.stream(call, sink)
}

///|
/// Read a task as it stands.
pub async fn Client::get_task(
  self : Client,
  id : String,
  history_length? : Int32,
) -> Task {
  let params = object()
  params["id"] = Json::string(id)
  put_int(params, "historyLength", history_length)
  read_reply(self.call(Method::GetTask, Json::object(params)))
}

///|
/// Read the tasks the caller may see.
pub async fn Client::list_tasks(
  self : Client,
  query : ListTasksQuery,
) -> TaskPage {
  read_reply(self.call(Method::ListTasks, query.to_json()))
}

///|
/// Ask the agent to stop a task.
pub async fn Client::cancel_task(self : Client, id : String) -> Task {
  let params = object()
  params["id"] = Json::string(id)
  read_reply(self.call(Method::CancelTask, Json::object(params)))
}

///|
/// Join a task that is already running, and follow it to its end.
pub async fn Client::subscribe_to_task(
  self : Client,
  id : String,
  sink : &ReplySink,
) -> Unit {
  let params = object()
  params["id"] = Json::string(id)
  let call = @moonjrpc.Message::Call(
    id=self.take_id(),
    name=Method::SubscribeToTask.name(),
    params=Some(Json::object(params)),
  )
  self.transport.stream(call, sink)
}

///|
/// Register a webhook for a task's updates.
pub async fn Client::create_push_config(
  self : Client,
  config : TaskPushConfig,
) -> TaskPushConfig {
  read_reply(self.call(Method::CreatePushConfig, config.to_json()))
}

///|
/// Read one of a task's webhook registrations.
pub async fn Client::get_push_config(
  self : Client,
  task_id : String,
  id : String,
) -> TaskPushConfig {
  let params = object()
  params["taskId"] = Json::string(task_id)
  params["id"] = Json::string(id)
  read_reply(self.call(Method::GetPushConfig, Json::object(params)))
}

///|
/// Read every webhook registration a task has.
pub async fn Client::list_push_configs(
  self : Client,
  task_id : String,
) -> Array[TaskPushConfig] {
  let params = object()
  params["taskId"] = Json::string(task_id)
  let page : PushConfigPage = read_reply(
    self.call(Method::ListPushConfigs, Json::object(params)),
  )
  page.configs
}

///|
/// Remove a webhook registration. Removing one that is already gone is not an error.
pub async fn Client::delete_push_config(
  self : Client,
  task_id : String,
  id : String,
) -> Unit {
  let params = object()
  params["taskId"] = Json::string(task_id)
  params["id"] = Json::string(id)
  self.call(Method::DeletePushConfig, Json::object(params)) |> ignore
}

///|
/// Read the card the agent shows only to authenticated callers.
pub async fn Client::extended_card(self : Client) -> AgentCard {
  read_reply(self.call(Method::GetExtendedCard, Json::object(Map([]))))
}

///|
/// Read the agent's public card.
pub async fn Client::discover(self : Client) -> AgentCard {
  read_reply(self.transport.discover())
}

///|
/// Make one call and return its result, turning a refusal into the error it names.
async fn Client::call(self : Client, rpc : Method, params : Json) -> Json {
  let call = @moonjrpc.Message::Call(
    id=self.take_id(),
    name=rpc.name(),
    params=Some(params),
  )
  let answer = self.transport.exchange(call)
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
