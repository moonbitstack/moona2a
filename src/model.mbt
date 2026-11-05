// The A2A (Agent-to-Agent) protocol data model — Koog `a2a-core` `model`. The message/task
// exchange types and their JSON wire form: a `Message` carries typed `Part`s (text / file / data);
// a `Task` carries a `TaskStatus` whose `TaskState` marks terminal outcomes, plus history and
// artifacts. `to_json` / `from_json` are the on-the-wire encoding the A2A JSON-RPC methods exchange.

///|
/// Raised on a malformed A2A payload.
pub suberror A2AError {
  A2AError(String)
}

///|
/// Who authored a message (A2A `Role`).
pub(all) enum Role {
  User
  Agent
} derive(Eq, Debug)

///|
/// A file attachment, carried either inline as base64 bytes or by URI (A2A `FileWithBytes` /
/// `FileWithUri`).
pub(all) enum FileContent {
  FileBytes(bytes~ : String, name~ : String?, mime_type~ : String?)
  FileUri(uri~ : String, name~ : String?, mime_type~ : String?)
} derive(Eq, Debug)

///|
/// One piece of a message: plain text, a file, or a structured data object (A2A `Part`).
pub(all) enum Part {
  TextPart(String)
  FilePart(FileContent)
  DataPart(Json)
} derive(Eq, Debug)

///|
/// A message exchanged with an agent (A2A `Message`).
pub(all) struct Message {
  message_id : String
  role : Role
  parts : Array[Part]
  extensions : Array[String]?
  task_id : String?
  reference_task_ids : Array[String]?
  context_id : String?
  metadata : Json?
} derive(Eq, Debug)

///|
/// A user message with a single text part (the common case).
pub fn Message::user_text(message_id : String, text : String) -> Message {
  {
    message_id,
    role: User,
    parts: [TextPart(text)],
    extensions: None,
    task_id: None,
    reference_task_ids: None,
    context_id: None,
    metadata: None,
  }
}

///|
/// A file/data artifact an agent produced while working a task (A2A `Artifact`).
pub(all) struct Artifact {
  artifact_id : String
  name : String?
  description : String?
  parts : Array[Part]
  extensions : Array[String]?
  metadata : Json?
} derive(Eq, Debug)

///|
/// The lifecycle state of a task (A2A `TaskState`); `terminal` states admit no further transitions.
pub(all) enum TaskState {
  Submitted
  Working
  InputRequired
  Completed
  Canceled
  Failed
  Rejected
  AuthRequired
  Unknown
} derive(Eq, Debug)

///|
/// Whether the state is terminal (Koog `TaskState.terminal`): completed, canceled, failed, rejected.
pub fn TaskState::terminal(self : TaskState) -> Bool {
  match self {
    Completed | Canceled | Failed | Rejected => true
    _ => false
  }
}

///|
/// The wire (kebab-case `@SerialName`) form of the state.
pub fn TaskState::wire(self : TaskState) -> String {
  match self {
    Submitted => "submitted"
    Working => "working"
    InputRequired => "input-required"
    Completed => "completed"
    Canceled => "canceled"
    Failed => "failed"
    Rejected => "rejected"
    AuthRequired => "auth-required"
    Unknown => "unknown"
  }
}

///|
/// The state named by its wire form (unrecognised names map to `Unknown`).
pub fn TaskState::from_wire(s : String) -> TaskState {
  match s {
    "submitted" => Submitted
    "working" => Working
    "input-required" => InputRequired
    "completed" => Completed
    "canceled" => Canceled
    "failed" => Failed
    "rejected" => Rejected
    "auth-required" => AuthRequired
    _ => Unknown
  }
}

///|
/// The status of a task: its state, an optional status message, and a timestamp (A2A `TaskStatus`).
pub(all) struct TaskStatus {
  state : TaskState
  message : Message?
  timestamp : String?
} derive(Eq, Debug)

///|
/// A unit of work an agent runs on a caller's behalf (A2A `Task`).
pub(all) struct Task {
  id : String
  context_id : String
  status : TaskStatus
  history : Array[Message]?
  artifacts : Array[Artifact]?
  metadata : Json?
} derive(Eq, Debug)

// ─── wire encoding ───────────────────────────────────────────────────────────

