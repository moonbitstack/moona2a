// The server side of the protocol: one JSON-RPC body in, one answer out. The transport is a thin
// layer above (see `moona2a/asgi`); everything about tasks, streams and push registrations is here.

///|
/// What an executor is given when it is asked to work a request: the message, the ids it belongs
/// to, and the task as it stands when the message continues one.
pub(all) struct RequestContext {
  message : Message
  task_id : String
  context_id : String
  task : Task?
}

///|
/// The event that moves this request's task to `state`.
pub fn RequestContext::status(
  self : RequestContext,
  state : TaskState,
) -> StreamEvent {
  StreamEvent::StatusChange(
    TaskStatusUpdate::of(self.task_id, self.context_id, state),
  )
}

///|
/// The event that hands this request's caller `artifact`, or more of one.
pub fn RequestContext::artifact(
  self : RequestContext,
  artifact : Artifact,
  append? : Bool,
  last_chunk? : Bool,
) -> StreamEvent {
  StreamEvent::ArtifactChunk(
    TaskArtifactUpdate::of(
      self.task_id,
      self.context_id,
      artifact,
      append=append.unwrap_or(false),
      last_chunk=last_chunk.unwrap_or(true),
    ),
  )
}

///|
/// A message this request's caller receives outside the task. An executor that says only this
/// answers with a message instead of opening a task.
pub fn RequestContext::replying(
  self : RequestContext,
  parts : Array[Part],
) -> StreamEvent {
  let message : Message = {
    message_id: self.task_id,
    role: Agent,
    parts,
    context_id: Some(self.context_id),
    task_id: Some(self.task_id),
    reference_task_ids: None,
    extensions: None,
    metadata: None,
  }
  StreamEvent::TaskMessage(message)
}

///|
/// The agent behind a server. An implementation works a request by emitting events — status
/// changes, artifacts, or a message that answers without a task — and stops a task when asked.
pub(open) trait Executor {
  /// Work `ctx`, sending what happens to `out`. Emitting nothing and returning leaves the task in
  /// the state it was given.
  async fn execute(Self, RequestContext, &EventSink) -> Unit
  /// Stop the task with `task_id`. The server records the cancellation itself.
  async fn cancel(Self, String) -> Unit
}

///|
/// Where a server sends push notifications.
pub(open) trait Notifier {
  /// Post `event` to `config`'s webhook, authenticating as the configuration says.
  async fn notify(Self, TaskPushConfig, StreamEvent) -> Unit
}

///|
/// An executor built from two functions, for the common case of one agent with no state of its own.
pub struct CallableExecutor {
  run : async (RequestContext, &EventSink) -> Unit
  stop : async (String) -> Unit
}

///|
/// An executor that works requests with `run` and stops tasks with `stop`.
pub fn CallableExecutor::new(
  run~ : async (RequestContext, &EventSink) -> Unit,
  stop~ : async (String) -> Unit,
) -> CallableExecutor {
  { run, stop, }
}

///|
pub impl Executor for CallableExecutor with fn execute(self, ctx, out) {
  (self.run)(ctx, out)
}

///|
pub impl Executor for CallableExecutor with fn cancel(self, task_id) {
  (self.stop)(task_id)
}

///|
/// The protocol version this library speaks, as a client writes it in `A2A-Version`.
pub let protocol_version : String = "1.0"

///|
/// The defaults a server runs with.
pub(all) struct ServerConfig {
  /// How many messages a reply brings back when the caller asks for no particular number. 0 means
  /// the whole history, which is what the specification leaves to the implementation.
  history_limit : Int32
  /// How many tasks a page of `ListTasks` holds when the caller asks for no particular number.
  page_size : Int32
  /// The largest page a caller may ask for; section 3.1.4 caps it at 100.
  max_page_size : Int32
  /// Whether a part naming a media type the card does not offer is refused with
  /// `ContentTypeNotSupported`. Off by default: the card lists what a caller may *ask* for, and
  /// only the agent knows what it can actually do with an unfamiliar type. An agent that wants the
  /// card's list enforced turns this on.
  refuse_unknown_media : Bool
}

///|
/// A server that brings back the whole history, 50 tasks to a page, and no more than 100.
pub fn ServerConfig::new() -> ServerConfig {
  {
    history_limit: 0,
    page_size: 50,
    max_page_size: 100,
    refuse_unknown_media: false,
  }
}

///|
/// Where a server's tasks live: a store it owns, or one the host keeps and it borrows.
priv enum Store {
  Owned(MemoryStore)
  Borrowed(&TaskStore)
}

///|
fn Store::get(self : Store, id : String) -> Task? {
  match self {
    Owned(store) => store.get(id)
    Borrowed(store) => store.get(id)
  }
}

