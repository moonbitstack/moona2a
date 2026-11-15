<div align="center">

# moona2a

**The Agent2Agent protocol for MoonBit.**<br>
Agent cards, tasks, streaming and push notifications — over JSON-RPC, HTTP+JSON and gRPC, served or called.

<a href="https://moonbitstack.github.io/moona2a/"><kbd> &nbsp;home&nbsp; </kbd></a>
&nbsp;
<a href="https://moonbitstack.github.io/moona2a/guide.html"><kbd> &nbsp;guide&nbsp; </kbd></a>
&nbsp;
<a href="https://moonbitstack.github.io/moona2a/api.html"><kbd> &nbsp;api&nbsp; </kbd></a>
&nbsp;
<a href="https://mooncakes.io/docs/moonbitstack/moona2a"><kbd> &nbsp;MoonCakes&nbsp; </kbd></a>

</div>

---

An agent that other agents can talk to needs three things: a document saying what it is, an
endpoint that answers a fixed set of methods, and a way to report progress on work that takes
longer than a request. `moona2a` is that protocol in MoonBit, in both directions: a server you
plug an agent into, and a client you point at someone else's agent. All three bindings the
specification defines are here, on one server and one client.

Nothing in the server owns a socket. JSON-RPC and HTTP+JSON are one ASGI application, so the HTTP
server stays a choice the host makes; gRPC is a set of handlers registered on a moonrpc server.
The client talks through a transport trait, so a test, HTTP, gRPC and anything else carry the same
calls.

## Install

```
moon add moonbitstack/moona2a
```

The module has six packages:

| Package | What it holds |
|:--|:--|
| `moonbitstack/moona2a` | The wire model, the methods, the task lifecycle, the binding table, and a client over any transport |
| `moonbitstack/moona2a/asgi` | JSON-RPC and HTTP+JSON as one ASGI application: the card, both bindings' paths, server-sent events |
| `moonbitstack/moona2a/grpc` | `A2AService` registered on any moonrpc server, and the message codec read from the specification's `a2a.proto` |
| `moonbitstack/moona2a/grpc/channel` | A client transport over a moonrpc channel; native only |
| `moonbitstack/moona2a/fetch` | Client transports for JSON-RPC and HTTP+JSON, and the notifier that posts to a caller's webhook |
| `moonbitstack/moona2a/otel` | Spans for an agent run and for a client's call, in the OpenTelemetry GenAI conventions |

## A server in ten lines

```moonbit
struct Echo {}

impl @moona2a.Executor for Echo with fn execute(self, ctx, out) {
  ignore(self)
  out.emit(ctx.status(@moona2a.Working))
  out.emit(ctx.artifact(@moona2a.Artifact::text("a-1", "done")))
  out.emit(ctx.status(@moona2a.Completed))
}

impl @moona2a.Executor for Echo with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

pub extend Echo with @moona2a.Executor::{execute, cancel}
```

An agent says what happens; the server turns that into a task, keeps its history and artifacts,
answers the protocol's methods around it, and hands the same events to every watcher. Cancelling,
listing, push registrations and task lookup are the server's work, not the agent's.

```moonbit
let card = @moona2a.AgentCard::new(
  "echo",
  "repeats what it is told",
  "1.0.0",
  "https://echo.example.com",
  [@moona2a.AgentSkill::new("echo", "Echo", "repeats a message", ["echo"])],
)
let server = @moona2a.Server::new(Echo::{ }, card)
let app = @asgi.to_asgi(server)
assert_eq(server.card().name, "echo")
```

`to_asgi` answers the card at `/.well-known/agent-card.json`, every method on the JSON-RPC path,
and every method at its own HTTP+JSON path. A streaming method answers with `text/event-stream`
and one `data:` frame per event, written as the event happens.

## A client

`Client` is the protocol; `Transport` is how the messages travel. `moona2a/fetch` supplies an HTTP
transport — it needs sockets, so it is there on the native and wasm backends and not on the
JavaScript one — and a test supplies a table.

```moonbit native
let transport = @fetch.HttpTransport::new("https://summariser.example.com")
let client = @moona2a.Client::new(transport)
```

