// The A2A client (Koog `a2a-client` `A2AClient`): the JSON-RPC 2.0 methods a caller uses to talk to
// a remote agent — `message/send` (which resolves to either a `Task` the agent opened or a direct
// `Message` reply), `tasks/get`, and `tasks/cancel`. As with the MCP adapter, the transport is an
// injectable synchronous round-trip: a mock in tests, a real HTTP/JSON-RPC call in production.

///|
/// A synchronous A2A transport: send one JSON-RPC request, get its response (Koog `ClientTransport`).
pub(open) trait A2ATransport {
  fn round_trip(Self, request : Json) -> Json raise
}

///|
/// The outcome of `message/send`: the agent either opened a task or replied with a message directly
/// (A2A's result is a `Task | Message` union, discriminated by `kind`).
pub(all) enum SendResult {
  ResultTask(Task)
  ResultMessage(Message)
} derive(Eq, Debug)

///|
/// A client for a remote agent over `transport`, issuing JSON-RPC 2.0 calls with increasing ids.
pub struct A2AClient {
  transport : &A2ATransport
  mut next_id : Int32
}

///|
/// A client talking to the agent behind `transport`.
pub fn A2AClient::new(transport : &A2ATransport) -> A2AClient {
  { transport, next_id: 1, }
}

///|
/// Issue a JSON-RPC call and return its `result`, raising on a JSON-RPC `error` or a missing result.
fn A2AClient::request(
  self : A2AClient,
  rpc_method : String,
  params : Json,
) -> Json raise {
  let id = self.next_id
  self.next_id = self.next_id + 1
  let request : Json = {
    "jsonrpc": "2.0",
    "id": Json::number(id.to_double()),
    "method": rpc_method,
    "params": params,
  }
  let response = self.transport.round_trip(request)
  guard response is Object(o) else {
    raise A2AError("JSON-RPC response must be a JSON object")
  }
  if o.get("error") is Some(Object(e)) {
    raise A2AError("A2A error: " + str_field(e, "message", "unknown"))
  }
  match o.get("result") {
    Some(r) => r
    None => raise A2AError("JSON-RPC response is missing 'result'")
  }
}

///|
/// Send `message` to the agent (`message/send`), returning the task it opened or its direct reply.
pub fn A2AClient::send_message(
  self : A2AClient,
  message : Message,
) -> SendResult raise {
  let result = self.request("message/send", { "message": message.to_json() })
  guard result is Object(o) else {
    raise A2AError("message/send result must be a JSON object")
  }
  match str_field(o, "kind", "") {
    "task" => ResultTask(Task::from_json(result))
    "message" => ResultMessage(Message::from_json(result))
    other => raise A2AError("unexpected message/send result kind: " + other)
  }
}

///|
/// Fetch the current state of a task (`tasks/get`), optionally bounding the returned history.
pub fn A2AClient::get_task(
  self : A2AClient,
  task_id : String,
  history_length? : Int32,
) -> Task raise {
  let params = new_obj()
  params["id"] = task_id.to_json()
  match history_length {
    Some(n) => params["historyLength"] = Json::number(n.to_double())
    None => ()
  }
  Task::from_json(self.request("tasks/get", Json::object(params)))
}

///|
/// Request cancellation of a task (`tasks/cancel`), returning its updated state.
pub fn A2AClient::cancel_task(self : A2AClient, task_id : String) -> Task raise {
  Task::from_json(self.request("tasks/cancel", { "id": task_id }))
}

///|
pub extend SendResult with Debug::{to_repr}

///|
pub extend SendResult with Eq::{not_equal, equal}
