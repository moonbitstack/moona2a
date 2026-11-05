// The card an agent publishes about itself: where it listens, what it can do, and what it needs
// from a caller before it will talk. Security schemes and signatures are carried as they came,
// because a card must survive a round trip through this library unchanged.

///|
/// Where the card is served (section 8.2).
pub let card_path : String = "/.well-known/agent-card.json"

///|
/// One address an agent answers on (A2A `AgentInterface`).
#derive(Eq)
pub(all) struct AgentInterface {
  url : String
  protocol_binding : String
  protocol_version : String
  tenant : String?
}

///|
/// An interface speaking JSON-RPC at `url`.
pub fn AgentInterface::json_rpc(
  url : String,
  protocol_version~ : String,
) -> AgentInterface {
  { url, protocol_binding: "JSONRPC", protocol_version, tenant: None, }
}

///|
/// The provider of an agent (A2A `AgentProvider`).
#derive(Eq)
pub(all) struct AgentProvider {
  organization : String
  url : String
}

///|
/// A protocol extension an agent speaks (A2A `AgentExtension`).
#derive(Eq)
pub(all) struct AgentExtension {
  uri : String
  description : String?
  required : Bool
  params : Json?
}

///|
/// What optional parts of the protocol an agent does (A2A `AgentCapabilities`).
#derive(Eq)
pub(all) struct AgentCapabilities {
  streaming : Bool
  push_notifications : Bool
  extended_agent_card : Bool
  extensions : Array[AgentExtension]
}

///|
/// An agent that streams, sends push notifications and serves no extended card.
pub fn AgentCapabilities::streaming_and_push() -> AgentCapabilities {
  {
    streaming: true,
    push_notifications: true,
    extended_agent_card: false,
    extensions: [],
  }
}

///|
/// An agent that answers in a single body and sends nothing out of band.
pub fn AgentCapabilities::plain() -> AgentCapabilities {
  {
    streaming: false,
    push_notifications: false,
    extended_agent_card: false,
    extensions: [],
  }
}

///|
/// One thing an agent is good at (A2A `AgentSkill`).
#derive(Eq)
pub(all) struct AgentSkill {
  id : String
  name : String
  description : String
  tags : Array[String]
  examples : Array[String]
  input_modes : Array[String]
  output_modes : Array[String]
}

///|
/// A skill named and described, tagged with `tags`, with no examples or modes of its own.
pub fn AgentSkill::new(
  id : String,
  name : String,
  description : String,
  tags : Array[String],
) -> AgentSkill {
  {
    id,
    name,
    description,
    tags,
    examples: [],
    input_modes: [],
    output_modes: [],
  }
}

///|
/// An agent's self-description, the document a caller reads before talking to it (A2A `AgentCard`).
#derive(Eq)
pub(all) struct AgentCard {
  name : String
  description : String
  supported_interfaces : Array[AgentInterface]
  provider : AgentProvider?
  version : String
  documentation_url : String?
  capabilities : AgentCapabilities
  security_schemes : Json?
  security_requirements : Json?
  default_input_modes : Array[String]
  default_output_modes : Array[String]
  skills : Array[AgentSkill]
  signatures : Json?
  icon_url : String?
}

///|
/// A card with no provider, no security and no signatures, serving text in and out.
pub fn AgentCard::new(
  name : String,
  description : String,
  version : String,
  url : String,
  skills : Array[AgentSkill],
) -> AgentCard {
  {
    name,
    description,
    supported_interfaces: [
      AgentInterface::json_rpc(url, protocol_version="1.0"),
    ],
    provider: None,
    version,
    documentation_url: None,
    capabilities: AgentCapabilities::plain(),
    security_schemes: None,
    security_requirements: None,
    default_input_modes: ["text/plain"],
    default_output_modes: ["text/plain"],
    skills,
    signatures: None,
    icon_url: None,
  }
}

///|
/// The same card advertising `capabilities`.
pub fn AgentCard::capable(
  self : AgentCard,
  capabilities : AgentCapabilities,
) -> AgentCard {
  { ..self, capabilities, }
}

