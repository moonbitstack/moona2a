// The A2A server (Koog `a2a-server` `A2AServer` + `AgentExecutor`): the request-handling side of the
// protocol. `AgentExecutor` holds the agent's logic — run a task for an incoming message, or cancel
// one — and `A2AServer.handle` is the JSON-RPC dispatcher a transport delivers requests to,
// persisting tasks in a `TaskStore`. Koog streams execution through a `SessionEventProcessor`;
// moonkoog's synchronous core collapses that to the executor returning the finished result.

///|
/// The context an executor runs a request in (Koog `RequestContext`): the incoming message, the
/// task and context ids it belongs to, and the existing task when the message continues one.
pub(all) struct RequestContext {
  message : Message
  task_id : String
  context_id : String
  task : Task?
}

///|
/// The agent's logic behind a server (Koog `AgentExecutor`): run a request to a result, or cancel a
/// task.
pub(open) trait AgentExecutor {
  fn execute(Self, context : RequestContext) -> SendResult raise
  fn cancel(Self, task_id : String) -> Task raise
}

///|
/// Where a server keeps tasks between requests (Koog task storage).
pub(open) trait TaskStore {
  fn get(Self, task_id : String) -> Task?
  fn save(Self, task : Task) -> Unit
}

///|
/// An in-memory task store (Koog `InMemoryMessageStorage`).
pub struct InMemoryTaskStore {
  tasks : Map[String, Task]
}

///|
/// A fresh in-memory store.
pub fn InMemoryTaskStore::new() -> InMemoryTaskStore {
  { tasks: Map([]), }
}

///|
pub impl TaskStore for InMemoryTaskStore with fn get(self, task_id) {
  self.tasks.get(task_id)
}

///|
pub impl TaskStore for InMemoryTaskStore with fn save(self, task) {
  self.tasks[task.id] = task
}

///|
/// An A2A server dispatching JSON-RPC requests to `executor`, persisting tasks in `store` and
/// push-notification configs per task.
pub struct A2AServer {
  executor : &AgentExecutor
  store : &TaskStore
  push : Map[String, Array[TaskPushConfig]]
}

///|
/// A server backed by `executor` and `store`.
pub fn A2AServer::new(
  executor : &AgentExecutor,
  store : &TaskStore,
) -> A2AServer {
  { executor, store, push: Map([]), }
}

///|
/// Handle one JSON-RPC request, returning the JSON-RPC response — a `result` on success, or an
/// `error` object when the method fails (a server answers, it does not throw at the transport).
pub fn A2AServer::handle(self : A2AServer, request : Json) -> Json {
  let (id, rpc_method, params) = match request {
    Object(o) =>
      (
        match o.get("id") {
          Some(x) => x
          None => Json::null()
        },
        str_field(o, "method", ""),
        match o.get("params") {
          Some(p) => p
          None => Json::object({})
        },
      )
    _ => (Json::null(), "", Json::object({}))
  }
  try {
    let result = self.dispatch(rpc_method, params)
    { "jsonrpc": "2.0", "id": id, "result": result }
  } catch {
    A2AError(msg) => error_response(id, msg)
    _ => error_response(id, "internal error")
  }
}

///|
/// Route one method to the executor / store.
fn A2AServer::dispatch(
  self : A2AServer,
  rpc_method : String,
  params : Json,
) -> Json raise {
  guard params is Object(p) else {
    raise A2AError("params must be a JSON object")
  }
  match rpc_method {
    "message/send" => {
      let message = match p.get("message") {
        Some(m) => Message::from_json(m)
        None => raise A2AError("message/send needs a message")
      }
      let task_id = match message.task_id {
        Some(t) => t
        None => message.message_id
      }
      let context_id = match message.context_id {
        Some(c) => c
        None => message.message_id
      }
      let existing = match message.task_id {
        Some(tid) => self.store.get(tid)
        None => None
      }
      match
        self.executor.execute({ message, task_id, context_id, task: existing, }) {
        ResultTask(task) => {
          self.store.save(task)
          task.to_json()
        }
        ResultMessage(msg) => msg.to_json()
      }
    }
    "tasks/get" =>
      match self.store.get(str_field(p, "id", "")) {
        Some(task) => task.to_json()
        None => raise A2AError("task not found: " + str_field(p, "id", ""))
      }
    "tasks/cancel" => {
      let task = self.executor.cancel(str_field(p, "id", ""))
      self.store.save(task)
      task.to_json()
    }
    "tasks/pushNotificationConfig/set" => {
      let cfg = TaskPushConfig::from_json(Json::object(p))
      let kept : Array[TaskPushConfig] = []
      for c in self.push_for(cfg.task_id) {
        if c.config.id != cfg.config.id {
          kept.push(c)
        }
      }
      kept.push(cfg)
      self.push[cfg.task_id] = kept
      cfg.to_json()
    }
    "tasks/pushNotificationConfig/get" => {
      let configs = self.push_for(str_field(p, "id", ""))
      let found = match opt_str(p, "pushNotificationConfigId") {
        Some(cid) => {
          let mut r : TaskPushConfig? = None
          for c in configs {
            if c.config.id == Some(cid) {
              r = Some(c)
            }
          }
          r
        }
        None => if configs.length() > 0 { Some(configs[0]) } else { None }
      }
      match found {
        Some(c) => c.to_json()
        None => raise A2AError("push config not found")
      }
    }
    "tasks/pushNotificationConfig/list" =>
      Json::array(
        self.push_for(str_field(p, "id", "")).map(TaskPushConfig::to_json),
      )
    "tasks/pushNotificationConfig/delete" => {
      let cid = str_field(p, "pushNotificationConfigId", "")
      let kept : Array[TaskPushConfig] = []
      for c in self.push_for(str_field(p, "id", "")) {
        if c.config.id != Some(cid) {
          kept.push(c)
        }
      }
      self.push[str_field(p, "id", "")] = kept
      Json::null()
    }
    other => raise A2AError("unknown method: " + other)
  }
}

///|
/// The push-notification configs registered for `task_id` (empty when none).
fn A2AServer::push_for(
  self : A2AServer,
  task_id : String,
) -> Array[TaskPushConfig] {
  match self.push.get(task_id) {
    Some(configs) => configs
    None => []
  }
}

///|
/// A JSON-RPC error response.
fn error_response(id : Json, message : String) -> Json {
  {
    "jsonrpc": "2.0",
    "id": id,
    "error": { "code": Json::number(-32000), "message": message },
  }
}

///|
pub extend InMemoryTaskStore with TaskStore::{save, get}
