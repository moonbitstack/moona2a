// The method names are the binding's, and the request objects around them read what a client
// sends, including the proto field names a hand-written client may use.

///|
test "method: every name round-trips, and the streaming ones say so" {
  let all = [
    @moona2a.SendMessage,
    @moona2a.SendStreamingMessage,
    @moona2a.GetTask,
    @moona2a.ListTasks,
    @moona2a.CancelTask,
    @moona2a.SubscribeToTask,
    @moona2a.CreatePushConfig,
    @moona2a.GetPushConfig,
    @moona2a.ListPushConfigs,
    @moona2a.DeletePushConfig,
    @moona2a.GetExtendedCard,
  ]
  for each in all {
    let name = each.name()
    assert_true(@moona2a.Method::from_name(name) == Some(each))
  }
  assert_eq(@moona2a.SendMessage.name(), "SendMessage")
  assert_eq(
    @moona2a.CreatePushConfig.name(),
    "CreateTaskPushNotificationConfig",
  )
  assert_true(@moona2a.SendStreamingMessage.streams())
  assert_true(@moona2a.SubscribeToTask.streams())
  assert_false(@moona2a.SendMessage.streams())
  assert_true(@moona2a.is_streaming_method("SubscribeToTask"))
  assert_false(@moona2a.is_streaming_method("GetTask"))
  assert_true(@moona2a.Method::from_name("nope") is None)
}

///|
test "send request: the configuration reads camelCase, the proto names and the flags" {
  let json = @json.parse(
    "{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"hi\"}]},\"configuration\":{\"returnImmediately\":true,\"historyLength\":3,\"acceptedOutputModes\":[\"text/plain\"]}}",
  ) catch {
    _ => fail("the fixture is not JSON")
  }
  let request : @moona2a.SendMessageRequest = @json.from_json(json) catch {
    _ => fail("a send request does not read")
  }
  assert_eq(request.message.message_id, "m-1")
  match request.configuration {
    Some(configuration) => {
      assert_true(configuration.return_immediately)
      assert_eq(configuration.history_length, Some(3))
      assert_eq(configuration.accepted_output_modes.length(), 1)
    }
    None => fail("the request has no configuration")
  }
}

///|
test "send request: the proto field names are understood as well" {
  let json = @json.parse(
    "{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"hi\"}]},\"configuration\":{\"return_immediately\":false,\"history_length\":\"7\"}}",
  ) catch {
    _ => fail("the fixture is not JSON")
  }
  let request : @moona2a.SendMessageRequest = @json.from_json(json) catch {
    _ => fail("a send request with proto names does not read")
  }
  match request.configuration {
    Some(configuration) => {
      assert_false(configuration.return_immediately)
      // A 64-bit integer travels as a string under ProtoJSON, so a quoted one is read as a number.
      assert_eq(configuration.history_length, Some(7))
    }
    None => fail("the request has no configuration")
  }
}

///|
test "send request: a request without a message does not read" {
  let json = @json.parse("{\"configuration\":{}}") catch {
    _ => fail("the fixture is not JSON")
  }
  let outcome = try {
    let _ : @moona2a.SendMessageRequest = @json.from_json(json)
    false
  } catch {
    _ => true
  }
  assert_true(outcome)
}

///|
test "list query: the filters read, including the proto field names" {
  let json = @json.parse(
    "{\"context_id\":\"c-1\",\"status\":\"TASK_STATE_WORKING\",\"page_size\":5,\"page_token\":\"10\",\"include_artifacts\":true}",
  ) catch {
    _ => fail("the fixture is not JSON")
  }
  let query : @moona2a.ListTasksQuery = @json.from_json(json) catch {
    _ => fail("a list query does not read")
  }
  assert_eq(query.context_id, Some("c-1"))
  assert_eq(query.page_size, Some(5))
  assert_eq(query.page_token, Some("10"))
  assert_true(query.include_artifacts)
  match query.state {
    Some(state) => assert_eq(state.wire(), "TASK_STATE_WORKING")
    None => fail("the query has no state")
  }
}

///|
test "list page: the next page token is always present, empty on the last page" {
  let page : @moona2a.TaskPage = {
    tasks: [],
    next_page_token: "",
    page_size: 50,
    total_size: 0,
  }
  let json = page.to_json()
  let fields = match json {
    Object(fields) => fields
    _ => fail("a page is not an object")
  }
  assert_eq(field_str(fields, "nextPageToken"), Some(""))
  assert_true(fields.contains("totalSize"))
  assert_true(fields.contains("pageSize"))
}

///|
test "send configuration: a push registration rides along in the configuration" {
  let configuration = @moona2a.SendMessageConfig::waiting().pushing(
    @moona2a.TaskPushConfig::new("cfg-1", "", "https://hook.test/a"),
  )
  let json = configuration.to_json()
  let fields = match json {
    Object(fields) => fields
    _ => fail("a configuration is not an object")
  }
  assert_true(fields.contains("taskPushNotificationConfig"))
  let read : @moona2a.SendMessageConfig = @json.from_json(json) catch {
    _ => fail("a configuration does not read back")
  }
  assert_true(read == configuration)
}
