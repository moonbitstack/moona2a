// The three transports the specification defines (section 5) and what each one needs about a
// method beyond its name: the HTTP verb and path, the gRPC path, and how a refusal reads.

///|
/// A transport the specification defines, as a card names it in `protocolBinding`.
#derive(Eq, Debug)
pub(all) enum Binding {
  JsonRpc
  Grpc
  HttpJson
}

///|
/// The name the card writes for this binding.
pub fn Binding::code(self : Binding) -> String {
  match self {
    JsonRpc => "JSONRPC"
    Grpc => "GRPC"
    HttpJson => "HTTP+JSON"
  }
}

///|
/// The binding a card names, when it is one of the specification's.
pub fn Binding::of(code : StringView) -> Binding? {
  match code {
    "JSONRPC" => Some(JsonRpc)
    "GRPC" => Some(Grpc)
    "HTTP+JSON" => Some(HttpJson)
    _ => None
  }
}

///|
/// The service every gRPC method belongs to, as `a2a.proto` declares it.
pub let grpc_service : String = "lf.a2a.v1.A2AService"

///|
/// The path a gRPC call of this method goes to.
pub fn Method::grpc_path(self : Method) -> String {
  "/\{grpc_service}/\{self.name()}"
}

///|
/// Where this method lives on the HTTP+JSON binding (section 11.3): the verb, and the path with
/// `{id}` for the task and `{configId}` for a push configuration. `SubscribeToTask` also answers
/// a `GET`, which is what `a2a.proto` annotates; the specification's table writes `POST`.
pub fn Method::rest(self : Method) -> (String, String) {
  match self {
    SendMessage => ("POST", "/message:send")
    SendStreamingMessage => ("POST", "/message:stream")
    GetTask => ("GET", "/tasks/{id}")
    ListTasks => ("GET", "/tasks")
    CancelTask => ("POST", "/tasks/{id}:cancel")
    SubscribeToTask => ("POST", "/tasks/{id}:subscribe")
    CreatePushConfig => ("POST", "/tasks/{id}/pushNotificationConfigs")
    GetPushConfig => ("GET", "/tasks/{id}/pushNotificationConfigs/{configId}")
    ListPushConfigs => ("GET", "/tasks/{id}/pushNotificationConfigs")
    DeletePushConfig =>
      ("DELETE", "/tasks/{id}/pushNotificationConfigs/{configId}")
    GetExtendedCard => ("GET", "/extendedAgentCard")
  }
}

///|
/// An interface speaking gRPC at `url`, written `host:port`.
pub fn AgentInterface::grpc(
  url : String,
  protocol_version~ : String,
) -> AgentInterface {
  { url, protocol_binding: "GRPC", protocol_version, tenant: None, }
}

///|
/// An interface speaking HTTP+JSON under `url`.
pub fn AgentInterface::http_json(
  url : String,
  protocol_version~ : String,
) -> AgentInterface {
  { url, protocol_binding: "HTTP+JSON", protocol_version, tenant: None, }
}

///|
/// The interface a client speaking `bindings` should use: the first the card lists among those it
/// can speak, since the card lists them in the agent's order of preference.
pub fn AgentCard::choose(
  self : AgentCard,
  bindings : Array[Binding],
) -> AgentInterface? {
  for interface in self.supported_interfaces {
    if Binding::of(interface.protocol_binding) is Some(binding) &&
      bindings.contains(binding) {
      return Some(interface)
    }
  }
  None
}

///|
/// How a failure reads on gRPC and on HTTP+JSON (section 5.4).
#derive(Eq, Debug)
pub(all) struct Status {
  /// The gRPC status code.
  grpc : Int32
  /// The code's canonical name, which the HTTP+JSON error body carries as `status`.
  name : String
  /// The HTTP status.
  http : Int32
}

///|
/// The status a failure with JSON-RPC code `code` maps to. A method nobody serves is a not found,
/// as the Python SDK answers it; a code the specification does not name is an internal error.
pub fn Status::of(code : Int32) -> Status {
  match code {
    -32001 | -32601 => { grpc: 5, name: "NOT_FOUND", http: 404, }
    -32002 | -32003 | -32004 | -32007 | -32008 | -32009 =>
      { grpc: 9, name: "FAILED_PRECONDITION", http: 400, }
    -32005 | -32600 | -32602 | -32700 =>
      { grpc: 3, name: "INVALID_ARGUMENT", http: 400, }
    _ => { grpc: 13, name: "INTERNAL", http: 500, }
  }
}

///|
/// The failure a gRPC or HTTP+JSON refusal stands for. The A2A error its `ErrorInfo` names wins;
/// without one, the gRPC code picks the nearest JSON-RPC code. `details` stay as the server sent
/// them, as the failure's data.
pub fn failure_of_status(
  grpc : Int32,
  message : String,
  details : Array[Json],
) -> @moonjrpc.Failure {
  let named = details
    .iter()
    .filter_map(detail => {
      guard detail is Object(fields) &&
        fields.get("domain") is Some(String("a2a-protocol.org")) &&
        fields.get("reason") is Some(String(reason)) else {
        return None
      }
      Refused::of(reason)
    })
    .head()
  let code = match named {
    Some(refused) => refused.code()
    None =>
      match grpc {
        3 => @moonjrpc.invalid_params
        5 | 12 => @moonjrpc.method_not_found
        _ => @moonjrpc.internal_error
      }
  }
  {
    code,
    message,
    data: if details.is_empty() {
      None
    } else {
      Some(Json::array(details))
    },
  }
}

///|
pub extend Binding with Eq::{equal, not_equal}

///|
pub extend Binding with Debug::{to_repr}

///|
pub extend Status with Eq::{equal, not_equal}

///|
pub extend Status with Debug::{to_repr}