///|
fn Store::put(self : Store, task : Task) -> Unit {
  match self {
    Owned(store) => store.put(task)
    Borrowed(store) => store.put(task)
  }
}

///|
fn Store::all(self : Store) -> Array[Task] {
  match self {
    Owned(store) => store.all()
    Borrowed(store) => store.all()
  }
}

///|
/// Where a server's push notifications go: nowhere, or a notifier the host keeps.
priv enum Notice {
  Nowhere
  Given(&Notifier)
}

///|
async fn Notice::notify(
  self : Notice,
  config : TaskPushConfig,
  event : StreamEvent,
) -> Unit {
  match self {
    Nowhere => ()
    Given(notifier) => notifier.notify(config, event)
  }
}

///|
/// Everything a server mutates. Held behind the `Server` handle so a handler that captured the
/// handle sees the same maps as the one that made it.
struct ServerState {
  store : Store
  executor : &Executor
  notifier : Notice
  card : AgentCard
  config : ServerConfig
  push : Map[String, Array[TaskPushConfig]]
  logs : Map[String, TaskLog]
  /// Task and message ids are the server's to mint; a counter keeps them unique in a process and
  /// the clock in front of it keeps them apart across restarts.
  minted : Array[Int64]
  /// Where a run goes when the caller asked not to wait. Set by the host with `attach`.
  mut group : @async.TaskGroup[Unit]?
  /// The card a caller sees after authenticating, when the agent has one.
  mut extended : AgentCard?
}

///|
/// An A2A endpoint: it holds the agent, the store and the card, and answers the protocol's
/// methods.
pub struct Server {
  state : ServerState
}

///|
/// A server for `executor` and `card`, keeping tasks in its own memory and sending no
/// notifications.
pub fn Server::new(executor : &Executor, card : AgentCard) -> Server {
  {
    state: {
      store: Owned(MemoryStore::new()),
      executor,
      notifier: Nowhere,
      card,
      config: ServerConfig::new(),
      push: Map([]),
      logs: Map([]),
      minted: [0L],
      group: None,
      extended: None,
    },
  }
}

///|
/// A server over the given store, notifier and configuration.
pub fn Server::configured(
  executor~ : &Executor,
  card~ : AgentCard,
  store~ : &TaskStore,
  notifier~ : &Notifier,
  config~ : ServerConfig,
) -> Server {
  {
    state: {
      store: Borrowed(store),
      executor,
      notifier: Given(notifier),
      card,
      config,
      push: Map([]),
      logs: Map([]),
      minted: [0L],
      group: None,
      extended: None,
    },
  }
}

///|
/// The same server, keeping its tasks in `store` and sending notifications through `notifier`.
pub fn Server::storing(self : Server, store : &TaskStore) -> Server {
  { state: { ..self.state, store: Borrowed(store), }, }
}

///|
/// The same server, sending its push notifications through `notifier`.
pub fn Server::notifying(self : Server, notifier : &Notifier) -> Server {
  { state: { ..self.state, notifier: Given(notifier), }, }
}

///|
/// The same server under `config`.
pub fn Server::under(self : Server, config : ServerConfig) -> Server {
  { state: { ..self.state, config, }, }
}

///|
/// Let the server start runs in `group` when a caller asks not to wait. A run started this way
/// outlives the request that asked for it, and stops when the group does.
pub fn Server::attach(self : Server, group : @async.TaskGroup[Unit]) -> Server {
  self.state.group = Some(group)
  self
}

///|
/// The same server, handing an authenticated caller `card` instead of the public one.
pub fn Server::with_extended_card(self : Server, card : AgentCard) -> Server {
  self.state.extended = Some(card)
  self
}

///|
/// The card this server publishes.
pub fn Server::card(self : Server) -> AgentCard {
  self.state.card
}

///|
/// The public card as the well-known document serves it.
pub fn Server::card_json(self : Server) -> Json {
  self.state.card.to_json()
}

///|
/// A fresh identifier, unique within this server and unlikely to collide with another's.
fn Server::mint(self : Server) -> String {
  self.state.minted[0] = self.state.minted[0] + 1L
  let stamp = @env.now().reinterpret_as_int64()
  "a2a-\{stamp}-\{self.state.minted[0]}"
}

///|
/// Answer one body of JSON-RPC, as a body. The answer is `None` when the body was a notification
/// and nothing goes back.
///
/// `extensions` are the extension URIs the caller declared for this request — the values of the
/// `A2A-Extensions` header, in the JSON-RPC binding. An extension the card requires that is not
/// among them is refused.
pub async fn Server::answer(
  self : Server,
  body : StringView,
  extensions? : Array[String],
  version? : String,
) -> String? {
  let table = self.table(extensions.unwrap_or([]), version)
  table.body(body)
}

