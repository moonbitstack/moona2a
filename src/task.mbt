// A task: the unit of work an agent runs, its lifecycle state, and the history and artifacts it
// accumulates. The state machine lives here, so both sides of the wire agree on what may follow
// what.

///|
/// The lifecycle state of a task (A2A `TaskState`).
#derive(Eq)
pub(all) enum TaskState {
  Unspecified
  Submitted
  Working
  Completed
  Failed
  Canceled
  InputRequired
  Rejected
  AuthRequired
}

///|
/// The wire name of the state, as ProtoJSON writes an enum.
pub fn TaskState::wire(self : TaskState) -> String {
  match self {
    Unspecified => "TASK_STATE_UNSPECIFIED"
    Submitted => "TASK_STATE_SUBMITTED"
    Working => "TASK_STATE_WORKING"
    Completed => "TASK_STATE_COMPLETED"
    Failed => "TASK_STATE_FAILED"
    Canceled => "TASK_STATE_CANCELED"
    InputRequired => "TASK_STATE_INPUT_REQUIRED"
    Rejected => "TASK_STATE_REJECTED"
    AuthRequired => "TASK_STATE_AUTH_REQUIRED"
  }
}

///|
/// The state named by its wire form. The proto name, the bare word and the hyphenated draft name
/// are all read: a client written against an earlier draft sends `input-required`.
pub fn TaskState::from_wire(name : String) -> TaskState {
  match name {
    "TASK_STATE_SUBMITTED" | "submitted" => Submitted
    "TASK_STATE_WORKING" | "working" => Working
    "TASK_STATE_COMPLETED" | "completed" => Completed
    "TASK_STATE_FAILED" | "failed" => Failed
    "TASK_STATE_CANCELED" | "cancelled" | "canceled" => Canceled
    "TASK_STATE_INPUT_REQUIRED" | "input-required" | "input_required" =>
      InputRequired
    "TASK_STATE_REJECTED" | "rejected" => Rejected
    "TASK_STATE_AUTH_REQUIRED" | "auth-required" | "auth_required" =>
      AuthRequired
    _ => Unspecified
  }
}

///|
/// Whether the task has finished for good: no further message, cancel or transition can apply.
pub fn TaskState::terminal(self : TaskState) -> Bool {
  match self {
    Completed | Failed | Canceled | Rejected => true
    _ => false
  }
}

///|
/// Whether the task is waiting on the caller and processing can resume from here.
pub fn TaskState::interrupted(self : TaskState) -> Bool {
  match self {
    InputRequired | AuthRequired => true
    _ => false
  }
}

///|
pub impl @json.ToJson for TaskState with fn to_json(self) {
  Json::string(self.wire())
}

///|
pub impl @json.FromJson for TaskState with fn from_json(json, path) {
  match json {
    String(name) => TaskState::from_wire(name)
    _ => raise @json.JsonDecodeError((path, "want a task state name"))
  }
}

///|
/// The state of a task, with the message and time that go with it (A2A `TaskStatus`).
#derive(Eq)
pub(all) struct TaskStatus {
  state : TaskState
  message : Message?
  timestamp : String?
}

///|
/// A status with no message and no timestamp.
pub fn TaskStatus::of(state : TaskState) -> TaskStatus {
  { state, message: None, timestamp: None, }
}

///|
/// The status of `state`, recorded now.
pub fn TaskStatus::recorded(state : TaskState) -> TaskStatus {
  { state, message: None, timestamp: Some(timestamp_now()), }
}

///|
pub impl @json.ToJson for TaskStatus with fn to_json(self) {
  let fields = object()
  fields["state"] = self.state.to_json()
  put_json(fields, "message", self.message.map(Message::to_json))
  put_str(fields, "timestamp", self.timestamp)
  Json::object(fields)
}

///|
pub impl @json.FromJson for TaskStatus with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    state: match fields.get("state") {
      Some(String(name)) => TaskState::from_wire(name)
      _ => raise wrong_type(path, "state", "a task state name")
    },
    message: read_opt(fields, "message", path, Message::from_json),
    timestamp: opt_str(fields, "timestamp"),
  }
}

///|
/// A unit of work an agent runs on a caller's behalf (A2A `Task`).
#derive(Eq)
pub(all) struct Task {
  id : String
  context_id : String
  status : TaskStatus
  artifacts : Array[Artifact]
  history : Array[Message]
  metadata : Json?
}

///|
/// A new task in `context_id`, submitted and not yet worked on.
pub fn Task::new(id : String, context_id : String) -> Task {
  {
    id,
    context_id,
    status: TaskStatus::recorded(Submitted),
    artifacts: [],
    history: [],
    metadata: None,
  }
}

