// The A2A agent card (Koog `a2a-core` `AgentCard` + `a2a-client` `AgentCardResolver`): an agent's
// self-description, served at `/.well-known/agent-card.json`, that a caller reads to discover the
// agent's name, endpoint, transport, capabilities and skills before talking to it. The discovery
// fields are typed; the security-scheme and signature sub-trees — a large OpenAPI-style hierarchy —
// are carried verbatim as `Json` so the card round-trips losslessly without re-modelling all of it.

///|
/// A transport endpoint the agent also serves on (A2A `AgentInterface`).
pub(all) struct AgentInterface {
  url : String
  transport : String
} derive(Eq, Debug)

///|
/// The organization behind an agent (A2A `AgentProvider`).
pub(all) struct AgentProvider {
  organization : String
  url : String
} derive(Eq, Debug)

///|
/// A protocol extension an agent supports (A2A `AgentExtension`).
pub(all) struct AgentExtension {
  uri : String
  description : String?
  required : Bool?
  params : Json?
} derive(Eq, Debug)

///|
/// What optional protocol features an agent supports (A2A `AgentCapabilities`).
pub(all) struct AgentCapabilities {
  streaming : Bool?
  push_notifications : Bool?
  state_transition_history : Bool?
  extensions : Array[AgentExtension]?
} derive(Eq, Debug)

///|
/// One capability an agent advertises (A2A `AgentSkill`).
pub(all) struct AgentSkill {
  id : String
  name : String
  description : String
  tags : Array[String]
  examples : Array[String]?
  input_modes : Array[String]?
  output_modes : Array[String]?
} derive(Eq, Debug)

///|
/// An agent's public description and discovery document (A2A `AgentCard`).
pub(all) struct AgentCard {
  protocol_version : String
  name : String
  description : String
  url : String
  preferred_transport : String
  additional_interfaces : Array[AgentInterface]?
  icon_url : String?
  provider : AgentProvider?
  version : String
  documentation_url : String?
  capabilities : AgentCapabilities
  security_schemes : Json?
  security : Json?
  default_input_modes : Array[String]
  default_output_modes : Array[String]
  skills : Array[AgentSkill]
  supports_authenticated_extended_card : Bool?
  signatures : Json?
} derive(Eq, Debug)

///|
/// Where an agent card is fetched from (Koog `AgentCardResolver`): typically an HTTP GET of the
/// agent's well-known card URL, injectable so tests can supply a card without a network.
pub(open) trait CardSource {
  fn fetch(Self) -> Json raise
}

///|
/// Resolve and parse an agent's card from `source` (Koog `A2AClient.getAgentCard`).
pub fn resolve_agent_card(source : &CardSource) -> AgentCard raise {
  AgentCard::from_json(source.fetch())
}

// ─── wire encoding ───────────────────────────────────────────────────────────

///|
pub fn AgentInterface::to_json(self : AgentInterface) -> Json {
  { "url": self.url, "transport": self.transport }
}

///|
pub fn AgentProvider::to_json(self : AgentProvider) -> Json {
  { "organization": self.organization, "url": self.url }
}

///|
pub fn AgentExtension::to_json(self : AgentExtension) -> Json {
  let e = new_obj()
  e["uri"] = self.uri.to_json()
  put_opt_str(e, "description", self.description)
  put_opt_bool(e, "required", self.required)
  put_opt_json(e, "params", self.params)
  Json::object(e)
}

///|
pub fn AgentCapabilities::to_json(self : AgentCapabilities) -> Json {
  let c = new_obj()
  put_opt_bool(c, "streaming", self.streaming)
  put_opt_bool(c, "pushNotifications", self.push_notifications)
  put_opt_bool(c, "stateTransitionHistory", self.state_transition_history)
  match self.extensions {
    Some(exts) =>
      c["extensions"] = Json::array(exts.map(AgentExtension::to_json))
    None => ()
  }
  Json::object(c)
}

///|
pub fn AgentSkill::to_json(self : AgentSkill) -> Json {
  let s = new_obj()
  s["id"] = self.id.to_json()
  s["name"] = self.name.to_json()
  s["description"] = self.description.to_json()
  s["tags"] = str_json_array(self.tags)
  put_opt_str_array(s, "examples", self.examples)
  put_opt_str_array(s, "inputModes", self.input_modes)
  put_opt_str_array(s, "outputModes", self.output_modes)
  Json::object(s)
}

///|
pub fn AgentCard::to_json(self : AgentCard) -> Json {
  let c = new_obj()
  c["protocolVersion"] = self.protocol_version.to_json()
  c["name"] = self.name.to_json()
  c["description"] = self.description.to_json()
  c["url"] = self.url.to_json()
  c["preferredTransport"] = self.preferred_transport.to_json()
  match self.additional_interfaces {
    Some(ifs) =>
      c["additionalInterfaces"] = Json::array(ifs.map(AgentInterface::to_json))
    None => ()
  }
  put_opt_str(c, "iconUrl", self.icon_url)
  match self.provider {
    Some(p) => c["provider"] = p.to_json()
    None => ()
  }
  c["version"] = self.version.to_json()
  put_opt_str(c, "documentationUrl", self.documentation_url)
  c["capabilities"] = self.capabilities.to_json()
  put_opt_json(c, "securitySchemes", self.security_schemes)
  put_opt_json(c, "security", self.security)
  c["defaultInputModes"] = str_json_array(self.default_input_modes)
  c["defaultOutputModes"] = str_json_array(self.default_output_modes)
  c["skills"] = Json::array(self.skills.map(AgentSkill::to_json))
  put_opt_bool(
    c,
    "supportsAuthenticatedExtendedCard",
    self.supports_authenticated_extended_card,
  )
  put_opt_json(c, "signatures", self.signatures)
  Json::object(c)
}

