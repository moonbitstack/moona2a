<div align="center">

# moona2a

**The Agent2Agent protocol for MoonBit.**<br>
Agent cards, tasks, streaming and push notifications — one JSON-RPC endpoint, served or called.

<a href="https://moonbitstack.github.io/moona2a/"><kbd> &nbsp;home&nbsp; </kbd></a>
&nbsp;
<a href="https://moonbitstack.github.io/moona2a/guide.html"><kbd> &nbsp;guide&nbsp; </kbd></a>
&nbsp;
<a href="https://moonbitstack.github.io/moona2a/api.html"><kbd> &nbsp;api&nbsp; </kbd></a>
&nbsp;
<a href="https://mooncakes.io/docs/moonbitstack/moona2a"><kbd> &nbsp;MoonCakes&nbsp; </kbd></a>

</div>

---

An agent that other agents can talk to needs three things: a document saying what it is, one
endpoint that answers a fixed set of methods, and a way to report progress on work that takes
longer than a request. `moona2a` is that protocol in MoonBit, in both directions: a server you
plug an agent into, and a client you point at someone else's agent.

Nothing here owns a socket. The server is an ASGI application, so the HTTP server stays a choice
the host makes; the client talks through a transport trait, so a test, HTTP and anything else can
carry the same calls.

## Install

```
moon add moonbitstack/moona2a
```

The module has three packages:

| Package | What it holds |
|:--|:--|
| `moonbitstack/moona2a` | The wire model, the JSON-RPC methods, the task lifecycle, and a client over any transport |
| `moonbitstack/moona2a/asgi` | The HTTP endpoint as an ASGI application: the card, the JSON-RPC path, server-sent events |
| `moonbitstack/moona2a/fetch` | A client transport over HTTP, and the notifier that posts to a caller's webhook |

## A server in ten lines

```moonbit
impl @moona2a.Executor for Echo with fn execute(self, ctx, out) {
  ignore(self)
  out.emit(ctx.status(@moona2a.Working))
  out.emit(ctx.artifact(@moona2a.Artifact::text("a-1", "done")))
  out.emit(ctx.status(@moona2a.Completed))
}
```

An agent says what happens; the server turns that into a task, keeps its history and artifacts,
answers the protocol's methods around it, and hands the same events to every watcher. Cancelling,
listing, push registrations and task lookup are the server's work, not the agent's.

```moonbit
let server = @moona2a.Server::new(Echo::{}, card)
let app = @asgi.to_asgi(server)
```

`to_asgi` answers two addresses: the card at `/.well-known/agent-card.json`, and every method on
the JSON-RPC path. A streaming method answers with `text/event-stream` and one `data:` frame per
event, written as the event happens.

## A client

```moonbit
let message = @moona2a.Message::user("m-1", "summarise this")
match client.send_message(message) {
  @moona2a.TaskSnapshot(task) => println("task \{task.id}: \{task.status.state.wire()}")
  @moona2a.TaskMessage(reply) => println(reply.text())
  _ => ()
}
```

`Client` is the protocol; `Transport` is how the messages travel. `moona2a/fetch` supplies an HTTP
transport, and a test supplies a table.

## The methods

| Method | What it does |
|:--|:--|
| `SendMessage` | Send a message; get back a task or a message |
| `SendStreamingMessage` | The same, with every event as it happens |
| `GetTask` | Read a task, optionally cutting its history short |
| `ListTasks` | A page of the caller's tasks, newest first |
| `CancelTask` | Ask a task to stop |
| `SubscribeToTask` | Join a running task and follow it to its end |
| `CreateTaskPushNotificationConfig` | Leave a webhook for a task's updates |
| `GetTaskPushNotificationConfig` | Read one registration |
| `ListTaskPushNotificationConfigs` | Read a task's registrations |
| `DeleteTaskPushNotificationConfig` | Remove a registration, idempotently |
| `GetExtendedAgentCard` | Read the card shown to authenticated callers |

Errors are the specification's own. A refused call carries one of `TaskNotFound`,
`TaskNotCancelable`, `PushNotificationNotSupported`, `UnsupportedOperation`,
`ContentTypeNotSupported`, `InvalidAgentResponse`, `ExtendedAgentCardNotConfigured`,
`ExtensionSupportRequired` or `VersionNotSupported`, each with the code section 5.4 assigns it and a
`google.rpc.ErrorInfo` detail.

## The server's parts

