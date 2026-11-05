// Who sent a message, and the message itself.

///|
/// The sender of a message (A2A `Role`).
#derive(Eq)
pub(all) enum Role {
  Unspecified
  User
  Agent
}

///|
/// The wire name of the role, as ProtoJSON writes an enum.
pub fn Role::wire(self : Role) -> String {
  match self {
    Unspecified => "ROLE_UNSPECIFIED"
    User => "ROLE_USER"
    Agent => "ROLE_AGENT"
  }
}

///|
/// The role named by its wire form. Both the proto name and the bare word are read, because
/// clients written against earlier drafts send the bare word.
pub fn Role::from_wire(name : String) -> Role {
  match name {
    "ROLE_USER" | "user" => User
    "ROLE_AGENT" | "agent" => Agent
    _ => Unspecified
  }
}

///|
pub impl @json.ToJson for Role with fn to_json(self) {
  Json::string(self.wire())
}

///|
pub impl @json.FromJson for Role with fn from_json(json, path) {
  match json {
    String(name) => Role::from_wire(name)
    _ => raise @json.JsonDecodeError((path, "want a role name"))
  }
}

///|
/// One turn of a conversation between a client and an agent (A2A `Message`).
#derive(Eq)
pub(all) struct Message {
  message_id : String
  role : Role
  parts : Array[Part]
  context_id : String?
  task_id : String?
  reference_task_ids : Array[String]?
  extensions : Array[String]?
  metadata : Json?
}

///|
/// A message from the client, carrying one text part.
pub fn Message::user(message_id : String, text : String) -> Message {
  Message::new(message_id, User, [Part::text(text)])
}

///|
/// A message from the agent, carrying one text part.
pub fn Message::agent(message_id : String, text : String) -> Message {
  Message::new(message_id, Agent, [Part::text(text)])
}

///|
/// A message from `role` carrying `parts`.
pub fn Message::new(
  message_id : String,
  role : Role,
  parts : Array[Part],
) -> Message {
  {
    message_id,
    role,
    parts,
    context_id: None,
    task_id: None,
    reference_task_ids: None,
    extensions: None,
    metadata: None,
  }
}

///|
/// The same message, continuing the task and context given.
pub fn Message::in_task(
  self : Message,
  task_id : String,
  context_id : String,
) -> Message {
  { ..self, task_id: Some(task_id), context_id: Some(context_id), }
}

///|
/// The text of every text part, in order and with nothing added: a part is content, so joining
/// must not invent characters between them.
pub fn Message::text(self : Message) -> String {
  let texts : Array[String] = []
  for part in self.parts {
    guard part.content is Text(text) else { continue }
    texts.push(text)
  }
  texts.join("")
}

///|
pub impl @json.ToJson for Message with fn to_json(self) {
  let fields = object()
  fields["messageId"] = Json::string(self.message_id)
  fields["role"] = self.role.to_json()
  fields["parts"] = Json::array(self.parts.map(Part::to_json))
  put_str(fields, "contextId", self.context_id)
  put_str(fields, "taskId", self.task_id)
  put_strs(fields, "referenceTaskIds", self.reference_task_ids)
  put_strs(fields, "extensions", self.extensions)
  put_json(fields, "metadata", self.metadata)
  Json::object(fields)
}

///|
pub impl @json.FromJson for Message with fn from_json(json, path) {
  let fields = as_object(json, path)
  let role = match fields.get("role") {
    Some(String(name)) => Role::from_wire(name)
    _ => raise wrong_type(path, "role", "a role name")
  }
  {
    message_id: need_str(fields, "messageId", path),
    role,
    parts: read_array(fields, "parts", path, Part::from_json),
    context_id: opt_str(fields, "contextId"),
    task_id: opt_str(fields, "taskId"),
    reference_task_ids: opt_strs(fields, "referenceTaskIds"),
    extensions: opt_strs(fields, "extensions"),
    metadata: fields.get("metadata"),
  }
}

///|
pub extend Role with @json.ToJson::{to_json}

///|
pub extend Message with @json.ToJson::{to_json}

///|
pub extend Role with @json.FromJson::{from_json}

///|
pub extend Message with @json.FromJson::{from_json}

///|
pub extend Role with Eq::{not_equal, equal}

///|
pub extend Message with Eq::{not_equal, equal}