```moonbit native
let message = @moona2a.Message::user("m-1", "summarise this")
match client.send_message(message) {
  @moona2a.TaskSnapshot(task) => println("task \{task.id}: \{task.status.state.wire()}")
  @moona2a.TaskMessage(reply) => println(reply.text())
  _ => ()
}
```

### Headers on a call

Every client method takes `headers?`: the headers of that one call, in wire spelling. The transport
sends them alongside what it always sends, and a name both supply keeps the call's value. The
`Transport` trait carries them as `exchange_with`, `stream_with` and `discover_with`, each with a
default that reaches the original three methods — a transport written before per-call headers
existed needs no change.

```moonbit native
let task = client.get_task("t-1", headers=[("x-tenant", "acme")])
println("task \{task.id}: \{task.status.state.wire()}")
```

A host can also give `HttpTransport` a `headers` callback for headers it wants on every request;
those sit behind the ones a call names. A trace context, a tenant that changes with the caller, or
a short-lived credential belongs to the call, not to the handle that sends it.

## Three bindings

A server answers all three with the same tasks: the JSON-RPC and HTTP+JSON bindings come from
`to_asgi`, and gRPC from `@grpc.register` on a moonrpc server. gRPC is HTTP/2 and runs on its own
listener.

```moonbit native
async fn serve_grpc(server : @moona2a.Server) -> Unit {
  let grpc = @net.GrpcServer::new()
  @grpc.register(grpc, server)
  grpc.serve(port=12001)
}
```

The card lists every interface, in the order a client should try them, and a client takes the
first it can speak:

```moonbit
let base = {
  ..@moona2a.AgentCard::new("echo", "repeats", "1.0.0", "https://echo.example.com", []),
  supported_interfaces: [
    @moona2a.AgentInterface::grpc("echo.example.com:12001", protocol_version="1.0"),
    @moona2a.AgentInterface::http_json("https://echo.example.com", protocol_version="1.0"),
    @moona2a.AgentInterface::json_rpc("https://echo.example.com", protocol_version="1.0"),
  ],
}
let chosen = base.choose([HttpJson, JsonRpc])
assert_eq(chosen.map(i => i.protocol_binding), Some("HTTP+JSON"))
```

| Binding | Server | Client transport |
|:--|:--|:--|
| JSON-RPC | `@asgi.to_asgi`, one path | `@fetch.HttpTransport` |
| HTTP+JSON | `@asgi.to_asgi`, `/message:send` and the rest, also under `/{tenant}` | `@fetch.RestTransport` |
| gRPC | `@grpc.register` on `@net.GrpcServer` | `@channel.GrpcTransport` |

`Server::invoke` and `Server::invoke_stream` are what the three share: a method, its parameters as
the JSON form of the request message, and the answer in the JSON form of the reply. A binding of
your own is a path or a handler that reads a call into those and writes the answer back.

A refusal reads as each binding writes it, with the same `google.rpc.ErrorInfo` in all three:

| Error | JSON-RPC | gRPC | HTTP |
|:--|:--:|:--:|:--:|
| `TaskNotFound` | `-32001` | `NOT_FOUND` | 404 |
| `TaskNotCancelable`, `PushNotificationNotSupported`, `UnsupportedOperation` | `-32002` to `-32004` | `FAILED_PRECONDITION` | 400 |
| `ContentTypeNotSupported` | `-32005` | `INVALID_ARGUMENT` | 400 |
| `InvalidAgentResponse` | `-32006` | `INTERNAL` | 500 |
| `ExtendedAgentCardNotConfigured`, `ExtensionSupportRequired`, `VersionNotSupported` | `-32007` to `-32009` | `FAILED_PRECONDITION` | 400 |
| invalid request or parameters | `-32600`, `-32602` | `INVALID_ARGUMENT` | 400 |

`Status::of` gives the gRPC and HTTP status of a JSON-RPC code, and `failure_of_status` reads a
gRPC or HTTP+JSON refusal back into the error its `ErrorInfo` names. A client sees `TaskNotFound`
whichever binding carried it.

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

## Bodies

A body is read as JSON and nothing else: a comment, a trailing comma, a single-quoted name or a
number in hex is refused with `-32700` rather than repaired. A number a caller writes keeps its
digits when an answer carries it back, so an integer past what a double holds survives the round
trip. Text goes out as UTF-8, not as `\u` escapes.

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

