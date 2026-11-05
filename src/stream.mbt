// A2A streaming (Koog `a2a-core` `TaskStatusUpdateEvent` / `TaskArtifactUpdateEvent` + the client's
// `message/stream`): instead of one reply, the agent streams a sequence of events over SSE as the
// task progresses — status transitions and artifact chunks, ending on a `final` status. The events
// and their wire form are here; the live SSE body is read through an injectable `EventStream` so the
// pure parsing is testable, with a real long-lived HTTP connection supplying it in production.

///|
/// A task's status changed while streaming (A2A `TaskStatusUpdateEvent`); `is_final` ends the stream.
pub(all) struct TaskStatusUpdateEvent {
  task_id : String
  context_id : String
  status : TaskStatus
  is_final : Bool
  metadata : Json?
} derive(Eq, Debug)

///|
/// The agent produced (part of) an artifact while streaming (A2A `TaskArtifactUpdateEvent`).
pub(all) struct TaskArtifactUpdateEvent {
  task_id : String
  context_id : String
  artifact : Artifact
  append : Bool?
  last_chunk : Bool?
  metadata : Json?
} derive(Eq, Debug)

///|
/// One event of a streamed response (A2A streaming `Event` union, discriminated by `kind`).
pub(all) enum StreamEvent {
  StreamTask(Task)
  StreamMessage(Message)
  StreamStatusUpdate(TaskStatusUpdateEvent)
  StreamArtifactUpdate(TaskArtifactUpdateEvent)
} derive(Eq, Debug)

///|
/// Where a streamed response body comes from (the SSE side of Koog's `ClientTransport`): send the
/// request, get back the whole SSE body. Injectable so the parsing is testable without a live socket.
pub(open) trait EventStream {
  fn open_stream(Self, request : Json) -> String raise
}

// ─── wire ────────────────────────────────────────────────────────────────────

///|
pub fn TaskStatusUpdateEvent::to_json(self : TaskStatusUpdateEvent) -> Json {
  let e = new_obj()
  e["kind"] = "status-update".to_json()
  e["taskId"] = self.task_id.to_json()
  e["contextId"] = self.context_id.to_json()
  e["status"] = self.status.to_json()
  e["final"] = self.is_final.to_json()
  put_opt_json(e, "metadata", self.metadata)
  Json::object(e)
}

///|
pub fn TaskStatusUpdateEvent::from_json(
  j : Json,
) -> TaskStatusUpdateEvent raise {
  guard j is Object(o) else {
    raise A2AError("status-update must be an object")
  }
  {
    task_id: str_field(o, "taskId", ""),
    context_id: str_field(o, "contextId", ""),
    status: match o.get("status") {
      Some(s) => TaskStatus::from_json(s)
      None => raise A2AError("status-update is missing status")
    },
    is_final: match opt_bool(o, "final") {
      Some(b) => b
      None => false
    },
    metadata: o.get("metadata"),
  }
}

///|
pub fn TaskArtifactUpdateEvent::to_json(self : TaskArtifactUpdateEvent) -> Json {
  let e = new_obj()
  e["kind"] = "artifact-update".to_json()
  e["taskId"] = self.task_id.to_json()
  e["contextId"] = self.context_id.to_json()
  e["artifact"] = self.artifact.to_json()
  put_opt_bool(e, "append", self.append)
  put_opt_bool(e, "lastChunk", self.last_chunk)
  put_opt_json(e, "metadata", self.metadata)
  Json::object(e)
}

///|
pub fn TaskArtifactUpdateEvent::from_json(
  j : Json,
) -> TaskArtifactUpdateEvent raise {
  guard j is Object(o) else {
    raise A2AError("artifact-update must be an object")
  }
  {
    task_id: str_field(o, "taskId", ""),
    context_id: str_field(o, "contextId", ""),
    artifact: match o.get("artifact") {
      Some(a) => Artifact::from_json(a)
      None => raise A2AError("artifact-update is missing artifact")
    },
    append: opt_bool(o, "append"),
    last_chunk: opt_bool(o, "lastChunk"),
    metadata: o.get("metadata"),
  }
}

///|
/// Parse a streamed event from its JSON, dispatching on `kind`.
pub fn StreamEvent::from_json(j : Json) -> StreamEvent raise {
  guard j is Object(o) else { raise A2AError("stream event must be an object") }
  match str_field(o, "kind", "") {
    "task" => StreamTask(Task::from_json(j))
    "message" => StreamMessage(Message::from_json(j))
    "status-update" => StreamStatusUpdate(TaskStatusUpdateEvent::from_json(j))
    "artifact-update" =>
      StreamArtifactUpdate(TaskArtifactUpdateEvent::from_json(j))
    other => raise A2AError("unknown stream event kind: " + other)
  }
}

// ─── client ──────────────────────────────────────────────────────────────────

///|
/// Send `message` and collect the streamed events (`message/stream`): open the SSE stream, parse
/// each `data:` frame as a JSON-RPC response, and turn each `result` into a `StreamEvent`.
pub fn stream_message(
  source : &EventStream,
  message : Message,
) -> Array[StreamEvent] raise {
  let request : Json = {
    "jsonrpc": "2.0",
    "id": Json::number(1),
    "method": "message/stream",
    "params": { "message": message.to_json() },
  }
  let events : Array[StreamEvent] = []
  for frame in @sse.events(source.open_stream(request)) {
    let response = @json.parse(frame.data)
    guard response is Object(o) else {
      raise A2AError("streamed frame must be a JSON object")
    }
    match o.get("result") {
      Some(result) => events.push(StreamEvent::from_json(result))
      None => raise A2AError("streamed frame is missing 'result'")
    }
  }
  events
}

///|
pub extend StreamEvent with Debug::{to_repr}

///|
pub extend StreamEvent with Eq::{not_equal, equal}

///|
pub extend TaskArtifactUpdateEvent with Debug::{to_repr}

///|
pub extend TaskArtifactUpdateEvent with Eq::{not_equal, equal}

///|
pub extend TaskStatusUpdateEvent with Debug::{to_repr}

///|
pub extend TaskStatusUpdateEvent with Eq::{not_equal, equal}
