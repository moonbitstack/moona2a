// A2A push-notification config (Koog `a2a-core` `TaskPushNotificationConfig` + the four
// `tasks/pushNotificationConfig/*` client methods): a caller registers a webhook the agent calls
// when a task changes state out of band, then reads, lists, and deletes those registrations. Model
// with its wire form, plus the client calls over the same JSON-RPC transport.

///|
/// How the agent authenticates its callback to the caller (A2A `PushNotificationAuthenticationInfo`).
pub(all) struct PushAuthInfo {
  schemes : Array[String]
  credentials : String?
} derive(Eq, Debug)

///|
/// A webhook the agent calls on task updates (A2A `PushNotificationConfig`).
pub(all) struct PushNotificationConfig {
  id : String?
  url : String
  token : String?
  authentication : PushAuthInfo?
} derive(Eq, Debug)

///|
/// A push-notification config bound to a task (A2A `TaskPushNotificationConfig`).
pub(all) struct TaskPushConfig {
  task_id : String
  config : PushNotificationConfig
} derive(Eq, Debug)

// ─── wire ────────────────────────────────────────────────────────────────────

///|
pub fn PushAuthInfo::to_json(self : PushAuthInfo) -> Json {
  let a = new_obj()
  a["schemes"] = Json::array(self.schemes.map(fn(s) { s.to_json() }))
  put_opt_str(a, "credentials", self.credentials)
  Json::object(a)
}

///|
pub fn PushAuthInfo::from_json(j : Json) -> PushAuthInfo raise {
  guard j is Object(o) else {
    raise A2AError("push auth info must be an object")
  }
  {
    schemes: req_str_array(o, "schemes"),
    credentials: opt_str(o, "credentials"),
  }
}

///|
pub fn PushNotificationConfig::to_json(self : PushNotificationConfig) -> Json {
  let c = new_obj()
  put_opt_str(c, "id", self.id)
  c["url"] = self.url.to_json()
  put_opt_str(c, "token", self.token)
  match self.authentication {
    Some(a) => c["authentication"] = a.to_json()
    None => ()
  }
  Json::object(c)
}

///|
pub fn PushNotificationConfig::from_json(
  j : Json,
) -> PushNotificationConfig raise {
  guard j is Object(o) else { raise A2AError("push config must be an object") }
  {
    id: opt_str(o, "id"),
    url: str_field(o, "url", ""),
    token: opt_str(o, "token"),
    authentication: match o.get("authentication") {
      Some(a) => Some(PushAuthInfo::from_json(a))
      None => None
    },
  }
}

///|
pub fn TaskPushConfig::to_json(self : TaskPushConfig) -> Json {
  { "taskId": self.task_id, "pushNotificationConfig": self.config.to_json() }
}

///|
pub fn TaskPushConfig::from_json(j : Json) -> TaskPushConfig raise {
  guard j is Object(o) else {
    raise A2AError("task push config must be an object")
  }
  {
    task_id: str_field(o, "taskId", ""),
    config: match o.get("pushNotificationConfig") {
      Some(c) => PushNotificationConfig::from_json(c)
      None =>
        raise A2AError("task push config is missing pushNotificationConfig")
    },
  }
}

// ─── client calls ────────────────────────────────────────────────────────────

///|
/// Register a push-notification webhook for a task (`tasks/pushNotificationConfig/set`).
pub fn A2AClient::set_push_config(
  self : A2AClient,
  config : TaskPushConfig,
) -> TaskPushConfig raise {
  TaskPushConfig::from_json(
    self.request("tasks/pushNotificationConfig/set", config.to_json()),
  )
}

///|
/// Read a task's push-notification config (`tasks/pushNotificationConfig/get`).
pub fn A2AClient::get_push_config(
  self : A2AClient,
  task_id : String,
  config_id? : String,
) -> TaskPushConfig raise {
  let p = new_obj()
  p["id"] = task_id.to_json()
  match config_id {
    Some(c) => p["pushNotificationConfigId"] = c.to_json()
    None => ()
  }
  TaskPushConfig::from_json(
    self.request("tasks/pushNotificationConfig/get", Json::object(p)),
  )
}

///|
/// List a task's push-notification configs (`tasks/pushNotificationConfig/list`).
pub fn A2AClient::list_push_configs(
  self : A2AClient,
  task_id : String,
) -> Array[TaskPushConfig] raise {
  match self.request("tasks/pushNotificationConfig/list", { "id": task_id }) {
    Array(a) => {
      let out : Array[TaskPushConfig] = []
      for x in a {
        out.push(TaskPushConfig::from_json(x))
      }
      out
    }
    _ => raise A2AError("list result must be a JSON array")
  }
}

///|
/// Delete a task's push-notification config (`tasks/pushNotificationConfig/delete`).
pub fn A2AClient::delete_push_config(
  self : A2AClient,
  task_id : String,
  config_id : String,
) -> Unit raise {
  self.request("tasks/pushNotificationConfig/delete", {
    "id": task_id,
    "pushNotificationConfigId": config_id,
  })
  |> ignore
}

///|
pub extend PushAuthInfo with Debug::{to_repr}

///|
pub extend PushAuthInfo with Eq::{not_equal, equal}

///|
pub extend PushNotificationConfig with Debug::{to_repr}

///|
pub extend PushNotificationConfig with Eq::{not_equal, equal}

///|
pub extend TaskPushConfig with Debug::{to_repr}

///|
pub extend TaskPushConfig with Eq::{not_equal, equal}
