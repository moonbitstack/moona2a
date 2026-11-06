---
name: moona2a
description: Serve or call an Agent2Agent (A2A) agent in MoonBit — publish an agent card, answer the JSON-RPC methods, stream task updates, register push webhooks, and talk to another agent. Use when agents need to discover each other and exchange tasks over HTTP.
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

An agent is an `Executor`: it is given the message and emits what happens. Tasks, history,
artifacts, cancellation, push registrations and every protocol error are the server's work.

```moonbit
///|
impl @moona2a.Executor for Greeter with fn execute(self, ctx, out) {
  ignore(self)
  out.emit(ctx.status(@moona2a.Working))
  out.emit(ctx.artifact(@moona2a.Artifact::text("greeting", "hello " + ctx.message.text())))
  out.emit(ctx.status(@moona2a.Completed))
}

///|
impl @moona2a.Executor for Greeter with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}
```

Put it behind an endpoint, and hand the application to whichever ASGI server the process runs:

```moonbit
///|
fn endpoint(server : @moona2a.Server) -> @moonasgi.AsgiApp {
  @asgi.to_asgi(server)
}
```

The application answers `GET /.well-known/agent-card.json` with the card and `POST /` with the
methods. A streaming method answers `text/event-stream`, one `data:` frame per event, and holds the
response open until the task finishes or the caller leaves.

## Call another agent

```moonbit
///|
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

## Rules that bite

- **Version.** Send `A2A-Version: 1.0` on every request. A request with no version header is a 0.3
  client and is refused with `VersionNotSupported`, because this library speaks 1.0 only.
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
