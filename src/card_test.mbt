// The card an agent publishes: it must survive a round trip unchanged, including the parts this
// library does not model as fields, and it must answer the questions a client asks of it.

///|
test "card: a full card round-trips, security schemes and signatures verbatim" {
  let card : @moona2a.AgentCard = {
    name: "greeter",
    description: "greets people",
    supported_interfaces: [
      @moona2a.AgentInterface::json_rpc(
        "https://agent.test/rpc",
        protocol_version="1.0",
      ),
      {
        url: "https://agent.test/rest",
        protocol_binding: "HTTP+JSON",
        protocol_version: "1.0",
        tenant: Some("blue"),
      },
    ],
    provider: Some({ organization: "acme", url: "https://acme.test", }),
    version: "1.2.3",
    documentation_url: Some("https://docs.test/greeter"),
    capabilities: {
      streaming: true,
      push_notifications: false,
      extended_agent_card: true,
      extensions: [
        {
          uri: "https://example.test/ext/v1",
          description: Some("an extension"),
          required: false,
          params: None,
        },
      ],
    },
    security_schemes: Some(
      @json.parse(
        "{\"apiKey\":{\"apiKeySecurityScheme\":{\"name\":\"X\",\"location\":\"header\"}}}",
      ) catch {
        _ => Json::null()
      },
    ),
    security_requirements: Some(
      @json.parse("[{\"schemes\":{\"apiKey\":{\"list\":[]}}}]") catch {
        _ => Json::null()
      },
    ),
    default_input_modes: ["text/plain"],
    default_output_modes: ["text/plain", "application/json"],
    skills: [@moona2a.AgentSkill::new("greet", "Greet", "say hi", ["social"])],
    signatures: Some(
      @json.parse("[{\"protected\":\"h\",\"signature\":\"s\"}]") catch {
        _ => Json::null()
      },
    ),
    icon_url: Some("https://agent.test/icon.png"),
  }
  let read : @moona2a.AgentCard = @json.from_json(card.to_json()) catch {
    _ => fail("a card does not read back")
  }
  assert_true(read == card)
}

///|
test "card: the wire names are the ones a client expects" {
  let card = @moona2a.AgentCard::new(
    "n",
    "d",
    "1.0.0",
    "https://agent.test/rpc",
    [@moona2a.AgentSkill::new("s", "S", "does s", ["t"])],
  )
  let json = card.to_json()
  let fields = match json {
    Object(fields) => fields
    _ => fail("a card is not an object")
  }
  assert_true(fields.contains("supportedInterfaces"))
  assert_true(fields.contains("capabilities"))
  assert_true(fields.contains("defaultInputModes"))
  assert_true(fields.contains("skills"))
  // An optional field that is unset is absent, not null.
  assert_false(fields.contains("provider"))
  assert_false(fields.contains("iconUrl"))
  let interfaces = match fields.get("supportedInterfaces") {
    Some(Array(interfaces)) => interfaces
    _ => fail("a card has no interfaces")
  }
  let only = match interfaces[0] {
    Object(fields) => fields
    _ => fail("an interface is not an object")
  }
  assert_eq(field_str(only, "protocolBinding"), Some("JSONRPC"))
  assert_eq(field_str(only, "protocolVersion"), Some("1.0"))
}

///|
test "card: the first interface is the one a client should try" {
  let card = @moona2a.AgentCard::new("n", "d", "1", "https://first.test", [])
  match card.preferred() {
    Some(interface) => assert_eq(interface.url, "https://first.test")
    None => fail("a card with an interface has a preferred one")
  }
  let bare : @moona2a.AgentCard = { ..card, supported_interfaces: [], }
  assert_true(bare.preferred() is None)
}

///|
test "card: the input modes are the defaults plus what the skills add" {
  let skill : @moona2a.AgentSkill = {
    ..@moona2a.AgentSkill::new("s", "S", "does s", ["t"]),
    input_modes: ["image/png"],
  }
  let card = @moona2a.AgentCard::new("n", "d", "1", "https://a.test", [skill])
  let modes = card.input_modes()
  assert_eq(modes.length(), 2)
  assert_true(modes.contains("text/plain"))
  assert_true(modes.contains("image/png"))
}

///|
test "card: a card without capabilities does not read" {
  let json = @json.parse(
    "{\"name\":\"n\",\"description\":\"d\",\"version\":\"1\"}",
  ) catch {
    _ => fail("the fixture is not JSON")
  }
  let outcome = try {
    let _ : @moona2a.AgentCard = @json.from_json(json)
    false
  } catch {
    _ => true
  }
  assert_true(outcome)
}

///|
test "push: a registration round-trips with its token and authentication" {
  let config = @moona2a.TaskPushConfig::new(
      "cfg-1", "t-1", "https://hook.test/a",
    )
    .with_token("shared")
    .authenticating(@moona2a.AuthenticationInfo::bearer("secret"))
  let read : @moona2a.TaskPushConfig = @json.from_json(config.to_json()) catch {
    _ => fail("a registration does not read back")
  }
  assert_true(read == config)
  let json = config.to_json()
  let fields = match json {
    Object(fields) => fields
    _ => fail("a registration is not an object")
  }
  // The 1.0 model flattens the configuration into the registration.
  assert_eq(field_str(fields, "taskId"), Some("t-1"))
  assert_eq(field_str(fields, "token"), Some("shared"))
  assert_eq(field_str(fields, "url"), Some("https://hook.test/a"))
  let authentication = match fields.get("authentication") {
    Some(Object(fields)) => fields
    _ => fail("a registration has no authentication")
  }
  assert_eq(field_str(authentication, "scheme"), Some("Bearer"))
  assert_eq(field_str(authentication, "credentials"), Some("secret"))
}

///|
test "push: a registration from the wire keeps the id the caller chose" {
  let json = @json.parse(
    "{\"taskId\":\"t-1\",\"id\":\"mine\",\"url\":\"https://hook.test/a\"}",
  ) catch {
    _ => fail("the fixture is not JSON")
  }
  let read : @moona2a.TaskPushConfig = @json.from_json(json) catch {
    _ => fail("a registration does not read back")
  }
  assert_eq(read.id, "mine")
  assert_eq(read.task_id, "t-1")
  assert_true(read.authentication is None)
}
