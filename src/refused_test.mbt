// A refusal is one of the errors the specification names, and it reaches a JSON-RPC caller with
// the code section 5.4 maps it to and the `ErrorInfo` detail section 9.5 asks for.

///|
test "refused: every named error has its own code, all inside the A2A range" {
  let cases : Array[(@moona2a.Refused, Int32, String)] = [
    (@moona2a.TaskNotFound(""), -32001, "TASK_NOT_FOUND"),
    (@moona2a.TaskNotCancelable(""), -32002, "TASK_NOT_CANCELABLE"),
    (
      @moona2a.PushNotificationNotSupported(""),
      -32003,
      "PUSH_NOTIFICATION_NOT_SUPPORTED",
    ),
    (@moona2a.UnsupportedOperation(""), -32004, "UNSUPPORTED_OPERATION"),
    (@moona2a.ContentTypeNotSupported(""), -32005, "CONTENT_TYPE_NOT_SUPPORTED"),
    (@moona2a.InvalidAgentResponse(""), -32006, "INVALID_AGENT_RESPONSE"),
    (
      @moona2a.ExtendedAgentCardNotConfigured(""),
      -32007,
      "EXTENDED_AGENT_CARD_NOT_CONFIGURED",
    ),
    (
      @moona2a.ExtensionSupportRequired(""),
      -32008,
      "EXTENSION_SUPPORT_REQUIRED",
    ),
    (@moona2a.VersionNotSupported(""), -32009, "VERSION_NOT_SUPPORTED"),
  ]
  for case in cases {
    let (refusal, code, reason) = case
    assert_eq(refusal.code(), code)
    assert_eq(refusal.reason(), reason)
    assert_true(refusal.code() <= -32001 && refusal.code() >= -32099)
  }
}

///|
test "refused: a request-level problem uses the JSON-RPC codes, not the A2A ones" {
  assert_eq(@moona2a.InvalidRequest("").code(), -32600)
  assert_eq(@moona2a.InvalidParams("").code(), -32602)
}

///|
test "refused: the failure carries the code, a message and an ErrorInfo detail" {
  let failure = @moona2a.TaskNotFound("no such task").failure()
  assert_eq(failure.code, -32001)
  assert_eq(failure.message, "Task not found")
  let data = match failure.data {
    Some(Array(items)) => items
    _ => fail("a refusal has no detail")
  }
  assert_eq(data.length(), 1)
  let info = match data[0] {
    Object(fields) => fields
    _ => fail("a detail is not an object")
  }
  assert_eq(
    field_str(info, "@type"),
    Some("type.googleapis.com/google.rpc.ErrorInfo"),
  )
  assert_eq(field_str(info, "reason"), Some("TASK_NOT_FOUND"))
  assert_eq(field_str(info, "domain"), Some("a2a-protocol.org"))
  let metadata = match info.get("metadata") {
    Some(Object(fields)) => fields
    _ => fail("a detail has no metadata")
  }
  assert_eq(field_str(metadata, "detail"), Some("no such task"))
}

///|
test "refused: a refusal read off the wire names the same error it went out as" {
  for
    refusal in [
      @moona2a.TaskNotFound("x"),
      @moona2a.TaskNotCancelable("x"),
      @moona2a.PushNotificationNotSupported("x"),
      @moona2a.UnsupportedOperation("x"),
      @moona2a.ContentTypeNotSupported("x"),
      @moona2a.InvalidAgentResponse("x"),
      @moona2a.ExtendedAgentCardNotConfigured("x"),
      @moona2a.ExtensionSupportRequired("x"),
      @moona2a.VersionNotSupported("x"),
    ] {
    let back = @moona2a.Refused::from_failure(refusal.failure())
    assert_eq(back.code(), refusal.code())
    assert_eq(back.reason(), refusal.reason())
  }
}

///|
test "refused: a code this library does not know is reported as an invalid agent response" {
  let failure : @moonjrpc.Failure = {
    code: -32099,
    message: "something else",
    data: None,
  }
  let refusal = @moona2a.Refused::from_failure(failure)
  assert_eq(refusal.reason(), "INVALID_AGENT_RESPONSE")
  // The agent's own words are kept, so a caller can read them.
  assert_eq(refusal.detail(), Some("something else"))
}
