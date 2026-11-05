// What a server refuses, in the protocol's own vocabulary: every case is one of the errors the
// specification names, so a client sees the same numeric code whichever binding answered.

///|
/// A refused operation, named as the specification names it. The string is the server's own note
/// on what the caller did, empty when the name says everything.
pub(all) suberror Refused {
  TaskNotFound(String)
  TaskNotCancelable(String)
  PushNotificationNotSupported(String)
  UnsupportedOperation(String)
  ContentTypeNotSupported(String)
  InvalidAgentResponse(String)
  ExtendedAgentCardNotConfigured(String)
  ExtensionSupportRequired(String)
  VersionNotSupported(String)
  InvalidRequest(String)
  InvalidParams(String)
}

///|
/// The JSON-RPC error code of the refusal, as section 5.4 of the specification maps it.
pub fn Refused::code(self : Refused) -> Int32 {
  match self {
    TaskNotFound(_) => -32001
    TaskNotCancelable(_) => -32002
    PushNotificationNotSupported(_) => -32003
    UnsupportedOperation(_) => -32004
    ContentTypeNotSupported(_) => -32005
    InvalidAgentResponse(_) => -32006
    ExtendedAgentCardNotConfigured(_) => -32007
    ExtensionSupportRequired(_) => -32008
    VersionNotSupported(_) => -32009
    InvalidRequest(_) => @moonjrpc.invalid_request
    InvalidParams(_) => @moonjrpc.invalid_params
  }
}

///|
/// The machine-readable reason, which goes into the error details.
pub fn Refused::reason(self : Refused) -> String {
  match self {
    TaskNotFound(_) => "TASK_NOT_FOUND"
    TaskNotCancelable(_) => "TASK_NOT_CANCELABLE"
    PushNotificationNotSupported(_) => "PUSH_NOTIFICATION_NOT_SUPPORTED"
    UnsupportedOperation(_) => "UNSUPPORTED_OPERATION"
    ContentTypeNotSupported(_) => "CONTENT_TYPE_NOT_SUPPORTED"
    InvalidAgentResponse(_) => "INVALID_AGENT_RESPONSE"
    ExtendedAgentCardNotConfigured(_) => "EXTENDED_AGENT_CARD_NOT_CONFIGURED"
    ExtensionSupportRequired(_) => "EXTENSION_SUPPORT_REQUIRED"
    VersionNotSupported(_) => "VERSION_NOT_SUPPORTED"
    InvalidRequest(_) => "INVALID_REQUEST"
    InvalidParams(_) => "INVALID_PARAMS"
  }
}

///|
/// The one-line message a client shows a human, worded as the specification's error table words it.
pub fn Refused::mention(self : Refused) -> String {
  match self {
    TaskNotFound(_) => "Task not found"
    TaskNotCancelable(_) => "Task cannot be canceled"
    PushNotificationNotSupported(_) => "Push notifications are not supported"
    UnsupportedOperation(_) => "This operation is not supported"
    ContentTypeNotSupported(_) => "Content type is not supported"
    InvalidAgentResponse(_) => "The agent response is invalid"
    ExtendedAgentCardNotConfigured(_) => "No extended agent card is configured"
    ExtensionSupportRequired(_) => "A required extension was not declared"
    VersionNotSupported(_) => "This protocol version is not supported"
    InvalidRequest(_) => "Invalid request"
    InvalidParams(_) => "Invalid parameters"
  }
}

///|
/// What the caller did that the server is complaining about, when the refusal says.
pub fn Refused::detail(self : Refused) -> String? {
  let detail = match self {
    TaskNotFound(detail)
    | TaskNotCancelable(detail)
    | PushNotificationNotSupported(detail)
    | UnsupportedOperation(detail)
    | ContentTypeNotSupported(detail)
    | InvalidAgentResponse(detail)
    | ExtendedAgentCardNotConfigured(detail)
    | ExtensionSupportRequired(detail)
    | VersionNotSupported(detail)
    | InvalidRequest(detail)
    | InvalidParams(detail) => detail
  }
  if detail == "" {
    None
  } else {
    Some(detail)
  }
}

///|
/// The `google.rpc.ErrorInfo` object that travels in the error's `data`, as section 9.5 asks.
fn error_info(reason : String, detail : String?) -> Json {
  let metadata = object()
  match detail {
    Some(text) => metadata["detail"] = Json::string(text)
    None => ()
  }
  Json::object({
    "@type": Json::string("type.googleapis.com/google.rpc.ErrorInfo"),
    "reason": Json::string(reason),
    "domain": Json::string("a2a-protocol.org"),
    "metadata": Json::object(metadata),
  })
}

///|
/// The JSON-RPC failure that carries this refusal to the caller.
pub fn Refused::failure(self : Refused) -> @moonjrpc.Failure {
  {
    code: self.code(),
    message: self.mention(),
    data: Some(Json::array([error_info(self.reason(), self.detail())])),
  }
}

///|
/// The refusal as the error a JSON-RPC handler raises, so its code and details reach the caller.
pub fn Refused::as_failed(self : Refused) -> @moonjrpc.Failed {
  @moonjrpc.Failed(self.failure())
}

///|
/// Read a refusal off the wire, by the code the server gave it. A code this library does not know
/// becomes `InvalidAgentResponse`: the caller cannot recover from it either way, and naming it
/// after what it is beats inventing a case for it.
pub fn Refused::from_failure(failure : @moonjrpc.Failure) -> Refused {
  match failure.code {
    -32001 => TaskNotFound("")
    -32002 => TaskNotCancelable("")
    -32003 => PushNotificationNotSupported("")
    -32004 => UnsupportedOperation("")
    -32005 => ContentTypeNotSupported("")
    -32006 => InvalidAgentResponse("")
    -32007 => ExtendedAgentCardNotConfigured("")
    -32008 => ExtensionSupportRequired("")
    -32009 => VersionNotSupported("")
    -32600 => InvalidRequest("")
    -32602 => InvalidParams("")
    _ => InvalidAgentResponse(failure.message)
  }
}