///|
pub fn Part::to_json(self : Part) -> Json {
  match self {
    TextPart(text) => { "kind": "text", "text": text }
    FilePart(f) => {
      let file = new_obj()
      match f {
        FileBytes(bytes~, name~, mime_type~) => {
          file["bytes"] = bytes.to_json()
          put_opt_str(file, "name", name)
          put_opt_str(file, "mimeType", mime_type)
        }
        FileUri(uri~, name~, mime_type~) => {
          file["uri"] = uri.to_json()
          put_opt_str(file, "name", name)
          put_opt_str(file, "mimeType", mime_type)
        }
      }
      { "kind": "file", "file": Json::object(file) }
    }
    DataPart(data) => { "kind": "data", "data": data }
  }
}

///|
pub fn Message::to_json(self : Message) -> Json {
  let m = new_obj()
  m["kind"] = "message".to_json()
  m["messageId"] = self.message_id.to_json()
  m["role"] = role_wire(self.role).to_json()
  m["parts"] = Json::array(self.parts.map(Part::to_json))
  put_opt_str_array(m, "extensions", self.extensions)
  put_opt_str(m, "taskId", self.task_id)
  put_opt_str_array(m, "referenceTaskIds", self.reference_task_ids)
  put_opt_str(m, "contextId", self.context_id)
  put_opt_json(m, "metadata", self.metadata)
  Json::object(m)
}

///|
pub fn Artifact::to_json(self : Artifact) -> Json {
  let a = new_obj()
  a["artifactId"] = self.artifact_id.to_json()
  put_opt_str(a, "name", self.name)
  put_opt_str(a, "description", self.description)
  a["parts"] = Json::array(self.parts.map(Part::to_json))
  put_opt_str_array(a, "extensions", self.extensions)
  put_opt_json(a, "metadata", self.metadata)
  Json::object(a)
}

///|
pub fn TaskStatus::to_json(self : TaskStatus) -> Json {
  let s = new_obj()
  s["state"] = self.state.wire().to_json()
  match self.message {
    Some(msg) => s["message"] = msg.to_json()
    None => ()
  }
  put_opt_str(s, "timestamp", self.timestamp)
  Json::object(s)
}

///|
pub fn Task::to_json(self : Task) -> Json {
  let t = new_obj()
  t["kind"] = "task".to_json()
  t["id"] = self.id.to_json()
  t["contextId"] = self.context_id.to_json()
  t["status"] = self.status.to_json()
  match self.history {
    Some(h) => t["history"] = Json::array(h.map(Message::to_json))
    None => ()
  }
  match self.artifacts {
    Some(ar) => t["artifacts"] = Json::array(ar.map(Artifact::to_json))
    None => ()
  }
  put_opt_json(t, "metadata", self.metadata)
  Json::object(t)
}

// ─── wire decoding ───────────────────────────────────────────────────────────

///|
pub fn Part::from_json(j : Json) -> Part raise {
  guard j is Object(o) else { raise A2AError("part must be a JSON object") }
  match str_field(o, "kind", "") {
    "text" => TextPart(str_field(o, "text", ""))
    "data" =>
      DataPart(
        match o.get("data") {
          Some(d) => d
          None => Json::object({})
        },
      )
    "file" => {
      guard o.get("file") is Some(Object(f)) else {
        raise A2AError("file part is missing its file object")
      }
      let name = opt_str(f, "name")
      let mime_type = opt_str(f, "mimeType")
      match f.get("bytes") {
        Some(String(b)) => FilePart(FileBytes(bytes=b, name~, mime_type~))
        _ =>
          match f.get("uri") {
            Some(String(u)) => FilePart(FileUri(uri=u, name~, mime_type~))
            _ => raise A2AError("file must carry bytes or uri")
          }
      }
    }
    other => raise A2AError("unknown part kind: " + other)
  }
}

///|
pub fn Message::from_json(j : Json) -> Message raise {
  guard j is Object(o) else { raise A2AError("message must be a JSON object") }
  {
    message_id: str_field(o, "messageId", ""),
    role: role_from_wire(str_field(o, "role", "user")),
    parts: parse_parts(o.get("parts")),
    extensions: opt_str_array(o, "extensions"),
    task_id: opt_str(o, "taskId"),
    reference_task_ids: opt_str_array(o, "referenceTaskIds"),
    context_id: opt_str(o, "contextId"),
    metadata: o.get("metadata"),
  }
}

