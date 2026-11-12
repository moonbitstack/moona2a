---
name: moona2a
description: "Serve or call an Agent2Agent (A2A) agent in MoonBit — publish an agent card, answer the JSON-RPC methods, stream task updates, register push webhooks, send per-call request headers, trace a run with OpenTelemetry, and talk to another agent. Use when agents need to discover each other and exchange tasks over HTTP."
---

# moona2a

The Agent2Agent protocol, both directions. A server holds an agent and answers the protocol's
methods; a client calls an agent that someone else runs.

```
moon add moonbitstack/moona2a
```

| Package | Use it for |
|:--|:--|
| `moonbitstack/moona2a` | the wire model, the server, the client |
| `moonbitstack/moona2a/asgi` | the HTTP endpoint as an ASGI application |
| `moonbitstack/moona2a/fetch` | an HTTP client transport, and the webhook notifier |
| `moonbitstack/moona2a/otel` | spans for a run and for a client's call |

An agent is an `Executor`: it is given the message and emits what happens. Tasks, history,
artifacts, cancellation, push registrations and every protocol error are the server's work.

```moonbit
struct Greeter {}

impl @moona2a.Executor for Greeter with fn execute(self, ctx, out) {
  ignore(self)
  out.emit(ctx.status(@moona2a.Working))
  out.emit(ctx.artifact(@moona2a.Artifact::text("greeting", "hello " + ctx.message.text())))
  out.emit(ctx.status(@moona2a.Completed))
}

impl @moona2a.Executor for Greeter with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

pub extend Greeter with @moona2a.Executor::{execute, cancel}
```

Put it behind an endpoint, and hand the application to whichever ASGI server the process runs:

```moonbit
let card = @moona2a.AgentCard::new(
  "greeter",
  "says hello",
  "1.0.0",
  "https://greeter.example.com",
  [@moona2a.AgentSkill::new("greet", "Greet", "says hello", ["text"])],
)
let server = @moona2a.Server::new(Greeter::{ }, card)
let app = @asgi.to_asgi(server)
```

The application answers `GET /.well-known/agent-card.json` with the card and `POST /` with the
methods. A streaming method answers `text/event-stream`, one `data:` frame per event, and holds the
response open until the task finishes or the caller leaves.

## Call another agent

```moonbit native
async fn ask(url : String) -> String raise {
  let transport = @fetch.HttpTransport::new(url)
  let client = @moona2a.Client::new(transport)
  let card = client.discover()
  match client.send_message(@moona2a.Message::user("m-1", "hello")) {
    @moona2a.TaskSnapshot(task) => "\{card.name}: \{task.status.state.wire()}"
    @moona2a.TaskMessage(reply) => reply.text()
    _ => "no answer"
  }
}
```

`Client` takes any `Transport`. In a test, implement `exchange`, `stream` and `discover` on a
struct and answer from a table; nothing binds the client to HTTP.

## Headers on a call

Every client method takes `headers?`: a trace context, a tenant, or a credential that belongs to
one call. The transport merges them with what it always sends; a name both supply keeps the call's
value. A transport that only implements `exchange`, `stream` and `discover` still works — the three
`*_with` methods default to them and drop the headers.

```moonbit native
async fn ask_as(url : String, tenant : String) -> @moona2a.AgentCard raise {
  let client = @moona2a.Client::new(@fetch.HttpTransport::new(url))
  client.discover(headers=[("x-tenant", tenant)])
}
```

## Trace it

A run and a call become OpenTelemetry spans named `invoke_agent` and the agent, in the GenAI
conventions. The tracer is yours, so the spans join whatever the process already exports.

```moonbit
fn traced(greeter : &@moona2a.Executor, rand : (Int32) -> Bytes, now : () -> Int64) -> @moona2a.Server {
  let tracing = @otel.Tracing::new(
    tracer=@trace.Tracer::new(rand~, sink=@trace.discard, sampler=@trace.always),
    now~,
    agent=@otel.Agent::new(id="https://greeter.example.com", name="greeter"),
  )
  let card = @moona2a.AgentCard::new(
    "greeter",
    "says hello",
    "1.0.0",
    "https://greeter.example.com",
    [@moona2a.AgentSkill::new("greet", "Greet", "says hello", ["text"])],
  )
  @moona2a.Server::new(tracing.executing(greeter), card)
}
```

`tracing.calling(transport)` does the same for the client side. Message text stays out of the spans
until `recording_content()` is asked for.

A call carries its trace across the wire, so the run on the other side is a child of the span that
called it: `tracing.calling(transport)` adds `traceparent` to that call's headers, the transport
sends them, and the agent is handed the request's headers as `RequestContext.headers`. Headers are
per call, so several tasks can share one traced transport without mixing traces.

```moonbit native
fn wired(url : String, tracing : @otel.Tracing) -> @moona2a.Client raise {
  @moona2a.Client::new(tracing.calling(@fetch.HttpTransport::new(url)))
}
```

## Rules that bite

- **Version.** Send `A2A-Version: 1.0` on every request. A request with no version header is a 0.3
  client and is refused with `VersionNotSupported`, because this library speaks 1.0 only.
- **Bodies are read strictly.** A comment, a trailing comma or a hex number is refused with
  `-32700`. A number a caller writes keeps its digits in the answer.
- **Streaming errors.** A call refused before the stream starts (unknown task, finished task,
  unsupported version) answers with a plain JSON-RPC error body, not a stream. Read the
  content-type before assuming frames.
- **Media types.** The framework does not refuse a part because its media type is missing from the
  card; the agent decides. Set `ServerConfig.refuse_unknown_media` to make the card's list a hard
  filter.
- **Ids are the server's.** `messageId` is the caller's to choose; `taskId` and `contextId` are
  minted by the server. A message that names a task continues it, and one that names a finished
  task is refused.
- **One task, many watchers.** Several `SubscribeToTask` calls can follow the same task; each gets
  the task as it stood when it joined, then everything after.
- **Push registrations are flattened.** `TaskPushConfig` carries `taskId`, `url`, `token` and
  `authentication` in one object — not nested, as earlier drafts had it.
- **Sockets.** `moona2a/fetch` needs them, so it is there on the native and wasm backends and not
  on the JavaScript one. The server side is an ASGI application and needs nothing.
- **Headers belong to a call.** Pass `headers=` to a `Client` method, not a shared cell. One
  traced transport can serve many tasks; a `traceparent` a caller supplies is replaced by the
  span of that call. `Injector` observes one call in flight, it is not on the path to the wire.
