// Push notifications: a caller leaves a URL, and the agent posts task updates there when the task
// runs on after the caller has gone. The registration and the delivered configuration are the same
// object in 1.0, flattened into one message.

///|
/// How the agent proves itself to the caller's webhook (A2A `AuthenticationInfo`).
#derive(Eq)
pub(all) struct AuthenticationInfo {
  scheme : String
  credentials : String?
}

///|
/// A bearer token the agent sends with each notification.
pub fn AuthenticationInfo::bearer(token : String) -> AuthenticationInfo {
  { scheme: "Bearer", credentials: Some(token), }
}

///|
/// Where the agent posts a task's updates, and how it authenticates there (A2A
/// `TaskPushNotificationConfig`).
#derive(Eq)
pub(all) struct TaskPushConfig {
  id : String
  task_id : String
  url : String
  token : String?
  authentication : AuthenticationInfo?
  tenant : String?
}

///|
/// A registration of `url` for `task_id`, under `id`.
pub fn TaskPushConfig::new(
  id : String,
  task_id : String,
  url : String,
) -> TaskPushConfig {
  { id, task_id, url, token: None, authentication: None, tenant: None, }
}

///|
/// The same registration, carrying the caller's own `token` in each notification's headers.
pub fn TaskPushConfig::with_token(
  self : TaskPushConfig,
  token : String,
) -> TaskPushConfig {
  { ..self, token: Some(token), }
}

///|
/// The same registration, authenticating with `authentication`.
pub fn TaskPushConfig::authenticating(
  self : TaskPushConfig,
  authentication : AuthenticationInfo,
) -> TaskPushConfig {
  { ..self, authentication: Some(authentication), }
}

///|
/// One page of a task's registrations (A2A `ListTaskPushNotificationConfigsResponse`).
#derive(Eq)
pub(all) struct PushConfigPage {
  configs : Array[TaskPushConfig]
  next_page_token : String
}

///|
pub impl @json.ToJson for AuthenticationInfo with fn to_json(self) {
  let fields = object()
  fields["scheme"] = Json::string(self.scheme)
  put_str(fields, "credentials", self.credentials)
  Json::object(fields)
}

///|
pub impl @json.FromJson for AuthenticationInfo with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    scheme: need_str(fields, "scheme", path),
    credentials: opt_str(fields, "credentials"),
  }
}

///|
pub impl @json.ToJson for TaskPushConfig with fn to_json(self) {
  let fields = object()
  fields["id"] = Json::string(self.id)
  fields["taskId"] = Json::string(self.task_id)
  fields["url"] = Json::string(self.url)
  put_str(fields, "token", self.token)
  put_str(fields, "tenant", self.tenant)
  match self.authentication {
    Some(authentication) => fields["authentication"] = authentication.to_json()
    None => ()
  }
  Json::object(fields)
}

///|
pub impl @json.FromJson for TaskPushConfig with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    id: opt_str(fields, "id").unwrap_or(""),
    task_id: pick_str(fields, "taskId", "task_id").unwrap_or(""),
    url: need_str(fields, "url", path),
    token: opt_str(fields, "token"),
    authentication: read_opt(
      fields,
      "authentication",
      path,
      AuthenticationInfo::from_json,
    ),
    tenant: opt_str(fields, "tenant"),
  }
}

///|
pub impl @json.ToJson for PushConfigPage with fn to_json(self) {
  Json::object({
    "configs": Json::array(self.configs.map(TaskPushConfig::to_json)),
    "nextPageToken": Json::string(self.next_page_token),
  })
}

///|
pub impl @json.FromJson for PushConfigPage with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    configs: read_opt_array(fields, "configs", path, TaskPushConfig::from_json).unwrap_or([],
    ),
    next_page_token: opt_str(fields, "nextPageToken").unwrap_or(""),
  }
}

///|
pub extend AuthenticationInfo with @json.ToJson::{to_json}

///|
pub extend TaskPushConfig with @json.ToJson::{to_json}

///|
pub extend PushConfigPage with @json.ToJson::{to_json}

///|
pub extend AuthenticationInfo with @json.FromJson::{from_json}

///|
pub extend TaskPushConfig with @json.FromJson::{from_json}

///|
pub extend PushConfigPage with @json.FromJson::{from_json}

///|
pub extend AuthenticationInfo with Eq::{not_equal, equal}

///|
pub extend TaskPushConfig with Eq::{not_equal, equal}

///|
pub extend PushConfigPage with Eq::{not_equal, equal}
