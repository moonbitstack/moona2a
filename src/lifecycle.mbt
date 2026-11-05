// What a server does with each method: it resolves or creates the task, runs the agent, folds what
// the agent emits back into the task, and hands the same events to whoever is watching.

///|
/// A request that has been checked against the store and the card, ready to run.
priv struct Prepared {
  task : Task
  /// The task as it stood before this message, when the message continued one.
  previous : Task?
  configuration : SendMessageConfig
}

///|
/// A sink that folds what an agent emits into the task it is working, and passes the same events
/// on. The task is published the first time the agent says something about it, so an agent that
/// only answers with a message never leaves a task behind.
priv struct Folding {
  server : Server
  mut task : Task
  mut published : Bool
  out : &EventSink
}

///|
/// Turn what raised into the failure a caller sees. A refusal keeps its own name and code;
/// anything else is the internal error the specification reserves for a bug, because what an agent
/// trips over is not the caller's to read.
fn failure_of(error : Error) -> @moonjrpc.Failure {
  match error {
    @moonjrpc.Failed(failure) => failure
    TaskNotFound(detail) => TaskNotFound(detail).failure()
    TaskNotCancelable(detail) => TaskNotCancelable(detail).failure()
    PushNotificationNotSupported(detail) =>
      PushNotificationNotSupported(detail).failure()
    UnsupportedOperation(detail) => UnsupportedOperation(detail).failure()
    ContentTypeNotSupported(detail) => ContentTypeNotSupported(detail).failure()
    InvalidAgentResponse(detail) => InvalidAgentResponse(detail).failure()
    ExtendedAgentCardNotConfigured(detail) =>
      ExtendedAgentCardNotConfigured(detail).failure()
    ExtensionSupportRequired(detail) =>
      ExtensionSupportRequired(detail).failure()
    VersionNotSupported(detail) => VersionNotSupported(detail).failure()
    InvalidRequest(detail) => InvalidRequest(detail).failure()
    InvalidParams(detail) => InvalidParams(detail).failure()
    _ =>
      { code: @moonjrpc.internal_error, message: "Internal error", data: None, }
  }
}

///|
impl EventSink for Folding with fn emit(self, event) {
  match event {
    TaskMessage(_) => self.forward(event)
    TaskSnapshot(task) => {
      self.task = task
      self.published = true
      self.server.record(task, event)
      self.forward(event)
    }
    StatusChange(update) => {
      self.announce()
      self.task = { ..self.task, status: update.status, }
      self.server.record(self.task, event)
      self.forward(event)
    }
    ArtifactChunk(update) => {
      self.announce()
      self.task = self.task.taking(update.artifact, update.append)
      self.server.record(self.task, event)
      self.forward(event)
    }
  }
}

///|
/// Hand an event to whoever is watching. A watcher that has gone away is not the task's problem,
/// so a failed delivery leaves the run going.
async fn Folding::forward(self : Folding, event : StreamEvent) -> Unit noraise {
  self.out.emit(event) catch {
    _ => ()
  }
}

///|
/// Make sure the task exists for the watchers before anything about it is said.
async fn Folding::announce(self : Folding) -> Unit noraise {
  if !self.published {
    self.published = true
    let snapshot = StreamEvent::TaskSnapshot(self.task)
    self.server.record(self.task, snapshot)
    self.forward(snapshot)
  }
}

///|
/// Put `task` where the store keeps it and hand `event` to the task's log and its push
/// registrations.
async fn Server::record(
  self : Server,
  task : Task,
  event : StreamEvent,
) -> Unit noraise {
  self.state.store.put(task)
  let log = match self.state.logs.get(task.id) {
    Some(log) => log
    None => {
      let log = TaskLog::new()
      self.state.logs[task.id] = log
      log
    }
  }
  log.events.push(event)
  if event.is_final() {
    log.open = false
  }
  for config in self.push_configs(task.id) {
    self.state.notifier.notify(config, event) catch {
      _ => ()
    }
  }
}

///|
/// The push registrations a task has, empty when it has none.
fn Server::push_configs(
  self : Server,
  task_id : String,
) -> Array[TaskPushConfig] {
  match self.state.push.get(task_id) {
    Some(configs) => configs
    None => []
  }
}

///|
/// Refuse the request when the card requires an extension the caller did not declare.
fn Server::gate(
  self : Server,
  declared : Array[String],
) -> Unit raise @moonjrpc.Failed {
  for extension in self.state.card.capabilities.extensions {
    if extension.required && !declared.contains(extension.uri) {
      raise ExtensionSupportRequired(extension.uri).as_failed()
    }
  }
}