///|
/// The same task in `state`, with the clock stamped.
pub fn Task::with_state(self : Task, state : TaskState) -> Task {
  {
    ..self,
    status: { ..self.status, state, timestamp: Some(timestamp_now()), },
  }
}

///|
/// The same task with `message` appended to its history.
pub fn Task::saying(self : Task, message : Message) -> Task {
  let history = self.history.copy()
  history.push(message)
  { ..self, history, }
}

///|
/// The most recent `limit` messages of the history; all of them when `limit` is unset.
pub fn Task::recent(self : Task, limit : Int32?) -> Array[Message] {
  let total = self.history.length()
  let first = match limit {
    None => 0
    Some(n) => if n <= 0 { total } else if total <= n { 0 } else { total - n }
  }
  let out : Array[Message] = []
  for i in first..<total {
    out.push(self.history[i])
  }
  out
}

///|
/// The artifact with `artifact_id`, when the task has one.
pub fn Task::artifact(self : Task, artifact_id : String) -> Artifact? {
  for artifact in self.artifacts {
    if artifact.artifact_id == artifact_id {
      return Some(artifact)
    }
  }
  None
}

///|
/// The same task with `artifact` added, or with the parts of an existing artifact of the same id
/// replaced or appended to.
pub fn Task::taking(self : Task, artifact : Artifact, append : Bool) -> Task {
  let artifacts : Array[Artifact] = []
  let mut replaced = false
  for existing in self.artifacts {
    if existing.artifact_id == artifact.artifact_id {
      replaced = true
      if append {
        let parts = existing.parts.copy()
        for part in artifact.parts {
          parts.push(part)
        }
        artifacts.push({ ..existing, parts, })
      } else {
        artifacts.push(artifact)
      }
    } else {
      artifacts.push(existing)
    }
  }
  if !replaced {
    artifacts.push(artifact)
  }
  { ..self, artifacts, }
}

///|
/// How much of a task a reply carries: whether its artifacts travel with it, and how many of the
/// most recent messages do. `None` history means all of them.
#derive(Eq)
pub(all) struct View {
  artifacts : Bool
  history : Int32?
}

///|
/// Everything the task has.
pub fn View::full() -> View {
  { artifacts: true, history: None, }
}

///|
/// The task alone, without what it produced.
pub fn View::bare() -> View {
  { artifacts: false, history: None, }
}

///|
/// The task as the wire wants it, cut down to `view`.
pub fn Task::encode(self : Task, view? : View) -> Json {
  let view = view.unwrap_or(View::full())
  let fields = object()
  fields["id"] = Json::string(self.id)
  fields["contextId"] = Json::string(self.context_id)
  fields["status"] = self.status.to_json()
  if view.artifacts && self.artifacts.length() > 0 {
    fields["artifacts"] = Json::array(self.artifacts.map(Artifact::to_json))
  }
  let messages = self.recent(view.history)
  if messages.length() > 0 {
    fields["history"] = Json::array(messages.map(Message::to_json))
  }
  put_json(fields, "metadata", self.metadata)
  Json::object(fields)
}

///|
pub impl @json.ToJson for Task with fn to_json(self) {
  self.encode()
}

///|
pub impl @json.FromJson for Task with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    id: need_str(fields, "id", path),
    context_id: opt_str(fields, "contextId").unwrap_or(""),
    status: match opt_object(fields, "status") {
      Some(status) =>
        TaskStatus::from_json(Json::object(status), path.add_key("status"))
      None => raise wrong_type(path, "status", "a status object")
    },
    artifacts: read_opt_array(fields, "artifacts", path, Artifact::from_json).unwrap_or([],
    ),
    history: read_opt_array(fields, "history", path, Message::from_json).unwrap_or([],
    ),
    metadata: fields.get("metadata"),
  }
}

///|
pub extend TaskState with @json.ToJson::{to_json}

///|
pub extend TaskStatus with @json.ToJson::{to_json}

///|
pub extend Task with @json.ToJson::{to_json}

///|
pub extend TaskState with @json.FromJson::{from_json}

///|
pub extend TaskStatus with @json.FromJson::{from_json}

///|
pub extend Task with @json.FromJson::{from_json}

///|
pub extend TaskState with Eq::{not_equal, equal}

///|
pub extend TaskStatus with Eq::{not_equal, equal}

///|
pub extend Task with Eq::{not_equal, equal}

///|
pub extend View with Eq::{not_equal, equal}
