// What a span says about the agent it belongs to. The attribute names come from the
// semantic conventions wherever one exists; the protocol's own two are here.

///|
/// Who an agent is, in the terms the semantic conventions describe an agent with.
#derive(Debug)
pub(all) struct Agent {
  /// The address the agent answers on. On an open network that address is what tells
  /// two agents of the same name apart, which is why it is the id.
  id : String
  name : String
  description : String?
  version : String?
}

///|
/// An agent named `name`, answering at `id`.
pub fn Agent::new(
  id~ : String,
  name~ : String,
  description? : String,
  version? : String,
) -> Agent {
  { id, name, description, version, }
}

///|
/// The agent a card describes. A card carries no id of its own, so the address of the
/// interface a caller would use stands in for one.
pub fn Agent::of_card(card : @moona2a.AgentCard) -> Agent {
  let id = match card.preferred() {
    Some(interface) => interface.url
    None => card.name
  }
  {
    id,
    name: card.name,
    description: Some(card.description),
    version: Some(card.version),
  }
}

///|
/// The agent under a server's card.
pub fn Agent::of_server(server : @moona2a.Server) -> Agent {
  Agent::of_card(server.card())
}

///|
/// What the instrumentation writes into a span.
#derive(Debug)
pub(all) struct Settings {
  /// Whether the text of the messages is recorded. Off by default: a span store is
  /// not the place for a caller's prompt unless the operator says it is.
  record_content : Bool
  /// The longest text recorded in one attribute, in characters. Above this a
  /// message is cut, so one long prompt cannot cost a span store a megabyte.
  text_limit : Int32
}

///|
/// Message text left out, and a message cut at 512 characters.
pub let settings : Settings = { record_content: false, text_limit: 512, }

///|
/// The instrumentation: one tracer, one clock, and who the agent is.
///
/// The clock is handed in rather than read here, so a replay can put a run on a
/// timeline it chose. It counts nanoseconds, which is what a span's times are in.
pub(all) struct Tracing {
  tracer : @trace.Tracer
  now : () -> Int64
  agent : Agent
  settings : Settings
}

///|
/// Instrumentation that writes to `tracer`, times spans with `now`, and describes
/// `agent`.
pub fn Tracing::new(
  tracer~ : @trace.Tracer,
  now~ : () -> Int64,
  agent~ : Agent,
  settings~ : Settings = settings,
) -> Tracing {
  { tracer, now, agent, settings, }
}

///|
/// The same instrumentation, recording what the messages said. For a development
/// environment, where reading the prompt in the trace is the point.
pub fn Tracing::recording_content(self : Tracing) -> Tracing {
  { ..self, settings: { ..self.settings, record_content: true, }, }
}

///|
/// The same instrumentation, cutting recorded text at `limit` characters.
pub fn Tracing::at_most(self : Tracing, limit : Int32) -> Tracing {
  { ..self, settings: { ..self.settings, text_limit: limit, }, }
}

///|
/// The span name a run and a message call share: the operation, then the agent.
fn Tracing::invocation_name(self : Tracing) -> String {
  invoke_agent + " " + self.agent.name
}

///|
/// `agent` as the conventions spell it. `gen_ai.agent.id` and `gen_ai.agent.name` are
/// required on an agent span, so they are always written; the other two are not.
fn Tracing::identity_attributes(
  self : Tracing,
) -> Array[(String, @trace.Value)] {
  let attributes : Array[(String, @trace.Value)] = [
    (@semconv.gen_ai_agent_id, @trace.Str(self.agent.id)),
    (@semconv.gen_ai_agent_name, @trace.Str(self.agent.name)),
  ]
  match self.agent.description {
    Some(text) =>
      attributes.push((@semconv.gen_ai_agent_description, @trace.Str(text)))
    None => ()
  }
  match self.agent.version {
    Some(text) =>
      attributes.push((@semconv.gen_ai_agent_version, @trace.Str(text)))
    None => ()
  }
  attributes
}

///|
/// What a span that invokes the agent says: who it is, and that it was invoked.
fn Tracing::agent_attributes(self : Tracing) -> Array[(String, @trace.Value)] {
  let attributes = self.identity_attributes()
  attributes.push((@semconv.gen_ai_operation_name, @trace.Str(invoke_agent)))
  attributes
}

///|
/// Open the span `name` covers, or `None` when the tracer's source of randomness is
/// broken — a run is worth more than its trace, so an untraced one goes ahead.
fn Tracing::begin(
  self : Tracing,
  name : String,
  kind : @trace.SpanKind,
  attributes : Array[(String, @trace.Value)],
) -> @trace.Span? {
  Some(self.tracer.start(name, kind~, at=(self.now)(), attributes~)) catch {
    _ => None
  }
}

///|
/// The text of a message as the conventions write `gen_ai.input.messages`: a JSON
/// array of messages, each with a role and its parts. Part contents other than text
/// are named but not carried, since what a blob holds is not a span's business.
fn Tracing::messages_json(self : Tracing, message : @moona2a.Message) -> String {
  let parts : Array[Json] = []
  for part in message.parts {
    let fields : Map[String, Json] = Map([])
    match part.content {
      Text(text) => {
        fields["type"] = Json::string("text")
        fields["content"] = Json::string(
          clipped(text, self.settings.text_limit),
        )
      }
      Data(value) => {
        fields["type"] = Json::string("json")
        fields["content"] = value
      }
      Url(url~, media_type~, ..) => {
        fields["type"] = Json::string("uri")
        fields["uri"] = Json::string(url)
        match media_type {
          Some(media_type) => fields["mime_type"] = Json::string(media_type)
          None => ()
        }
      }
      Raw(bytes~, media_type~, ..) => {
        fields["type"] = Json::string("blob")
        fields["size"] = Json::number(bytes.length().to_double())
        match media_type {
          Some(media_type) => fields["mime_type"] = Json::string(media_type)
          None => ()
        }
      }
    }
    parts.push(Json::object(fields))
  }
  let entry : Map[String, Json] = Map([])
  entry["role"] = Json::string(
    match message.role {
      User => "user"
      Agent => "assistant"
      Unspecified => "user"
    },
  )
  entry["parts"] = Json::array(parts)
  Json::array([Json::object(entry)]).stringify()
}

///|
/// The answer as `gen_ai.output.messages` writes it: one assistant message with the
/// text the agent settled on.
fn answer_json(text : String, limit : Int32) -> String {
  let part : Map[String, Json] = Map([])
  part["type"] = Json::string("text")
  part["content"] = Json::string(clipped(text, limit))
  let entry : Map[String, Json] = Map([])
  entry["role"] = Json::string("assistant")
  entry["parts"] = Json::array([Json::object(part)])
  Json::array([Json::object(entry)]).stringify()
}

///|
/// The first `limit` characters of `text`.
fn clipped(text : String, limit : Int32) -> String {
  if limit <= 0 || text.length() <= limit {
    return text
  }
  let kept = StringBuilder()
  let mut taken = 0
  for character in text {
    if taken >= limit {
      break
    }
    kept.write_char(character)
    taken = taken + 1
  }
  kept.to_string()
}

///|
pub extend Agent with @debug.Debug::{to_repr}

///|
pub extend Settings with @debug.Debug::{to_repr}