///|
/// Answer one body of JSON-RPC, handing every reply to `out` as it is ready. A streaming method
/// produces one reply per event; everything else produces exactly one.
pub async fn Server::answer_stream(
  self : Server,
  body : StringView,
  out : &ReplySink,
  extensions? : Array[String],
  version? : String,
) -> Unit {
  let request = @json.parse(body) catch {
    _ => {
      out.reply(@moonjrpc.Message::unreadable()) catch {
        _ => ()
      }
      return
    }
  }
  let message : @moonjrpc.Message = @json.from_json(request) catch {
    _ => {
      out.reply(@moonjrpc.Message::invalid(request)) catch {
        _ => ()
      }
      return
    }
  }
  match message {
    Call(id~, name~, params~) =>
      if is_streaming_method(name) {
        let declared = extensions.unwrap_or([])
        let refuse = try {
          self.enter(declared, version)
          None
        } catch {
          error => Some(error)
        }
        match refuse {
          Some(error) =>
            out.reply(
              @moonjrpc.Message::Refusal(id~, failure=failure_of(error)),
            ) catch {
              _ => ()
            }
          None =>
            self.stream_call(id, name, params.unwrap_or(Json::null()), out)
        }
      } else {
        let answer = self
          .table(extensions.unwrap_or([]), version)
          .answer(message)
        match answer {
          Some(reply) => out.reply(reply) catch { _ => () }
          None => ()
        }
      }
    Notice(..) | Reply(_) | Refusal(_) => ()
  }
}

///|
/// The method this request asks for, so a transport can decide whether its answer is a stream
/// before reading the whole body.
pub fn request_method(body : StringView) -> String? {
  let request = @json.parse(body) catch { _ => return None }
  match request {
    Object(fields) =>
      match fields.get("method") {
        Some(String(name)) => Some(name)
        _ => None
      }
    _ => None
  }
}

///|
/// The table of methods the non-streaming side answers. A table per call keeps the handlers'
/// capture of the server short-lived; it is a dozen map inserts, which is cheaper than the
/// bookkeeping a shared table would need.
fn Server::table(
  self : Server,
  extensions : Array[String],
  version : String?,
) -> @moonjrpc.Methods {
  let methods = @moonjrpc.Methods::new()
  methods.call(Method::SendMessage.name(), async fn(params) {
    self.enter(extensions, version)
    self.on_send(params)
  })
  methods.call(Method::CancelTask.name(), async fn(params) {
    self.enter(extensions, version)
    self.on_cancel(params)
  })
  methods.call(Method::GetTask.name(), params => {
    self.enter(extensions, version)
    self.on_get(params)
  })
  methods.call(Method::ListTasks.name(), params => {
    self.enter(extensions, version)
    self.on_list(params)
  })
  methods.call(Method::CreatePushConfig.name(), params => {
    self.enter(extensions, version)
    self.on_push_create(params)
  })
  methods.call(Method::GetPushConfig.name(), params => {
    self.enter(extensions, version)
    self.on_push_get(params)
  })
  methods.call(Method::ListPushConfigs.name(), params => {
    self.enter(extensions, version)
    self.on_push_list(params)
  })
  methods.call(Method::DeletePushConfig.name(), params => {
    self.enter(extensions, version)
    self.on_push_delete(params)
  })
  methods.call(Method::GetExtendedCard.name(), params => {
    self.enter(extensions, version)
    self.on_extended_card(params)
  })
  methods
}

///|
/// The check every method makes before doing anything else: the version this interface serves, and
/// the extensions the card requires. Raised as the JSON-RPC failure the caller sees.
fn Server::enter(
  self : Server,
  extensions : Array[String],
  version : String?,
) -> Unit raise @moonjrpc.Failed {
  self.accept_version(version)
  self.gate(extensions)
}

///|
/// Serve the version the caller asked for, or refuse. Section 3.6.2: an empty value means 0.3, and
/// patch numbers do not count when versions are compared.
///
/// A caller that says nothing at all is not a 0.3 client but a host that has not modelled the
/// header; the check is theirs to ask for, and a transport over HTTP always passes the value it
/// read, empty or not.
fn Server::accept_version(
  self : Server,
  version : String?,
) -> Unit raise @moonjrpc.Failed {
  ignore(self)
  let asked = match version {
    None => return
    Some(text) => if text == "" { "0.3" } else { text }
  }
  if major_minor(asked) != protocol_version {
    raise VersionNotSupported(asked).as_failed()
  }
}

///|
/// The `Major.Minor` part of a version string, which is all that negotiation looks at.
fn major_minor(version : String) -> String {
  guard version.find(".") is Some(first) else { return version }
  let rest = version.exact_view(start=first + 1, end=version.length())
  guard rest.find(".") is Some(second) else { return version }
  version.exact_view(start=0, end=first + 1 + second).to_owned()
}

///|
pub extend CallableExecutor with Executor::{execute, cancel}
