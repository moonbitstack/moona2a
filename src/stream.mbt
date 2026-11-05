// The two methods whose answer is a stream: a message the agent works while the caller watches,
// and a task the caller joins after the fact. Push registrations live here too, because a webhook
// is the third way the same events reach a caller.

///|
/// Where a reply goes. A transport turns each one into an SSE frame, a body, or a test's list.
pub(open) trait ReplySink {
  /// Send one JSON-RPC message.
  async fn reply(Self, @moonjrpc.Message) -> Unit
}

///|
/// A sink that wraps each event of a task in the JSON-RPC reply the caller is waiting for.
priv struct Broadcast {
  id : @moonjrpc.Id
  out : &ReplySink
}

///|
impl EventSink for Broadcast with fn emit(self, event) {
  self.out.reply(@moonjrpc.Message::Reply(id=self.id, result=event.to_json()))
}

///|
/// Answer a streaming method: `SendStreamingMessage` works the message, `SubscribeToTask` joins a
/// task that is already running. Either way the caller gets one reply per event, and a refusal
/// with the request's id if the call cannot start.
async fn Server::stream_call(
  self : Server,
  id : @moonjrpc.Id,
  rpc_name : String,
  params : Json,
  out : &ReplySink,
) -> Unit {
  let broadcast : Broadcast = { id, out, }
  let outcome = try {
    match Method::from_name(rpc_name) {
      Some(SendStreamingMessage) => {
        let request : SendMessageRequest = decode(Some(params))
        let prepared = self.prepare(request)
        self.remember_inline_push(prepared.task, prepared.configuration.push)
        self.work(prepared, broadcast) |> ignore
      }
      Some(SubscribeToTask) => self.follow(Some(params), broadcast)
      Some(_) | None => raise UnsupportedOperation(rpc_name).as_failed()
    }
    None
  } catch {
    error => Some(error)
  }
  match outcome {
    Some(error) =>
      out.reply(@moonjrpc.Message::Refusal(id~, failure=failure_of(error))) catch {
        _ => ()
      }
    None => ()
  }
}

///|
/// Answer `SubscribeToTask`: the task as it stands, then everything that happens to it until it
/// finishes or the caller goes away.
async fn Server::follow(
  self : Server,
  params : Json?,
  out : &EventSink,
) -> Unit {
  let fields = params_object(params)
  let task_id = match pick_str(fields, "id", "id") {
    Some(task_id) => task_id
    None => raise InvalidParams("SubscribeToTask needs an id").as_failed()
  }
  let task = match self.state.store.get(task_id) {
    Some(task) => task
    None => raise TaskNotFound(task_id).as_failed()
  }
  if task.status.state.terminal() {
    raise UnsupportedOperation(
      "task \{task_id} has finished and cannot be subscribed to",
    ).as_failed()
  }
  // A subscriber starts from the task as it is now and follows what happens next; what came
  // before is already in the task's history and artifacts.
  let mut cursor = match self.state.logs.get(task_id) {
    Some(log) => log.events.length()
    None => 0
  }
  out.emit(StreamEvent::TaskSnapshot(task))
  let mut following = true
  while following {
    let (events, open) = match self.state.logs.get(task_id) {
      Some(log) => (log.events, log.open)
      None => {
        let none : Array[StreamEvent] = []
        (none, false)
      }
    }
    while cursor < events.length() {
      out.emit(events[cursor])
      cursor = cursor + 1
    }
    if open {
      @async.sleep(follow_tick_millis)
    } else {
      following = false
    }
  }
}

///|
/// Register the push configuration that travelled with a send request, so the task's updates go to
/// the webhook it names.
fn Server::remember_inline_push(
  self : Server,
  task : Task,
  push : TaskPushConfig?,
) -> Unit {
  match push {
    Some(config) => {
      let id = if config.id == "" { self.mint() } else { config.id }
      self.store_push({ ..config, id, task_id: task.id, })
    }
    None => ()
  }
}

