// The binding table: names, paths, the status of each refusal, and reading a refusal back.

///|
test "binding: every refusal has the gRPC and HTTP status of section 5.4" {
  let table : Array[(@moona2a.Refused, Int32, String, Int32)] = [
    (TaskNotFound(""), 5, "NOT_FOUND", 404),
    (TaskNotCancelable(""), 9, "FAILED_PRECONDITION", 400),
    (PushNotificationNotSupported(""), 9, "FAILED_PRECONDITION", 400),
    (UnsupportedOperation(""), 9, "FAILED_PRECONDITION", 400),
    (ContentTypeNotSupported(""), 3, "INVALID_ARGUMENT", 400),
    (InvalidAgentResponse(""), 13, "INTERNAL", 500),
    (ExtendedAgentCardNotConfigured(""), 9, "FAILED_PRECONDITION", 400),
    (ExtensionSupportRequired(""), 9, "FAILED_PRECONDITION", 400),
    (VersionNotSupported(""), 9, "FAILED_PRECONDITION", 400),
    (InvalidRequest(""), 3, "INVALID_ARGUMENT", 400),
    (InvalidParams(""), 3, "INVALID_ARGUMENT", 400),
  ]
  for row in table {
    let (refused, grpc, name, http) = row
    let status = @moona2a.Status::of(refused.code())
    assert_eq(status, { grpc, name, http, })
    // The reason it travels under names it again.
    assert_eq(
      @moona2a.Refused::of(refused.reason()).map(r => r.code()),
      Some(refused.code()),
    )
  }
  assert_eq(@moona2a.Status::of(-32603).grpc, 13)
  assert_eq(@moona2a.Status::of(-32601).http, 404)
  assert_true(@moona2a.Refused::of("SOMETHING_ELSE") is None)
}

///|
test "binding: a refusal read back from gRPC or HTTP+JSON takes the code its ErrorInfo names" {
  let info = @moona2a.TaskNotCancelable("t-1").failure().data
  guard info is Some(Array(details)) else { fail("no details") }
  let failure = @moona2a.failure_of_status(9, "cannot", details)
  assert_eq(failure.code, -32002)
  assert_eq(failure.message, "cannot")
  // Without an ErrorInfo the status picks the nearest JSON-RPC code.
  assert_eq(@moona2a.failure_of_status(3, "bad", []).code, -32602)
  assert_eq(@moona2a.failure_of_status(12, "no", []).code, -32601)
  assert_eq(@moona2a.failure_of_status(14, "down", []).code, -32603)
  // An ErrorInfo from another domain names nothing here.
  let foreign = Json::object({
    "@type": Json::string("type.googleapis.com/google.rpc.ErrorInfo"),
    "reason": Json::string("TASK_NOT_FOUND"),
    "domain": Json::string("example.com"),
  })
  assert_eq(@moona2a.failure_of_status(5, "x", [foreign]).code, -32601)
}

///|
test "binding: names and paths" {
  for binding in [@moona2a.JsonRpc, Grpc, HttpJson] {
    assert_eq(@moona2a.Binding::of(binding.code()), Some(binding))
  }
  assert_eq(@moona2a.Binding::of("SOAP"), None)
  assert_eq(
    @moona2a.Method::CancelTask.grpc_path(),
    "/lf.a2a.v1.A2AService/CancelTask",
  )
  assert_eq(@moona2a.Method::CancelTask.rest(), ("POST", "/tasks/{id}:cancel"))
  assert_eq(
    @moona2a.Method::DeletePushConfig.rest(),
    ("DELETE", "/tasks/{id}/pushNotificationConfigs/{configId}"),
  )
}

///|
test "binding: a client takes the first interface the card lists among those it speaks" {
  let card = {
    ..@moona2a.AgentCard::new("a", "b", "1.0.0", "http://h/rpc", []),
    supported_interfaces: [
      @moona2a.AgentInterface::grpc("h:9", protocol_version="1.0"),
      @moona2a.AgentInterface::http_json("http://h", protocol_version="1.0"),
      @moona2a.AgentInterface::json_rpc("http://h/rpc", protocol_version="1.0"),
    ],
  }
  assert_eq(card.choose([JsonRpc, HttpJson]).map(i => i.url), Some("http://h"))
  assert_eq(card.choose([Grpc, JsonRpc]).map(i => i.url), Some("h:9"))
  assert_true(card.choose([]) is None)
}
