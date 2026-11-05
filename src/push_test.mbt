// A2A push-notification config: the model round-trips, and set/get/list/delete travel the real
// JSON-RPC handler between client and server (reusing the loopback executor/transport).

///|
test "a2a push config: the model round-trips through its wire form" {
  let cfg : @a2a.TaskPushConfig = {
    task_id: "t",
    config: {
      id: Some("c"),
      url: "https://cb",
      token: None,
      authentication: Some({
        schemes: ["Bearer", "ApiKey"],
        credentials: Some("x"),
      }),
    },
  }
  assert_eq(@a2a.TaskPushConfig::from_json(cfg.to_json()), cfg)
}

///|
test "a2a push config e2e: set, get, list, delete over the server" {
  let server = @a2a.A2AServer::new(
    EchoExecutor::{ },
    @a2a.InMemoryTaskStore::new(),
  )
  let client = @a2a.A2AClient::new(LoopbackTransport::{ server, })
  let cfg : @a2a.TaskPushConfig = {
    task_id: "t1",
    config: {
      id: Some("c1"),
      url: "https://cb",
      token: Some("tok"),
      authentication: None,
    },
  }
  assert_eq(client.set_push_config(cfg), cfg)
  assert_eq(client.get_push_config("t1", config_id="c1"), cfg)
  assert_eq(client.list_push_configs("t1"), [cfg])
  client.delete_push_config("t1", "c1")
  assert_eq(client.list_push_configs("t1"), [])
}