///|
/// The `historyLength` a reply uses: what the caller asked for, else the server's own cap.
fn Server::history(self : Server, asked : Int32?) -> Int32? {
  match asked {
    Some(n) => Some(n)
    None =>
      if self.state.config.history_limit > 0 {
        Some(self.state.config.history_limit)
      } else {
        None
      }
  }
}

///|
/// Check the request against the store and this agent's card, and settle which task it works on.
fn Server::prepare(
  self : Server,
  request : SendMessageRequest,
) -> Prepared raise @moonjrpc.Failed {
  let message = request.message
  if message.parts.length() == 0 {
    raise InvalidParams("a message needs at least one part").as_failed()
  }
  if self.state.config.refuse_unknown_media {
    for part in message.parts {
      match part.media_type() {
        Some(media_type) =>
          if !self.state.card.input_modes().contains(media_type) {
            raise ContentTypeNotSupported(media_type).as_failed()
          }
        None => ()
      }
    }
  }
  let configuration = request.configuration.unwrap_or(
    SendMessageConfig::waiting(),
  )
  match message.task_id {
    Some(task_id) => {
      let previous = match self.state.store.get(task_id) {
        Some(task) => task
        None => raise TaskNotFound(task_id).as_failed()
      }
      if previous.status.state.terminal() {
        raise UnsupportedOperation(
          "task \{task_id} has finished and takes no more messages",
        ).as_failed()
      }
      match message.context_id {
        Some(context_id) =>
          if context_id != previous.context_id {
            raise InvalidParams(
              "contextId \{context_id} does not belong to task \{task_id}",
            ).as_failed()
          }
        None => ()
      }
      // Section 3.4.3: a message that names only the task inherits the task's context.
      let message = message.in_task(task_id, previous.context_id)
      let task = previous.saying(message).with_state(Working)
      { task, previous: Some(previous), configuration, }
    }
    None => {
      let context_id = message.context_id.unwrap_or(self.mint())
      let task_id = self.mint()
      let message = message.in_task(task_id, context_id)
      let task = Task::new(task_id, context_id)
        .saying(message)
        .with_state(Submitted)
      { task, previous: None, configuration, }
    }
  }
}

///|
/// Run the agent on `prepared`, folding its events into the task. The folding sink is returned so
/// the caller can read what the run left behind.
async fn Server::work(
  self : Server,
  prepared : Prepared,
  out : &EventSink,
) -> Folding raise @moonjrpc.Failed {
  let folding = Folding::{
    server: self,
    task: prepared.task,
    published: false,
    out,
  }
  let context : RequestContext = {
    message: prepared.task.history[prepared.task.history.length() - 1],
    task_id: prepared.task.id,
    context_id: prepared.task.context_id,
    task: prepared.previous,
  }
  let outcome = try {
    self.state.executor.execute(context, folding)
    None
  } catch {
    error => Some(error)
  }
  match outcome {
    None => ()
    Some(error) => {
      // A run that blew up still owes the watchers a terminal state: a failed task is the honest
      // record of what happened, and it keeps a subscriber's stream from waiting on a task that
      // will never move again.
      folding.announce()
      let update = TaskStatusUpdate::{
        task_id: folding.task.id,
        context_id: folding.task.context_id,
        status: TaskStatus::recorded(Failed),
        metadata: None,
      }
      folding.task = { ..folding.task, status: update.status, }
      self.record(folding.task, StatusChange(update))
      folding.forward(StatusChange(update))
      raise @moonjrpc.Failed(failure_of(error))
    }
  }
  folding
}

///|
/// Answer `SendMessage`: either the task the agent worked, or the message it answered with.
async fn Server::on_send(
  self : Server,
  params : Json?,
) -> Json raise @moonjrpc.Failed {
  let request : SendMessageRequest = decode(params)
  let prepared = self.prepare(request)
  self.remember_inline_push(prepared.task, prepared.configuration.push)
  if prepared.configuration.return_immediately {
    if self.state.group is Some(group) {
      self.record(prepared.task, StreamEvent::TaskSnapshot(prepared.task))
      let discarded = Discard::{ }
      group.spawn_bg(no_wait=true) <| () => {
        try self.work(prepared, discarded) |> ignore catch {
          _ => ()
        }
      }
      let task = prepared.task
      return Json::object({
        "task": task.encode(view={
          artifacts: true,
          history: self.history(prepared.configuration.history_length),
        }),
      })
    }
  }
  self.answer_send(prepared)
}

