///|
/// A card source that returns a fixed card document (Koog's resolver fetches this
/// over HTTP; here it is injected).
struct StaticSource {
  doc : Json
}

///|
impl @moona2a.CardSource for StaticSource with fn fetch(self) {
  self.doc
}

///|
/// The A2A agent card (Agent-to-Agent protocol): a self-description an agent
/// publishes — its transports, provider, skills, and capabilities. It round-trips
/// through its wire JSON (security and signature blocks pass through verbatim), and
/// `resolve_agent_card` fetches and parses it from a source.
///
///     moon run examples/24-a2a-card --target native
#coverage.skip
fn main {
  let card : @moona2a.AgentCard = {
    protocol_version: "0.3.0",
    name: "greeter",
    description: "greets people in many languages",
    url: "https://agent.example/jsonrpc",
    preferred_transport: "JSONRPC",
    additional_interfaces: Some([
      { url: "https://agent.example/grpc", transport: "GRPC", },
    ]),
    icon_url: Some("https://agent.example/icon.png"),
    provider: Some({ organization: "heke1228", url: "https://heke.example", }),
    version: "1.2.3",
    documentation_url: None,
    capabilities: {
      streaming: Some(true),
      push_notifications: Some(false),
      state_transition_history: None,
      extensions: Some([
        {
          uri: "ext://trace",
          description: Some("tracing extension"),
          required: Some(false),
          params: None,
        },
      ]),
    },
    security_schemes: Some(
      @json.parse("{\"apiKey\":{\"type\":\"apiKey\",\"name\":\"X-Key\"}}"),
    ),
    security: Some(@json.parse("[{\"apiKey\":[]}]")),
    default_input_modes: ["text/plain"],
    default_output_modes: ["text/plain", "application/json"],
    skills: [
      {
        id: "greet",
        name: "Greet",
        description: "say hello",
        tags: ["social"],
        examples: Some(["hi there"]),
        input_modes: None,
        output_modes: None,
      },
    ],
    supports_authenticated_extended_card: Some(false),
    signatures: None,
  } catch {
    e => {
      println("bad seed json: " + e.to_string())
      return
    }
  }
  println("card: " + card.name + " v" + card.version)
  println("  transport: " + card.preferred_transport)
  println("  skills: " + card.skills.map(s => s.name).join(", "))
  let streaming = match card.capabilities.streaming {
    Some(b) => b.to_string()
    None => "unset"
  }
  println("  streaming capable: " + streaming)

  // Round-trip through the wire form.
  let wire = card.to_json()
  try {
    let back = @moona2a.AgentCard::from_json(wire)
    println("round-trips equal: \{back == card}")
  } catch {
    e => println("from_json failed: " + e.to_string())
  }

  // The resolver fetches and parses from an injected source.
  try {
    let resolved = @moona2a.resolve_agent_card(StaticSource::{ doc: wire, })
    println("resolved name: " + resolved.name)
  } catch {
    e => println("resolve failed: " + e.to_string())
  }
}
