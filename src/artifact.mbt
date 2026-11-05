// What a task produces: a named bag of parts that a client can collect when the task finishes.

///|
/// An output a task produced (A2A `Artifact`).
#derive(Eq)
pub(all) struct Artifact {
  artifact_id : String
  name : String?
  description : String?
  parts : Array[Part]
  extensions : Array[String]?
  metadata : Json?
}

///|
/// An artifact carrying `parts` under `artifact_id`.
pub fn Artifact::new(artifact_id : String, parts : Array[Part]) -> Artifact {
  {
    artifact_id,
    name: None,
    description: None,
    parts,
    extensions: None,
    metadata: None,
  }
}

///|
/// An artifact carrying one text part.
pub fn Artifact::text(artifact_id : String, text : String) -> Artifact {
  Artifact::new(artifact_id, [Part::text(text)])
}

///|
/// The same artifact under `name`.
pub fn Artifact::named(self : Artifact, name : String) -> Artifact {
  { ..self, name: Some(name), }
}

///|
/// The text of every text part, in order and with nothing added: a part is content, so joining
/// must not invent characters between them.
pub fn Artifact::text_of(self : Artifact) -> String {
  let texts : Array[String] = []
  for part in self.parts {
    guard part.content is Text(text) else { continue }
    texts.push(text)
  }
  texts.join("")
}

///|
pub impl @json.ToJson for Artifact with fn to_json(self) {
  let fields = object()
  fields["artifactId"] = Json::string(self.artifact_id)
  put_str(fields, "name", self.name)
  put_str(fields, "description", self.description)
  fields["parts"] = Json::array(self.parts.map(Part::to_json))
  put_strs(fields, "extensions", self.extensions)
  put_json(fields, "metadata", self.metadata)
  Json::object(fields)
}

///|
pub impl @json.FromJson for Artifact with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    artifact_id: need_str(fields, "artifactId", path),
    name: opt_str(fields, "name"),
    description: opt_str(fields, "description"),
    parts: read_array(fields, "parts", path, Part::from_json),
    extensions: opt_strs(fields, "extensions"),
    metadata: fields.get("metadata"),
  }
}

///|
pub extend Artifact with @json.ToJson::{to_json}

///|
pub extend Artifact with @json.FromJson::{from_json}

///|
pub extend Artifact with Eq::{not_equal, equal}