```moonbit native
let config = @moona2a.TaskPushConfig::new("cfg-1", "a2a-1", "https://caller.example/hook")
  .authenticating(@moona2a.AuthenticationInfo::bearer("secret"))
client.create_push_config(config) |> ignore
```

## Instrumentation

A run and a call are traced as the OpenTelemetry GenAI conventions describe them: `invoke_agent`
and the agent's name, with `gen_ai.operation.name`, `gen_ai.agent.*` and the conversation on it.
The protocol's own facts ride alongside as `a2a.task.id`, `a2a.task.state` and `a2a.method`; every
status change and artifact is an event inside the span.

```moonbit
fn traced_server(rand : (Int32) -> Bytes, now : () -> Int64, agent_card : @moona2a.AgentCard) -> @moona2a.Server {
  let tracing = @otel.Tracing::new(
    tracer=@trace.Tracer::new(rand~, sink=@trace.discard, sampler=@trace.always),
    now~,
    agent=@otel.Agent::of_card(agent_card),
  )
  @moona2a.Server::new(tracing.executing(Echo::{ }), agent_card)
}
```

The tracer is the one you already run, so spans land wherever the rest of the process' spans land;
`moonbitstack/moontel` has the exporter. Message text is left out unless `recording_content()` is
asked for, and `at_most(n)` cuts what is recorded.

`tracing.calling(transport)` is the same for the other side: a client's call is a span of kind
`Client`, streaming answers put every event on it, and a refusal is an error span.

### One trace, both agents

A call carries its own context across the wire, so the run on the other side is a child of the span
that called it rather than the root of a second trace. The protocol has no header of its own for
this, so the pieces are generic: `tracing.calling(transport)` adds `traceparent` to that call's
headers, the transport puts them on the request, `to_asgi` hands the request's headers to
`Server::answer`, they reach the agent as `RequestContext.headers`, and the run takes the caller's
context as its parent. A header that does not parse is no header: the run starts its own trace.

```moonbit native
fn calling_agent(rand : (Int32) -> Bytes, now : () -> Int64, agent_card : @moona2a.AgentCard) -> @moona2a.Client raise {
  let tracing = @otel.Tracing::new(
    tracer=@trace.Tracer::new(rand~, sink=@trace.discard, sampler=@trace.always),
    now~,
    agent=@otel.Agent::of_card(agent_card),
  )
  @moona2a.Client::new(
    tracing.calling(@fetch.HttpTransport::new("https://summariser.example.com")),
  )
}
```

Headers are an argument of the call, not a slot on the transport, so one traced transport serves
many tasks at once: each request carries the context of the span that opened it, and no task's trace
can land on another's request. `Injector` remains as an optional observer of a single call; it is
not on the path to the wire. The `a2a-version` header the transport always sends is still there,
and a call's headers take precedence when a name is used twice.

## Versioning

The interface speaks `1.0`. A request that names another version is refused with
`VersionNotSupported`, and so is one that names none: section 3.6.2 reads a missing header as 0.3,
which this interface does not serve. Patch numbers do not count when versions are compared, so
`1.0.3` reaches a `1.0` interface. A host that builds its own transport can leave the check to
itself by passing no version at all.

## Consistency

