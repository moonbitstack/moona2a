// The methods an A2A endpoint answers, and the request and reply objects that travel with them.

///|
/// Every method of the JSON-RPC binding.
#derive(Eq)
pub(all) enum Method {
  SendMessage
  SendStreamingMessage
  GetTask
  ListTasks
  CancelTask
  SubscribeToTask
  CreatePushConfig
  GetPushConfig
  ListPushConfigs
  DeletePushConfig
  GetExtendedCard
}

///|
/// The name the method goes by on the wire: PascalCase, as section 9.1 requires.
pub fn Method::name(self : Method) -> String {
  match self {
    SendMessage => "SendMessage"
    SendStreamingMessage => "SendStreamingMessage"
    GetTask => "GetTask"
    ListTasks => "ListTasks"
    CancelTask => "CancelTask"
    SubscribeToTask => "SubscribeToTask"
    CreatePushConfig => "CreateTaskPushNotificationConfig"
    GetPushConfig => "GetTaskPushNotificationConfig"
    ListPushConfigs => "ListTaskPushNotificationConfigs"
    DeletePushConfig => "DeleteTaskPushNotificationConfig"
    GetExtendedCard => "GetExtendedAgentCard"
  }
}

///|
/// The method that goes by `name`, when it is one of the protocol's.
pub fn Method::from_name(name : String) -> Method? {
  for
    candidate in [
      SendMessage,
      SendStreamingMessage,
      GetTask,
      ListTasks,
      CancelTask,
      SubscribeToTask,
      CreatePushConfig,
      GetPushConfig,
      ListPushConfigs,
      DeletePushConfig,
      GetExtendedCard,
    ] {
    if candidate.name() == name {
      return Some(candidate)
    }
  }
  None
}

///|
/// Whether the answer to this method is a stream of events rather than a single body.
pub fn Method::streams(self : Method) -> Bool {
  match self {
    SendStreamingMessage | SubscribeToTask => true
    _ => false
  }
}

///|
/// Whether `name` is one of the methods whose answer is a stream, for a transport that has to
/// decide before reading the whole request.
pub fn is_streaming_method(name : String) -> Bool {
  match Method::from_name(name) {
    Some(candidate) => candidate.streams()
    None => false
  }
}

///|
/// The parameters of a call as an object. A call with no parameters reads as an empty one, so a
/// method that needs nothing can still be called.
fn params_object(params : Json?) -> Map[String, Json] raise @moonjrpc.Failed {
  match params {
    Some(Object(fields)) => fields
    None => Map([])
    _ => raise InvalidParams("params must be an object").as_failed()
  }
}

///|
/// Read a request object out of a call's parameters. Parameters that do not decode are the
/// caller's mistake, so they come back as `InvalidParams` naming the path that would not read.
fn[A : @json.FromJson] decode(params : Json?) -> A raise @moonjrpc.Failed {
  let json = params.unwrap_or(Json::null())
  @json.from_json(json) catch {
    @json.JsonDecodeError((path, reason)) =>
      raise InvalidParams("\{path}: \{reason}").as_failed()
  }
}

///|
/// How a send request should be handled: whether to wait, how much history to bring back, and what
/// the caller is willing to receive.
#derive(Eq)
pub(all) struct SendMessageConfig {
  return_immediately : Bool
  history_length : Int32?
  accepted_output_modes : Array[String]
  push : TaskPushConfig?
}

///|
/// Wait for the task to finish, and bring back its whole history.
pub fn SendMessageConfig::waiting() -> SendMessageConfig {
  {
    return_immediately: false,
    history_length: None,
    accepted_output_modes: [],
    push: None,
  }
}

///|
/// The same configuration, returning before the task finishes.
pub fn SendMessageConfig::immediately(
  self : SendMessageConfig,
) -> SendMessageConfig {
  { ..self, return_immediately: true, }
}

///|
/// The same configuration, bringing back at most `history_length` messages.
pub fn SendMessageConfig::at_most(
  self : SendMessageConfig,
  history_length : Int32,
) -> SendMessageConfig {
  { ..self, history_length: Some(history_length), }
}

///|
/// The same configuration, registering `push` for the task it creates.
pub fn SendMessageConfig::pushing(
  self : SendMessageConfig,
  push : TaskPushConfig,
) -> SendMessageConfig {
  { ..self, push: Some(push), }
}

///|
/// Everything a send request carries (A2A `SendMessageRequest`).
#derive(Eq)
pub(all) struct SendMessageRequest {
  message : Message
  configuration : SendMessageConfig?
  metadata : Json?
  tenant : String?
}

///|
/// A request to send `message` with nothing else set.
pub fn SendMessageRequest::new(message : Message) -> SendMessageRequest {
  { message, configuration: None, metadata: None, tenant: None, }
}

///|
pub impl @json.ToJson for SendMessageConfig with fn to_json(self) {
  let fields = object()
  if self.return_immediately {
    fields["returnImmediately"] = Json::boolean(true)
  }
  put_int(fields, "historyLength", self.history_length)
  if self.accepted_output_modes.length() > 0 {
    fields["acceptedOutputModes"] = strings(self.accepted_output_modes)
  }
  match self.push {
    Some(push) => fields["taskPushNotificationConfig"] = push.to_json()
    None => ()
  }
  Json::object(fields)
}