///|
/// The media types the card offers to take, from its defaults and its skills together.
pub fn AgentCard::input_modes(self : AgentCard) -> Array[String] {
  let modes = self.default_input_modes.copy()
  for skill in self.skills {
    for mode in skill.input_modes {
      if !modes.contains(mode) {
        modes.push(mode)
      }
    }
  }
  modes
}

///|
/// The interface a client should try first, which is the one the card lists first.
pub fn AgentCard::preferred(self : AgentCard) -> AgentInterface? {
  if self.supported_interfaces.length() > 0 {
    Some(self.supported_interfaces[0])
  } else {
    None
  }
}

///|
pub impl @json.ToJson for AgentInterface with fn to_json(self) {
  let fields = object()
  fields["url"] = Json::string(self.url)
  fields["protocolBinding"] = Json::string(self.protocol_binding)
  fields["protocolVersion"] = Json::string(self.protocol_version)
  put_str(fields, "tenant", self.tenant)
  Json::object(fields)
}

///|
pub impl @json.FromJson for AgentInterface with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    url: need_str(fields, "url", path),
    protocol_binding: need_str(fields, "protocolBinding", path),
    protocol_version: opt_str(fields, "protocolVersion").unwrap_or("1.0"),
    tenant: opt_str(fields, "tenant"),
  }
}

///|
pub impl @json.ToJson for AgentProvider with fn to_json(self) {
  Json::object({
    "organization": Json::string(self.organization),
    "url": Json::string(self.url),
  })
}

///|
pub impl @json.FromJson for AgentProvider with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    organization: need_str(fields, "organization", path),
    url: need_str(fields, "url", path),
  }
}

///|
pub impl @json.ToJson for AgentExtension with fn to_json(self) {
  let fields = object()
  fields["uri"] = Json::string(self.uri)
  put_str(fields, "description", self.description)
  if self.required {
    fields["required"] = Json::boolean(true)
  }
  put_json(fields, "params", self.params)
  Json::object(fields)
}

///|
pub impl @json.FromJson for AgentExtension with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    uri: need_str(fields, "uri", path),
    description: opt_str(fields, "description"),
    required: opt_bool(fields, "required").unwrap_or(false),
    params: fields.get("params"),
  }
}

///|
pub impl @json.ToJson for AgentCapabilities with fn to_json(self) {
  let fields = object()
  // Each flag is written even when false: a client reads absence as "not supported", but a card
  // that says `false` out loud saves the reader from guessing.
  fields["streaming"] = Json::boolean(self.streaming)
  fields["pushNotifications"] = Json::boolean(self.push_notifications)
  fields["extendedAgentCard"] = Json::boolean(self.extended_agent_card)
  if self.extensions.length() > 0 {
    fields["extensions"] = Json::array(
      self.extensions.map(AgentExtension::to_json),
    )
  }
  Json::object(fields)
}

///|
pub impl @json.FromJson for AgentCapabilities with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    streaming: opt_bool(fields, "streaming").unwrap_or(false),
    push_notifications: opt_bool(fields, "pushNotifications").unwrap_or(false),
    extended_agent_card: opt_bool(fields, "extendedAgentCard").unwrap_or(false),
    extensions: read_opt_array(
      fields,
      "extensions",
      path,
      AgentExtension::from_json,
    ).unwrap_or([]),
  }
}

///|
pub impl @json.ToJson for AgentSkill with fn to_json(self) {
  let fields = object()
  fields["id"] = Json::string(self.id)
  fields["name"] = Json::string(self.name)
  fields["description"] = Json::string(self.description)
  fields["tags"] = strings(self.tags)
  if self.examples.length() > 0 {
    fields["examples"] = strings(self.examples)
  }
  if self.input_modes.length() > 0 {
    fields["inputModes"] = strings(self.input_modes)
  }
  if self.output_modes.length() > 0 {
    fields["outputModes"] = strings(self.output_modes)
  }
  Json::object(fields)
}