| Name | What it is |
|:--|:--|
| `Server` | Holds the agent, the store and the card; answers bodies and streams |
| `Executor` | The agent: `execute` emits events, `cancel` stops a task |
| `EventSink` | Where events go — a stream, a webhook, or a test's list |
| `TaskStore` | Where tasks live between requests; `MemoryStore` is the default |
| `Notifier` | Where push notifications go; `moona2a/fetch` has the HTTP one |
| `ReplySink` | Where a client's replies go, one per event |
| `ServerConfig` | History, page sizes, and whether an unknown media type is refused |

A task is created when the agent first says something about it, so an agent that answers with a
message leaves no empty task behind. A run that fails still leaves a task in `TASK_STATE_FAILED`,
which is what a subscriber needs to stop waiting.

## Streaming

A streaming answer is a JSON-RPC reply per event, each wrapping one `StreamResponse`:

```text
data: {"jsonrpc":"2.0","id":1,"result":{"task":{...}}}

data: {"jsonrpc":"2.0","id":1,"result":{"statusUpdate":{"taskId":"t-1",...}}}

data: {"jsonrpc":"2.0","id":1,"result":{"artifactUpdate":{"taskId":"t-1",...}}}
```

The stream opens with the task, carries what changed, and closes at a terminal state. A call that
is refused before it starts — an unknown task, a version the interface does not serve — is an
ordinary JSON-RPC error body instead, because a stream that carries one error is worse than no
stream.

Several callers can watch the same task. Each reads the task's log from its own cursor, so every
stream sees the same events in the same order, and one leaving affects no other.

## Push notifications

A caller leaves a URL, and the agent posts each update there: the same `StreamResponse` a stream
would carry, over plain HTTP, with the credentials the registration names.

```moonbit
let config = @moona2a.TaskPushConfig::new("cfg-1", task_id, "https://caller.example/hook")
  .authenticating(@moona2a.AuthenticationInfo::bearer("secret"))
client.create_push_config(config) |> ignore
```

## Versioning

The interface speaks `1.0`. A request that names another version is refused with
`VersionNotSupported`, and so is one that names none: section 3.6.2 reads a missing header as 0.3,
which this interface does not serve. Patch numbers do not count when versions are compared, so
`1.0.3` reaches a `1.0` interface. A host that builds its own transport can leave the check to
itself by passing no version at all.

## Consistency

The [official conformance suite](https://github.com/a2aproject/a2a-tck) runs against the server in
`src/examples/05-conformance`, at commit `70f6f73`, over the JSON-RPC binding.
`scripts/conformance/check.sh` reproduces the run.

| Run | Result |
|:--|:--|
| `--level must` | 85 passed, 0 failed |
| all levels | 97 passed, 0 failed, 166 skipped |

The skips are the suite's own: the requirements it marks `not-automatable` (card signing, TLS
deployment, client tenant propagation) and the two bindings this library does not declare — it
speaks JSON-RPC, so there is no gRPC or HTTP+JSON endpoint for the suite to drive. The error codes
of section 5.4, the multi-stream ordering, the resubscription cases and webhook delivery are all
covered.

The same server and client were run against the [official Python SDK](https://github.com/a2aproject/a2a-python)
(1.3.0) in both directions — the MoonBit client reading a card and streaming from a Python agent,
and the Python client sending, streaming and reading a task back from the MoonBit server —
with `scripts/interop/check.sh`.

Two behaviours are worth naming:

- **Media types are not refused by default.** Section 3.1.1 asks an agent to answer
  `ContentTypeNotSupported` for a media type it cannot take, but only the agent knows what it can
  take; the card's list is what a caller may *ask* for. `ServerConfig.refuse_unknown_media` turns
  the card's list into a hard filter for agents that want that.
- **The client reads a streamed answer to its end.** The HTTP client this library depends on has no
  incremental body, so `moona2a/fetch` hands the events over once the response finishes. The sink is
  still the seam: a host with a streaming HTTP client delivers into the same trait as frames arrive.

## Examples

| # | Example | What it shows |
|:--:|:--|:--|
| 01 | [`card`](src/examples/01-card/) | A card as JSON: interfaces, capabilities, skills |
| 02 | [`client`](src/examples/02-client/) | A client over a transport that answers from a table |
| 03 | [`server`](src/examples/03-server/) | A server answering a `SendMessage` body |
| 04 | [`stream`](src/examples/04-stream/) | A streaming answer, event by event |
| 05 | [`conformance`](src/examples/05-conformance/) | The server the conformance suite drives, over HTTP |
| 06 | [`interop`](src/examples/06-interop/) | A client calling a live agent: card, message, stream |

## Tests

```
moon test --target all
```

`async test` blocks run on the native, js and wasm backends; the wasm-gc toolchain drops them, so
the synchronous suite — the wire model, the state machine, the agent card, error mapping — is what
runs there.

## Licence

Apache 2.0.