///|
pub impl @json.FromJson for SendMessageConfig with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    return_immediately: pick_bool(
      fields, "returnImmediately", "return_immediately",
    ).unwrap_or(false),
    history_length: pick_int(fields, "historyLength", "history_length"),
    accepted_output_modes: match
      pick(fields, "acceptedOutputModes", "accepted_output_modes") {
      Some(Array(items)) => {
        let modes : Array[String] = []
        for item in items {
          if item is String(mode) {
            modes.push(mode)
          }
        }
        modes
      }
      _ => {
        let none : Array[String] = []
        none
      }
    },
    push: match
      pick_object(
        fields, "taskPushNotificationConfig", "task_push_notification_config",
      ) {
      Some(config) =>
        Some(
          TaskPushConfig::from_json(
            Json::object(config),
            path.add_key("taskPushNotificationConfig"),
          ),
        )
      None => None
    },
  }
}

///|
pub impl @json.ToJson for SendMessageRequest with fn to_json(self) {
  let fields = object()
  fields["message"] = self.message.to_json()
  match self.configuration {
    Some(configuration) => fields["configuration"] = configuration.to_json()
    None => ()
  }
  put_json(fields, "metadata", self.metadata)
  put_str(fields, "tenant", self.tenant)
  Json::object(fields)
}

///|
pub impl @json.FromJson for SendMessageRequest with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    message: match fields.get("message") {
      Some(message) => Message::from_json(message, path.add_key("message"))
      None => raise wrong_type(path, "message", "a message object")
    },
    configuration: read_opt(
      fields,
      "configuration",
      path,
      SendMessageConfig::from_json,
    ),
    metadata: fields.get("metadata"),
    tenant: opt_str(fields, "tenant"),
  }
}

///|
/// The filters a list request carries (A2A `ListTasksRequest`).
#derive(Eq)
pub(all) struct ListTasksQuery {
  context_id : String?
  state : TaskState?
  page_size : Int32?
  page_token : String?
  history_length : Int32?
  status_timestamp_after : String?
  include_artifacts : Bool
  tenant : String?
}

///|
/// No filter at all: every task the caller may see.
pub fn ListTasksQuery::all() -> ListTasksQuery {
  {
    context_id: None,
    state: None,
    page_size: None,
    page_token: None,
    history_length: None,
    status_timestamp_after: None,
    include_artifacts: false,
    tenant: None,
  }
}

///|
/// The same query, limited to one conversation.
pub fn ListTasksQuery::in_context(
  self : ListTasksQuery,
  context_id : String,
) -> ListTasksQuery {
  { ..self, context_id: Some(context_id), }
}

///|
/// One page of tasks (A2A `ListTasksResponse`).
#derive(Eq)
pub(all) struct TaskPage {
  tasks : Array[Task]
  next_page_token : String
  page_size : Int32
  total_size : Int32
}

///|
pub impl @json.ToJson for ListTasksQuery with fn to_json(self) {
  let fields = object()
  put_str(fields, "contextId", self.context_id)
  match self.state {
    Some(state) => fields["status"] = state.to_json()
    None => ()
  }
  put_int(fields, "pageSize", self.page_size)
  put_str(fields, "pageToken", self.page_token)
  put_int(fields, "historyLength", self.history_length)
  put_str(fields, "statusTimestampAfter", self.status_timestamp_after)
  if self.include_artifacts {
    fields["includeArtifacts"] = Json::boolean(true)
  }
  put_str(fields, "tenant", self.tenant)
  Json::object(fields)
}

///|
pub impl @json.FromJson for ListTasksQuery with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    context_id: pick_str(fields, "contextId", "context_id"),
    state: match pick_str(fields, "status", "status") {
      Some(name) => Some(TaskState::from_wire(name))
      None => None
    },
    page_size: pick_int(fields, "pageSize", "page_size"),
    page_token: pick_str(fields, "pageToken", "page_token"),
    history_length: pick_int(fields, "historyLength", "history_length"),
    status_timestamp_after: pick_str(
      fields, "statusTimestampAfter", "status_timestamp_after",
    ),
    include_artifacts: pick_bool(
      fields, "includeArtifacts", "include_artifacts",
    ).unwrap_or(false),
    tenant: opt_str(fields, "tenant"),
  }
}

///|
pub impl @json.ToJson for TaskPage with fn to_json(self) {
  Json::object({
    "tasks": Json::array(self.tasks.map(Task::to_json)),
    "nextPageToken": Json::string(self.next_page_token),
    "pageSize": Json::number(
      self.page_size.to_double(),
      repr=self.page_size.to_string(),
    ),
    "totalSize": Json::number(
      self.total_size.to_double(),
      repr=self.total_size.to_string(),
    ),
  })
}

///|
pub impl @json.FromJson for TaskPage with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    tasks: read_array(fields, "tasks", path, Task::from_json),
    next_page_token: opt_str(fields, "nextPageToken").unwrap_or(""),
    page_size: opt_int(fields, "pageSize").unwrap_or(0),
    total_size: opt_int(fields, "totalSize").unwrap_or(0),
  }
}

///|
pub extend SendMessageConfig with @json.ToJson::{to_json}

///|
pub extend SendMessageRequest with @json.ToJson::{to_json}

///|
pub extend ListTasksQuery with @json.ToJson::{to_json}

///|
pub extend TaskPage with @json.ToJson::{to_json}

///|
pub extend SendMessageConfig with @json.FromJson::{from_json}

///|
pub extend SendMessageRequest with @json.FromJson::{from_json}

///|
pub extend ListTasksQuery with @json.FromJson::{from_json}

///|
pub extend TaskPage with @json.FromJson::{from_json}

///|
pub extend Method with Eq::{not_equal, equal}

///|
pub extend SendMessageConfig with Eq::{not_equal, equal}

///|
pub extend SendMessageRequest with Eq::{not_equal, equal}

///|
pub extend ListTasksQuery with Eq::{not_equal, equal}

///|
pub extend TaskPage with Eq::{not_equal, equal}