The [official conformance suite](https://github.com/a2aproject/a2a-tck) runs against the server in
`src/examples/05-conformance`, at commit `70f6f73`, over all three bindings: JSON-RPC and HTTP+JSON
on one port, gRPC on the next. `scripts/conformance/check.sh` reproduces the run, and CI fails on
any failure `scripts/conformance/expected.txt` does not explain, or on an explained one that stops
happening.

| Level | Passed | Failed | Skipped | Manual | Not tested |
|:--|:--:|:--:|:--:|:--:|:--:|
| MUST | 85 | 2 | 5 | 7 | 16 |
| SHOULD | 9 | 0 | 1 | 2 | 2 |
| MAY | 3 | 0 | 1 | 0 | 0 |

| Binding | Checks passed |
|:--|:--:|
| agent card | 9 of 11, 2 skipped |
| gRPC | 67 of 72, 4 skipped |
| JSON-RPC | 91 of 99, 7 skipped |
| HTTP+JSON | 87 of 95, 6 skipped |

The two failures are places where the suite contradicts itself, and the server follows the
specification:

- **HTTP_JSON-ERR-001** wants `application/json` on an error body. Section 11.1 and the error
  example of section 11.6 write `application/a2a+json`, and the suite's own HTTP_JSON-SVC-001 checks
  for that type on the same response, which passes.
- **CORE-SEND-003**, once per binding, asks for `ContentTypeNotSupported` but names no expected
  error, so the refusal section 3.1.1 requires is counted as a failed call. HTTP_JSON-STATUS-001
  asserts that refusal for the same probe, which passes.

The skips are the suite's own: card signing, TLS deployment and client tenant propagation are
marked manual or not automatable.

The same server and client run against the [official Python SDK](https://github.com/a2aproject/a2a-python)
1.3.0 in both directions over each binding, with `scripts/interop/check.sh`: the MoonBit client
sends, streams, reads a task back and meets two refusals from a Python agent, and the Python client
does the same against the MoonBit server, asserting `TaskNotFoundError` and
`TaskNotCancelableError` where the specification names them. Six runs, all in CI.

The error mapping of the two newer bindings and the order of streamed events are checked by
breaking them: `scripts/check_mutations.py` changes one line at a time, seven in all, and each has
to turn the test named for it red. It runs in CI.

The spans of the `otel` package are checked against the semantic conventions they claim to follow.
[Weaver](https://github.com/open-telemetry/weaver) 0.28.0 runs `registry live-check` over the spans
the example in `src/examples/07-otel` emits, against the registry in `scripts/otel/registry`, with
`scripts/otel/check.sh`. The job fails on any `violation` — an attribute the conventions do not
define, one of the wrong type, a required one that is missing — and on an example that stops
producing the spans it is supposed to.

| Run | Result |
|:--|:--|
| registry check | valid, no policy violation |
| live check | 7 spans, 73 entities, 0 advisories, 73% of the registry exercised |
| the trace | one trace per send: the run's span names the caller's span as its parent |

The two `opt_in` attributes, the message text, are declared and not exercised by default, which is
where the missing quarter of the registry is. Span events are declared in the registry, but the
0.28 live check pairs them by their enclosing span rather than by name, so a mistyped event name is
not caught there; the package's own tests assert the names it emits.

The per-call header path is checked two ways: over a real socket, where a server reads back the
headers a call sent, and with two tasks sharing one traced transport at once. The second holds both
calls at the same point in the transport before either reads its headers, so a context shared
between calls cannot hide: each request is asserted to carry the `traceparent` of its own span.

Two behaviours are worth naming:

- **Media types are not refused by default.** Section 3.1.1 asks an agent to answer
  `ContentTypeNotSupported` for a media type it cannot take, but only the agent knows what it can
  take; the card's list is what a caller may *ask* for. `ServerConfig.refuse_unknown_media` turns
  the card's list into a hard filter for agents that want that.
- **Subscribing is `POST` and `GET`.** The specification's table writes `POST /tasks/{id}:subscribe`
  and `a2a.proto` annotates a `GET`; the server answers both, as the Python SDK does, and the
  client sends the `POST`.

## Examples

| # | Example | What it shows |
|:--:|:--|:--|
| 01 | [`card`](src/examples/01-card/) | A card as JSON: interfaces, capabilities, skills |
| 02 | [`client`](src/examples/02-client/) | A client over a transport that answers from a table |
| 03 | [`server`](src/examples/03-server/) | A server answering a `SendMessage` body |
| 04 | [`stream`](src/examples/04-stream/) | A streaming answer, event by event |
| 05 | [`conformance`](src/examples/05-conformance/) | The server the conformance suite drives, over all three bindings |
| 06 | [`interop`](src/examples/06-interop/) | A client calling a live agent over the binding it is told: message, stream, task, two refusals |
| 07 | [`otel`](src/examples/07-otel/) | Both ends of one exchange, instrumented and sent to a collector |

## Tests

```
moon test --target all
```

`async test` blocks run on the native, js and wasm backends; the wasm-gc toolchain drops them, so
the synchronous suite — the wire model, the state machine, the agent card, error mapping — is what
runs there.

## Licence

Apache 2.0.
