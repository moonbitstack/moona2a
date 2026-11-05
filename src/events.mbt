// The updates a task sends as it runs, and the one wrapper that carries them over the wire.

///|
/// A task changed state (A2A `TaskStatusUpdateEvent`).
#derive(Eq)
pub(all) struct TaskStatusUpdate {
  task_id : String
  context_id : String
  status : TaskStatus
  metadata : Json?
}

///|
/// An artifact was produced, or more of it arrived (A2A `TaskArtifactUpdateEvent`).
#derive(Eq)
pub(all) struct TaskArtifactUpdate {
  task_id : String
  context_id : String
  artifact : Artifact
  append : Bool
  last_chunk : Bool
  metadata : Json?
}

///|
/// One item of a streamed response (A2A `StreamResponse.payload` oneof).
#derive(Eq)
pub(all) enum StreamEvent {
  /// A task, as it stands.
  TaskSnapshot(Task)
  /// A message from the agent, outside any task.
  TaskMessage(Message)
  /// A task changed state.
  StatusChange(TaskStatusUpdate)
  /// An artifact was produced, or grew.
  ArtifactChunk(TaskArtifactUpdate)
}

///|
/// Whether the event ends the task for good.
pub fn StreamEvent::is_final(self : StreamEvent) -> Bool {
  match self {
    TaskSnapshot(task) => task.status.state.terminal()
    StatusChange(update) => update.status.state.terminal()
    TaskMessage(_) | ArtifactChunk(_) => false
  }
}

///|
/// The task this event belongs to, when it belongs to one.
pub fn StreamEvent::task_id(self : StreamEvent) -> String? {
  match self {
    TaskSnapshot(task) => Some(task.id)
    StatusChange(update) => Some(update.task_id)
    ArtifactChunk(update) => Some(update.task_id)
    TaskMessage(_) => None
  }
}

///|
/// The state this event reports, when it reports one.
pub fn StreamEvent::state(self : StreamEvent) -> TaskState? {
  match self {
    TaskSnapshot(task) => Some(task.status.state)
    StatusChange(update) => Some(update.status.state)
    TaskMessage(_) | ArtifactChunk(_) => None
  }
}

///|
/// A status update event for the task with `task_id`, moving it to `state`.
pub fn TaskStatusUpdate::of(
  task_id : String,
  context_id : String,
  state : TaskState,
) -> TaskStatusUpdate {
  { task_id, context_id, status: TaskStatus::recorded(state), metadata: None, }
}

///|
/// An artifact update event carrying `artifact` for the task with `task_id`.
pub fn TaskArtifactUpdate::of(
  task_id : String,
  context_id : String,
  artifact : Artifact,
  append? : Bool,
  last_chunk? : Bool,
) -> TaskArtifactUpdate {
  {
    task_id,
    context_id,
    artifact,
    append: append.unwrap_or(false),
    last_chunk: last_chunk.unwrap_or(true),
    metadata: None,
  }
}

///|
pub impl @json.ToJson for TaskStatusUpdate with fn to_json(self) {
  let fields = object()
  fields["taskId"] = Json::string(self.task_id)
  fields["contextId"] = Json::string(self.context_id)
  fields["status"] = self.status.to_json()
  put_json(fields, "metadata", self.metadata)
  Json::object(fields)
}

///|
pub impl @json.ToJson for TaskArtifactUpdate with fn to_json(self) {
  let fields = object()
  fields["taskId"] = Json::string(self.task_id)
  fields["contextId"] = Json::string(self.context_id)
  fields["artifact"] = self.artifact.to_json()
  if self.append {
    fields["append"] = Json::boolean(true)
  }
  if self.last_chunk {
    fields["lastChunk"] = Json::boolean(true)
  }
  put_json(fields, "metadata", self.metadata)
  Json::object(fields)
}

///|
pub impl @json.FromJson for TaskStatusUpdate with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    task_id: need_str(fields, "taskId", path),
    context_id: opt_str(fields, "contextId").unwrap_or(""),
    status: match opt_object(fields, "status") {
      Some(status) =>
        TaskStatus::from_json(Json::object(status), path.add_key("status"))
      None => raise wrong_type(path, "status", "a status object")
    },
    metadata: fields.get("metadata"),
  }
}

///|
pub impl @json.FromJson for TaskArtifactUpdate with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    task_id: need_str(fields, "taskId", path),
    context_id: opt_str(fields, "contextId").unwrap_or(""),
    artifact: match opt_object(fields, "artifact") {
      Some(artifact) =>
        Artifact::from_json(Json::object(artifact), path.add_key("artifact"))
      None => raise wrong_type(path, "artifact", "an artifact object")
    },
    append: opt_bool(fields, "append").unwrap_or(false),
    last_chunk: opt_bool(fields, "lastChunk").unwrap_or(false),
    metadata: fields.get("metadata"),
  }
}

///|
pub impl @json.ToJson for StreamEvent with fn to_json(self) {
  let fields = object()
  match self {
    TaskSnapshot(task) => fields["task"] = task.to_json()
    TaskMessage(message) => fields["message"] = message.to_json()
    StatusChange(update) => fields["statusUpdate"] = update.to_json()
    ArtifactChunk(update) => fields["artifactUpdate"] = update.to_json()
  }
  Json::object(fields)
}

///|
pub impl @json.FromJson for StreamEvent with fn from_json(json, path) {
  let fields = as_object(json, path)
  if fields.get("task") is Some(task) {
    TaskSnapshot(Task::from_json(task, path.add_key("task")))
  } else if fields.get("message") is Some(message) {
    TaskMessage(Message::from_json(message, path.add_key("message")))
  } else if fields.get("statusUpdate") is Some(update) {
    StatusChange(
      TaskStatusUpdate::from_json(update, path.add_key("statusUpdate")),
    )
  } else if fields.get("artifactUpdate") is Some(update) {
    ArtifactChunk(
      TaskArtifactUpdate::from_json(update, path.add_key("artifactUpdate")),
    )
  } else {
    raise @json.JsonDecodeError(
      (path, "want a task, a message, a statusUpdate or an artifactUpdate"),
    )
  }
}

///|
pub extend TaskStatusUpdate with @json.ToJson::{to_json}

///|
pub extend TaskArtifactUpdate with @json.ToJson::{to_json}

///|
pub extend StreamEvent with @json.ToJson::{to_json}

///|
pub extend TaskStatusUpdate with @json.FromJson::{from_json}

///|
pub extend TaskArtifactUpdate with @json.FromJson::{from_json}

///|
pub extend StreamEvent with @json.FromJson::{from_json}

///|
pub extend TaskStatusUpdate with Eq::{not_equal, equal}

///|
pub extend TaskArtifactUpdate with Eq::{not_equal, equal}

///|
pub extend StreamEvent with Eq::{not_equal, equal}