///|
/// Run a send to completion and shape the one-body answer.
async fn Server::answer_send(
  self : Server,
  prepared : Prepared,
) -> Json raise @moonjrpc.Failed {
  let collected = Collected::new()
  let folding = self.work(prepared, collected)
  let view : View = {
    artifacts: true,
    history: self.history(prepared.configuration.history_length),
  }
  match collected.message() {
    Some(message) =>
      if !folding.published {
        Json::object({ "message": message.to_json() })
      } else {
        Json::object({ "task": folding.task.encode(view~) })
      }
    None => Json::object({ "task": folding.task.encode(view~) })
  }
}

///|
/// Answer `GetTask`.
fn Server::on_get(self : Server, params : Json?) -> Json raise @moonjrpc.Failed {
  let fields = params_object(params)
  let id = match pick_str(fields, "id", "id") {
    Some(id) =>
      if id == "" {
        raise InvalidParams("GetTask needs an id").as_failed()
      } else {
        id
      }
    None => raise InvalidParams("GetTask needs an id").as_failed()
  }
  let task = match self.state.store.get(id) {
    Some(task) => task
    None => raise TaskNotFound(id).as_failed()
  }
  task.encode(view={
    artifacts: true,
    history: self.history(pick_int(fields, "historyLength", "history_length")),
  })
}

///|
/// Answer `ListTasks`: the caller's tasks, most recently updated first.
fn Server::on_list(
  self : Server,
  params : Json?,
) -> Json raise @moonjrpc.Failed {
  let query : ListTasksQuery = decode(params)
  let matching : Array[Task] = []
  for task in self.state.store.all() {
    if query.context_id is Some(context_id) && task.context_id != context_id {
      continue
    }
    match query.state {
      Some(state) =>
        if state != Unspecified && task.status.state != state {
          continue
        }
      None => ()
    }
    if query.status_timestamp_after is Some(after) {
      match task.status.timestamp {
        Some(stamp) => if stamp < after { continue }
        None => continue
      }
    }
    matching.push(task)
  }
  // Section 3.1.4: newest first.
  let sorted = matching.copy()
  sorted.sort_by(fn(a, b) {
    let left = a.status.timestamp.unwrap_or("")
    let right = b.status.timestamp.unwrap_or("")
    if left == right {
      0
    } else if left > right {
      -1
    } else {
      1
    }
  })
  let total = sorted.length()
  let page_size = match query.page_size {
    Some(size) =>
      if size < 1 {
        1
      } else if size > self.state.config.max_page_size {
        self.state.config.max_page_size
      } else {
        size
      }
    None => self.state.config.page_size
  }
  let start = match query.page_token {
    Some(token) => @string.parse_int(token) catch { _ => 0 }
    None => 0
  }
  let start = if start < 0 { 0 } else if start > total { total } else { start }
  let end = if start + page_size > total { total } else { start + page_size }
  let encoded : Array[Json] = []
  for i in start..<end {
    encoded.push(
      sorted[i].encode(view={
        artifacts: query.include_artifacts,
        history: self.history(query.history_length),
      }),
    )
  }
  Json::object({
    "tasks": Json::array(encoded),
    "nextPageToken": Json::string(
      if end < total {
        end.to_string()
      } else {
        ""
      },
    ),
    "pageSize": Json::number(page_size.to_double(), repr=page_size.to_string()),
    "totalSize": Json::number(total.to_double(), repr=total.to_string()),
  })
}

///|
/// Answer `CancelTask`.
async fn Server::on_cancel(
  self : Server,
  params : Json?,
) -> Json raise @moonjrpc.Failed {
  let fields = params_object(params)
  let id = match pick_str(fields, "id", "id") {
    Some(id) => id
    None => raise InvalidParams("CancelTask needs an id").as_failed()
  }
  let task = match self.state.store.get(id) {
    Some(task) => task
    None => raise TaskNotFound(id).as_failed()
  }
  if task.status.state.terminal() {
    raise TaskNotCancelable(id).as_failed()
  }
  self.state.executor.cancel(id) catch {
    _ => ()
  }
  let stopped = task.with_state(Canceled)
  self.record(
    stopped,
    StatusChange(TaskStatusUpdate::of(task.id, task.context_id, Canceled)),
  )
  Json::object({
    "task": stopped.encode(view={
      artifacts: true,
      history: self.history(pick_int(fields, "historyLength", "history_length")),
    }),
  })
}

///|
/// Answer `GetExtendedAgentCard`.
fn Server::on_extended_card(
  self : Server,
  params : Json?,
) -> Json raise @moonjrpc.Failed {
  ignore(params)
  if !self.state.card.capabilities.extended_agent_card {
    raise UnsupportedOperation("this agent serves no extended card").as_failed()
  }
  match self.state.extended {
    Some(card) => card.to_json()
    None => raise ExtendedAgentCardNotConfigured("").as_failed()
  }
}