// ─── wire decoding ───────────────────────────────────────────────────────────

///|
pub fn AgentInterface::from_json(j : Json) -> AgentInterface raise {
  guard j is Object(o) else {
    raise A2AError("agent interface must be an object")
  }
  { url: str_field(o, "url", ""), transport: str_field(o, "transport", ""), }
}

///|
pub fn AgentProvider::from_json(j : Json) -> AgentProvider raise {
  guard j is Object(o) else {
    raise A2AError("agent provider must be an object")
  }
  {
    organization: str_field(o, "organization", ""),
    url: str_field(o, "url", ""),
  }
}

///|
pub fn AgentExtension::from_json(j : Json) -> AgentExtension raise {
  guard j is Object(o) else {
    raise A2AError("agent extension must be an object")
  }
  {
    uri: str_field(o, "uri", ""),
    description: opt_str(o, "description"),
    required: opt_bool(o, "required"),
    params: o.get("params"),
  }
}

///|
pub fn AgentCapabilities::from_json(j : Json) -> AgentCapabilities raise {
  guard j is Object(o) else { raise A2AError("capabilities must be an object") }
  {
    streaming: opt_bool(o, "streaming"),
    push_notifications: opt_bool(o, "pushNotifications"),
    state_transition_history: opt_bool(o, "stateTransitionHistory"),
    extensions: match o.get("extensions") {
      Some(Array(a)) => {
        let out : Array[AgentExtension] = []
        for e in a {
          out.push(AgentExtension::from_json(e))
        }
        Some(out)
      }
      _ => None
    },
  }
}

///|
pub fn AgentSkill::from_json(j : Json) -> AgentSkill raise {
  guard j is Object(o) else { raise A2AError("agent skill must be an object") }
  {
    id: str_field(o, "id", ""),
    name: str_field(o, "name", ""),
    description: str_field(o, "description", ""),
    tags: req_str_array(o, "tags"),
    examples: opt_str_array(o, "examples"),
    input_modes: opt_str_array(o, "inputModes"),
    output_modes: opt_str_array(o, "outputModes"),
  }
}

///|
pub fn AgentCard::from_json(j : Json) -> AgentCard raise {
  guard j is Object(o) else { raise A2AError("agent card must be an object") }
  {
    protocol_version: str_field(o, "protocolVersion", "0.3.0"),
    name: str_field(o, "name", ""),
    description: str_field(o, "description", ""),
    url: str_field(o, "url", ""),
    preferred_transport: str_field(o, "preferredTransport", "JSONRPC"),
    additional_interfaces: match o.get("additionalInterfaces") {
      Some(Array(a)) => {
        let out : Array[AgentInterface] = []
        for i in a {
          out.push(AgentInterface::from_json(i))
        }
        Some(out)
      }
      _ => None
    },
    icon_url: opt_str(o, "iconUrl"),
    provider: match o.get("provider") {
      Some(p) => Some(AgentProvider::from_json(p))
      None => None
    },
    version: str_field(o, "version", ""),
    documentation_url: opt_str(o, "documentationUrl"),
    capabilities: match o.get("capabilities") {
      Some(c) => AgentCapabilities::from_json(c)
      None => raise A2AError("agent card is missing capabilities")
    },
    security_schemes: o.get("securitySchemes"),
    security: o.get("security"),
    default_input_modes: req_str_array(o, "defaultInputModes"),
    default_output_modes: req_str_array(o, "defaultOutputModes"),
    skills: {
      let out : Array[AgentSkill] = []
      if o.get("skills") is Some(Array(a)) {
        for s in a {
          out.push(AgentSkill::from_json(s))
        }
      }
      out
    },
    supports_authenticated_extended_card: opt_bool(
      o, "supportsAuthenticatedExtendedCard",
    ),
    signatures: o.get("signatures"),
  }
}

// ─── helpers ─────────────────────────────────────────────────────────────────

///|
fn str_json_array(xs : Array[String]) -> Json {
  Json::array(xs.map(fn(s) { s.to_json() }))
}

///|
fn req_str_array(o : Map[String, Json], key : String) -> Array[String] {
  match opt_str_array(o, key) {
    Some(a) => a
    None => []
  }
}

///|
fn put_opt_bool(m : Map[String, Json], key : String, v : Bool?) -> Unit {
  match v {
    Some(b) => m[key] = b.to_json()
    None => ()
  }
}

///|
fn opt_bool(o : Map[String, Json], key : String) -> Bool? {
  match o.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
pub extend AgentCapabilities with Debug::{to_repr}

///|
pub extend AgentCapabilities with Eq::{not_equal, equal}

///|
pub extend AgentCard with Debug::{to_repr}

///|
pub extend AgentCard with Eq::{not_equal, equal}

///|
pub extend AgentExtension with Debug::{to_repr}

///|
pub extend AgentExtension with Eq::{not_equal, equal}

///|
pub extend AgentInterface with Debug::{to_repr}

///|
pub extend AgentInterface with Eq::{not_equal, equal}

///|
pub extend AgentProvider with Debug::{to_repr}

///|
pub extend AgentProvider with Eq::{not_equal, equal}

///|
pub extend AgentSkill with Debug::{to_repr}

///|
pub extend AgentSkill with Eq::{not_equal, equal}
