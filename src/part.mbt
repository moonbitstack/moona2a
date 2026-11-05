// A part: one piece of a message or an artifact. Exactly one of text, raw bytes, a URL or a JSON
// value carries the content; `filename`, `media_type` and `metadata` describe it.

///|
/// What a part carries (A2A `Part.content` oneof).
#derive(Eq)
pub(all) enum PartContent {
  /// Plain text.
  Text(String)
  /// Bytes carried inline, base64 on the wire.
  Raw(bytes~ : Bytes, filename~ : String?, media_type~ : String?)
  /// A URL pointing at the content.
  Url(url~ : String, filename~ : String?, media_type~ : String?)
  /// A structured JSON value.
  Data(Json)
}

///|
/// One piece of a message or an artifact (A2A `Part`).
#derive(Eq)
pub(all) struct Part {
  content : PartContent
  metadata : Json?
}

///|
/// A text part.
pub fn Part::text(text : String) -> Part {
  { content: Text(text), metadata: None, }
}

///|
/// A part carrying bytes inline.
pub fn Part::bytes(
  bytes : Bytes,
  filename? : String,
  media_type? : String,
) -> Part {
  { content: Raw(bytes~, filename~, media_type~), metadata: None, }
}

///|
/// A part pointing at content by URL.
pub fn Part::uri(
  url : String,
  filename? : String,
  media_type? : String,
) -> Part {
  { content: Url(url~, filename~, media_type~), metadata: None, }
}

///|
/// A part carrying a structured JSON value.
pub fn Part::data(data : Json) -> Part {
  { content: Data(data), metadata: None, }
}

///|
/// The same part with metadata attached.
pub fn Part::with_metadata(self : Part, metadata : Json) -> Part {
  { ..self, metadata: Some(metadata), }
}

///|
/// The text this part carries, when it is a text part.
pub fn Part::text_of(self : Part) -> String? {
  match self.content {
    Text(text) => Some(text)
    _ => None
  }
}

///|
/// The media type this part declares, when it declares one.
pub fn Part::media_type(self : Part) -> String? {
  match self.content {
    Raw(media_type~, ..) | Url(media_type~, ..) => media_type
    Text(_) | Data(_) => None
  }
}

///|
pub impl @json.ToJson for Part with fn to_json(self) {
  let fields = object()
  match self.content {
    Text(text) => fields["text"] = Json::string(text)
    Raw(bytes~, ..) =>
      fields["raw"] = Json::string(@base64.encode(bytes[:], padding=true))
    Url(url~, ..) => fields["url"] = Json::string(url)
    Data(data) => fields["data"] = data
  }
  match self.content {
    Raw(filename~, media_type~, ..) | Url(filename~, media_type~, ..) => {
      put_str(fields, "filename", filename)
      put_str(fields, "mediaType", media_type)
    }
    Text(_) | Data(_) => ()
  }
  put_json(fields, "metadata", self.metadata)
  Json::object(fields)
}

///|
pub impl @json.FromJson for Part with fn from_json(json, path) {
  let fields = as_object(json, path)
  // The oneof is read in proto field order: a part naming more than one content kind keeps the
  // first, which is what a reader of the schema expects rather than an error.
  let content = if fields.get("text") is Some(String(text)) {
    Text(text)
  } else if fields.get("raw") is Some(String(encoded)) {
    Raw(
      bytes=@base64.decode(encoded) catch {
        _ => raise @json.JsonDecodeError((path.add_key("raw"), "want base64"))
      },
      filename=opt_str(fields, "filename"),
      media_type=opt_str(fields, "mediaType"),
    )
  } else if fields.get("url") is Some(String(url)) {
    Url(
      url~,
      filename=opt_str(fields, "filename"),
      media_type=opt_str(fields, "mediaType"),
    )
  } else if fields.get("data") is Some(data) {
    Data(data)
  } else {
    raise @json.JsonDecodeError(
      (path, "want a part with text, raw, url or data"),
    )
  }
  { content, metadata: fields.get("metadata"), }
}

///|
pub extend Part with @json.ToJson::{to_json}

///|
pub extend Part with @json.FromJson::{from_json}

///|
pub extend PartContent with Eq::{not_equal, equal}

///|
pub extend Part with Eq::{not_equal, equal}
