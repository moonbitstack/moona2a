// The A2A agent card round-trips through its wire form (including the verbatim security/signature
// pass-through), and a resolver fetches and parses it from an injectable source.

///|
/// A card source returning a canned card JSON.
struct MockCardSource {
  card : Json
}

///|
impl @a2a.CardSource for MockCardSource with fn fetch(self) {
  self.card
}

///|
test "a2a agent card: a full card round-trips, security/signatures preserved verbatim" {
  let card : @a2a.AgentCard = {
    protocol_version: "0.3.0",
    name: "greeter",
    description: "greets people",
    url: "https://agent/x",
    preferred_transport: "JSONRPC",
    additional_interfaces: Some([
      { url: "https://agent/grpc", transport: "GRPC", },
    ]),
    icon_url: Some("https://agent/icon.png"),
    provider: Some({ organization: "acme", url: "https://acme", }),
    version: "1.2.3",
    documentation_url: None,
    capabilities: {
      streaming: Some(true),
      push_notifications: Some(false),
      state_transition_history: None,
      extensions: Some([
        {
          uri: "ext://a",
          description: Some("an ext"),
          required: Some(true),
          params: None,
        },
      ]),
    },
    security_schemes: Some(
      @json.parse("{\"apiKey\":{\"type\":\"apiKey\",\"name\":\"X\"}}"),
    ),
    security: Some(@json.parse("[{\"apiKey\":[]}]")),
    default_input_modes: ["text/plain"],
    default_output_modes: ["text/plain", "application/json"],
    skills: [
      {
        id: "greet",
        name: "Greet",
        description: "say hi",
        tags: ["social"],
        examples: Some(["hi there"]),
        input_modes: None,
        output_modes: None,
      },
    ],
    supports_authenticated_extended_card: Some(false),
    signatures: Some(@json.parse("[{\"protected\":\"h\",\"signature\":\"s\"}]")),
  }
  assert_eq(@a2a.AgentCard::from_json(card.to_json()), card)
}

///|
test "a2a agent card: the resolver fetches and parses the card from its source" {
  let card : @a2a.AgentCard = {
    protocol_version: "0.3.0",
    name: "n",
    description: "d",
    url: "u",
    preferred_transport: "JSONRPC",
    additional_interfaces: None,
    icon_url: None,
    provider: None,
    version: "1",
    documentation_url: None,
    capabilities: {
      streaming: None,
      push_notifications: None,
      state_transition_history: None,
      extensions: None,
    },
    security_schemes: None,
    security: None,
    default_input_modes: ["text/plain"],
    default_output_modes: ["text/plain"],
    skills: [],
    supports_authenticated_extended_card: None,
    signatures: None,
  }
  let resolved = @a2a.resolve_agent_card(MockCardSource::{
    card: card.to_json(),
  })
  assert_eq(resolved.name, "n")
  assert_eq(resolved.capabilities.streaming, None)
  assert_eq(resolved, card)
}