///|
pub fn Artifact::from_json(j : Json) -> Artifact raise {
  guard j is Object(o) else { raise A2AError("artifact must be a JSON object") }
  {
    artifact_id: str_field(o, "artifactId", ""),
    name: opt_str(o, "name"),
    description: opt_str(o, "description"),
    parts: parse_parts(o.get("parts")),
    extensions: opt_str_array(o, "extensions"),
    metadata: o.get("metadata"),
  }
}

///|
pub fn TaskStatus::from_json(j : Json) -> TaskStatus raise {
  guard j is Object(o) else { raise A2AError("status must be a JSON object") }
  {
    state: TaskState::from_wire(str_field(o, "state", "unknown")),
    message: match o.get("message") {
      Some(m) => Some(Message::from_json(m))
      None => None
    },
    timestamp: opt_str(o, "timestamp"),
  }
}

///|
pub fn Task::from_json(j : Json) -> Task raise {
  guard j is Object(o) else { raise A2AError("task must be a JSON object") }
  {
    id: str_field(o, "id", ""),
    context_id: str_field(o, "contextId", ""),
    status: match o.get("status") {
      Some(s) => TaskStatus::from_json(s)
      None => raise A2AError("task is missing its status")
    },
    history: match o.get("history") {
      Some(Array(a)) => Some(parse_messages(a))
      _ => None
    },
    artifacts: match o.get("artifacts") {
      Some(Array(a)) => Some(parse_artifacts(a))
      _ => None
    },
    metadata: o.get("metadata"),
  }
}

// ─── helpers ─────────────────────────────────────────────────────────────────

///|
fn role_wire(r : Role) -> String {
  match r {
    User => "user"
    Agent => "agent"
  }
}

///|
fn role_from_wire(s : String) -> Role {
  if s == "agent" {
    Agent
  } else {
    User
  }
}

///|
fn parse_parts(j : Json?) -> Array[Part] raise {
  let out : Array[Part] = []
  if j is Some(Array(a)) {
    for p in a {
      out.push(Part::from_json(p))
    }
  }
  out
}

///|
fn parse_messages(a : Array[Json]) -> Array[Message] raise {
  let out : Array[Message] = []
  for m in a {
    out.push(Message::from_json(m))
  }
  out
}

///|
fn parse_artifacts(a : Array[Json]) -> Array[Artifact] raise {
  let out : Array[Artifact] = []
  for ar in a {
    out.push(Artifact::from_json(ar))
  }
  out
}

///|
fn new_obj() -> Map[String, Json] {
  Map([])
}

///|
fn put_opt_str(m : Map[String, Json], key : String, v : String?) -> Unit {
  match v {
    Some(s) => m[key] = s.to_json()
    None => ()
  }
}

///|
fn put_opt_json(m : Map[String, Json], key : String, v : Json?) -> Unit {
  match v {
    Some(j) => m[key] = j
    None => ()
  }
}

///|
fn put_opt_str_array(
  m : Map[String, Json],
  key : String,
  v : Array[String]?,
) -> Unit {
  match v {
    Some(a) => m[key] = Json::array(a.map(fn(s) { s.to_json() }))
    None => ()
  }
}

///|
fn str_field(o : Map[String, Json], key : String, default : String) -> String {
  match o.get(key) {
    Some(String(s)) => s
    _ => default
  }
}

///|
fn opt_str(o : Map[String, Json], key : String) -> String? {
  match o.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn opt_str_array(o : Map[String, Json], key : String) -> Array[String]? {
  match o.get(key) {
    Some(Array(a)) => {
      let out : Array[String] = []
      for x in a {
        if x is String(s) {
          out.push(s)
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
pub extend Artifact with Debug::{to_repr}

///|
pub extend Artifact with Eq::{not_equal, equal}

///|
pub extend FileContent with Debug::{to_repr}

///|
pub extend FileContent with Eq::{not_equal, equal}

///|
pub extend Message with Debug::{to_repr}

///|
pub extend Message with Eq::{not_equal, equal}

///|
pub extend Part with Debug::{to_repr}

///|
pub extend Part with Eq::{not_equal, equal}

///|
pub extend Role with Debug::{to_repr}

///|
pub extend Role with Eq::{not_equal, equal}

///|
pub extend Task with Debug::{to_repr}

///|
pub extend Task with Eq::{not_equal, equal}

///|
pub extend TaskState with Debug::{to_repr}

///|
pub extend TaskState with Eq::{not_equal, equal}

///|
pub extend TaskStatus with Debug::{to_repr}

///|
pub extend TaskStatus with Eq::{not_equal, equal}