///|
/// Keep `config` as one of the task's registrations, replacing any earlier one with the same id.
fn Server::store_push(self : Server, config : TaskPushConfig) -> Unit {
  let kept : Array[TaskPushConfig] = []
  for existing in self.push_configs(config.task_id) {
    if existing.id != config.id {
      kept.push(existing)
    }
  }
  kept.push(config)
  self.state.push[config.task_id] = kept
}

///|
/// Answer `CreateTaskPushNotificationConfig`.
fn Server::on_push_create(
  self : Server,
  params : Json?,
) -> Json raise @moonjrpc.Failed {
  self.push_supported()
  let config : TaskPushConfig = decode(params)
  if config.task_id == "" {
    raise InvalidParams("a push configuration needs a taskId").as_failed()
  }
  if config.url == "" {
    raise InvalidParams("a push configuration needs a url").as_failed()
  }
  match self.state.store.get(config.task_id) {
    Some(_) => ()
    None => raise TaskNotFound(config.task_id).as_failed()
  }
  let id = if config.id == "" { self.mint() } else { config.id }
  let stored = { ..config, id, }
  self.store_push(stored)
  stored.to_json()
}

///|
/// Answer `GetTaskPushNotificationConfig`.
fn Server::on_push_get(
  self : Server,
  params : Json?,
) -> Json raise @moonjrpc.Failed {
  self.push_supported()
  let fields = params_object(params)
  let task_id = match pick_str(fields, "taskId", "task_id") {
    Some(task_id) => task_id
    None => raise InvalidParams("a push lookup needs a taskId").as_failed()
  }
  let id = match pick_str(fields, "id", "id") {
    Some(id) => id
    None => raise InvalidParams("a push lookup needs an id").as_failed()
  }
  for config in self.push_configs(task_id) {
    if config.id == id {
      return config.to_json()
    }
  }
  raise TaskNotFound("\{task_id}/\{id}").as_failed()
}

///|
/// Answer `ListTaskPushNotificationConfigs`.
fn Server::on_push_list(
  self : Server,
  params : Json?,
) -> Json raise @moonjrpc.Failed {
  self.push_supported()
  let fields = params_object(params)
  let task_id = match pick_str(fields, "taskId", "task_id") {
    Some(task_id) => task_id
    None => raise InvalidParams("a push listing needs a taskId").as_failed()
  }
  let encoded : Array[Json] = []
  for config in self.push_configs(task_id) {
    encoded.push(config.to_json())
  }
  Json::object({
    "configs": Json::array(encoded),
    "nextPageToken": Json::string(""),
  })
}

///|
/// Answer `DeleteTaskPushNotificationConfig`. Deleting a registration that is already gone is not
/// an error: the caller asked for a state, and the state holds.
fn Server::on_push_delete(
  self : Server,
  params : Json?,
) -> Json raise @moonjrpc.Failed {
  self.push_supported()
  let fields = params_object(params)
  let task_id = match pick_str(fields, "taskId", "task_id") {
    Some(task_id) => task_id
    None => raise InvalidParams("a push deletion needs a taskId").as_failed()
  }
  let id = match pick_str(fields, "id", "id") {
    Some(id) => id
    None => raise InvalidParams("a push deletion needs an id").as_failed()
  }
  let kept : Array[TaskPushConfig] = []
  for config in self.push_configs(task_id) {
    if config.id != id {
      kept.push(config)
    }
  }
  self.state.push[task_id] = kept
  Json::null()
}

///|
/// Refuse the push methods when the card does not claim them, as section 3.3.4 asks.
fn Server::push_supported(self : Server) -> Unit raise @moonjrpc.Failed {
  if !self.state.card.capabilities.push_notifications {
    raise PushNotificationNotSupported("").as_failed()
  }
}

///|
/// A sink that throws its events away, for a run nobody is watching.
pub struct Discard {}

///|
impl EventSink for Discard with fn emit(self, event) {
  ignore(self)
  ignore(event)
}
