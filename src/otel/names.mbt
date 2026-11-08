// The names this instrumentation adds to the semantic conventions. Everything the
// conventions already name comes from `moonbitstack/moontel/semconv`; what is left is
// the protocol's own vocabulary, which no convention defines yet.

///|
/// `a2a.task.id` — the task a run works, minted by the server that owns it.
pub let a2a_task_id : String = "a2a.task.id"

///|
/// `a2a.task.state` — a state of the task lifecycle, as `TASK_STATE_*`.
pub let a2a_task_state : String = "a2a.task.state"

///|
/// `a2a.method` — the JSON-RPC method a client called, spelled as the wire spells it.
pub let a2a_method : String = "a2a.method"

///|
/// `a2a.artifact.id` — the artifact an update carries.
pub let a2a_artifact_id : String = "a2a.artifact.id"

///|
/// The event a span carries when the task moves: `a2a.task.status`.
pub let a2a_task_status_event : String = "a2a.task.status"

///|
/// The event a span carries when an artifact arrives: `a2a.artifact.produced`.
pub let a2a_artifact_event : String = "a2a.artifact.produced"

///|
/// The operation every agent-invocation span names: `gen_ai.operation.name`'s
/// `invoke_agent`, which the conventions pair with the agent's name to form the span
/// name.
pub let invoke_agent : String = "invoke_agent"

///|
/// The span a client's call gets when it is not a message: `a2a.method` says which
/// method it was. One name for the calls a client makes rather than one per method,
/// because they are the same operation on different nouns — the protocol is one
/// endpoint answering a fixed set of methods.
let call_span : String = "a2a.call"

///|
/// The span a cancellation runs under. Stopping work is not an agent invocation, and
/// no convention names it, so the protocol names it.
let cancel_span : String = "a2a.cancel_task"

///|
/// The span a card is read under.
let discover_span : String = "a2a.discover"