///|
pub impl @json.FromJson for AgentSkill with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    id: need_str(fields, "id", path),
    name: need_str(fields, "name", path),
    description: need_str(fields, "description", path),
    tags: strs_or_empty(fields, "tags"),
    examples: strs_or_empty(fields, "examples"),
    input_modes: strs_or_empty(fields, "inputModes"),
    output_modes: strs_or_empty(fields, "outputModes"),
  }
}

///|
pub impl @json.ToJson for AgentCard with fn to_json(self) {
  let fields = object()
  fields["name"] = Json::string(self.name)
  fields["description"] = Json::string(self.description)
  fields["supportedInterfaces"] = Json::array(
    self.supported_interfaces.map(AgentInterface::to_json),
  )
  match self.provider {
    Some(provider) => fields["provider"] = provider.to_json()
    None => ()
  }
  fields["version"] = Json::string(self.version)
  put_str(fields, "documentationUrl", self.documentation_url)
  fields["capabilities"] = self.capabilities.to_json()
  put_json(fields, "securitySchemes", self.security_schemes)
  put_json(fields, "securityRequirements", self.security_requirements)
  fields["defaultInputModes"] = strings(self.default_input_modes)
  fields["defaultOutputModes"] = strings(self.default_output_modes)
  fields["skills"] = Json::array(self.skills.map(AgentSkill::to_json))
  put_json(fields, "signatures", self.signatures)
  put_str(fields, "iconUrl", self.icon_url)
  Json::object(fields)
}

///|
pub impl @json.FromJson for AgentCard with fn from_json(json, path) {
  let fields = as_object(json, path)
  {
    name: need_str(fields, "name", path),
    description: need_str(fields, "description", path),
    supported_interfaces: read_array(
      fields,
      "supportedInterfaces",
      path,
      AgentInterface::from_json,
    ),
    provider: read_opt(fields, "provider", path, AgentProvider::from_json),
    version: need_str(fields, "version", path),
    documentation_url: opt_str(fields, "documentationUrl"),
    capabilities: match opt_object(fields, "capabilities") {
      Some(capabilities) =>
        AgentCapabilities::from_json(
          Json::object(capabilities),
          path.add_key("capabilities"),
        )
      None => raise wrong_type(path, "capabilities", "a capabilities object")
    },
    security_schemes: fields.get("securitySchemes"),
    security_requirements: fields.get("securityRequirements"),
    default_input_modes: strs_or_empty(fields, "defaultInputModes"),
    default_output_modes: strs_or_empty(fields, "defaultOutputModes"),
    skills: read_opt_array(fields, "skills", path, AgentSkill::from_json).unwrap_or([],
    ),
    signatures: fields.get("signatures"),
    icon_url: opt_str(fields, "iconUrl"),
  }
}

///|
pub extend AgentInterface with @json.ToJson::{to_json}

///|
pub extend AgentProvider with @json.ToJson::{to_json}

///|
pub extend AgentExtension with @json.ToJson::{to_json}

///|
pub extend AgentCapabilities with @json.ToJson::{to_json}

///|
pub extend AgentSkill with @json.ToJson::{to_json}

///|
pub extend AgentCard with @json.ToJson::{to_json}

///|
pub extend AgentInterface with @json.FromJson::{from_json}

///|
pub extend AgentProvider with @json.FromJson::{from_json}

///|
pub extend AgentExtension with @json.FromJson::{from_json}

///|
pub extend AgentCapabilities with @json.FromJson::{from_json}

///|
pub extend AgentSkill with @json.FromJson::{from_json}

///|
pub extend AgentCard with @json.FromJson::{from_json}

///|
pub extend AgentInterface with Eq::{not_equal, equal}

///|
pub extend AgentProvider with Eq::{not_equal, equal}

///|
pub extend AgentExtension with Eq::{not_equal, equal}

///|
pub extend AgentCapabilities with Eq::{not_equal, equal}

///|
pub extend AgentSkill with Eq::{not_equal, equal}

///|
pub extend AgentCard with Eq::{not_equal, equal}
