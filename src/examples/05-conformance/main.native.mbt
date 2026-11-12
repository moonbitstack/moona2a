// A server to run a conformance suite against. Each message id the suite sends names a behaviour
// the suite checks: a task that completes, one that waits for input, a stream of artifacts, a
// webhook that has to be called. Everything else is the protocol's own work.

///|
/// The agent behind the server.
struct Conformance {
  mut artifacts : Int64
}

///|
/// One artifact id per artifact this agent makes, so a task never sees two of the same name.
fn Conformance::next_artifact(self : Conformance) -> String {
  self.artifacts = self.artifacts + 1L
  "artifact-\{self.artifacts}"
}

///|
impl @moona2a.Executor for Conformance with fn execute(self, context, out) {
  let message_id = context.message.message_id
  if message_id.has_prefix("tck-message-response") {
    out.emit(context.replying([@moona2a.Part::text("Direct message response")]))
    return
  }
  if message_id.has_prefix("tck-input-required") {
    out.emit(context.status(@moona2a.InputRequired))
    return
  }
  if message_id.has_prefix("tck-auth-required") {
    out.emit(context.status(@moona2a.AuthRequired))
    return
  }
  if message_id.has_prefix("tck-reject-task") {
    raise Rejected("the agent will not take this one")
  }
  if message_id.has_prefix("test-resubscribe-message-id") {
    out.emit(context.status(@moona2a.Working))
    @async.sleep(4000)
    out.emit(context.status(@moona2a.Completed))
    return
  }
  if message_id.has_prefix("tck-stream-artifact-chunked") {
    out.emit(context.status(@moona2a.Working))
    let artifact_id = self.next_artifact()
    out.emit(
      context.artifact(
        @moona2a.Artifact::text(artifact_id, "chunk-1 "),
        append=true,
        last_chunk=false,
      ),
    )
    out.emit(
      context.artifact(
        @moona2a.Artifact::text(artifact_id, "chunk-2"),
        append=true,
        last_chunk=true,
      ),
    )
    out.emit(context.status(@moona2a.Completed))
    return
  }
  if message_id.has_prefix("tck-artifact-file-url") {
    out.emit(
      context.artifact(
        @moona2a.Artifact::new(self.next_artifact(), [
          @moona2a.Part::uri(
            "https://example.com/output.txt",
            filename="output.txt",
            media_type="text/plain",
          ),
        ]),
      ),
    )
    out.emit(context.status(@moona2a.Completed))
    return
  }
  if message_id.has_prefix("tck-artifact-file") ||
    message_id.has_prefix("tck-stream-artifact-file") {
    out.emit(context.status(@moona2a.Working))
    out.emit(
      context.artifact(
        @moona2a.Artifact::new(self.next_artifact(), [
          @moona2a.Part::bytes(
            b"tck",
            filename="output.txt",
            media_type="text/plain",
          ),
        ]),
      ),
    )
    out.emit(context.status(@moona2a.Completed))
    return
  }
  if message_id.has_prefix("tck-artifact-data") {
    let data = @moonjson.loads(
      "{\"key\":\"value\",\"count\":42}", @moonjson.strict,
    ) catch {
      _ => Json::null()
    }
    out.emit(
      context.artifact(
        @moona2a.Artifact::new(self.next_artifact(), [@moona2a.Part::data(data)]),
      ),
    )
    out.emit(context.status(@moona2a.Completed))
    return
  }
  if message_id.has_prefix("tck-artifact-text") {
    out.emit(
      context.artifact(
        @moona2a.Artifact::text(self.next_artifact(), "Generated text content"),
      ),
    )
    out.emit(context.status(@moona2a.Completed))
    return
  }
  if message_id.has_prefix("tck-stream-artifact-text") {
    out.emit(context.status(@moona2a.Working))
    out.emit(
      context.artifact(
        @moona2a.Artifact::text(self.next_artifact(), "Streamed text content"),
      ),
    )
    out.emit(context.status(@moona2a.Completed))
    return
  }
  if message_id.has_prefix("tck-stream-ordering") {
    out.emit(context.status(@moona2a.Working))
    out.emit(
      context.artifact(
        @moona2a.Artifact::text(self.next_artifact(), "Ordered output"),
      ),
    )
    out.emit(context.status(@moona2a.Completed))
    return
  }
  if message_id.has_prefix("tck-stream-001") {
    out.emit(context.status(@moona2a.Working))
    out.emit(
      context.artifact(
        @moona2a.Artifact::text(self.next_artifact(), "Stream hello from TCK"),
      ),
    )
    out.emit(context.status(@moona2a.Completed))
    return
  }
  if message_id.has_prefix("tck-stream-002") {
    out.emit(context.status(@moona2a.Completed))
    return
  }
  if message_id.has_prefix("tck-stream-003") {
    out.emit(context.status(@moona2a.Working))
    out.emit(
      context.artifact(
        @moona2a.Artifact::text(self.next_artifact(), "Stream task lifecycle"),
      ),
    )
    out.emit(context.status(@moona2a.Completed))
    return
  }
  // Everything else finishes, answering with the suite's own words so a failure is readable.
  out.emit(context.status(@moona2a.Working))
  let agent_message = @moona2a.Message::agent(
    context.task_id + "-reply",
    "Hello from TCK",
  ).in_task(context.task_id, context.context_id)
  out.emit(context.status(@moona2a.Completed) |> attach_message(agent_message))
}

///|
/// A task the agent would not take.
suberror Rejected {
  Rejected(String)
}

///|
/// The same status event, carrying `message` as its status message.
fn attach_message(
  event : @moona2a.StreamEvent,
  message : @moona2a.Message,
) -> @moona2a.StreamEvent {
  match event {
    @moona2a.StatusChange(update) =>
      @moona2a.StreamEvent::StatusChange({
        ..update,
        status: { ..update.status, message: Some(message), },
      })
    other => other
  }
}

///|
impl @moona2a.Executor for Conformance with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
pub extend Conformance with @moona2a.Executor::{execute, cancel}

///|
/// The card this server publishes.
fn card(port : Int32) -> @moona2a.AgentCard {
  let base = "http://127.0.0.1:\{port}"
  @moona2a.AgentCard::new(
    "A2A MoonBit conformance agent",
    "An agent that answers the conformance suite's messages",
    "1.0.0",
    base,
    [
      @moona2a.AgentSkill::new(
        "conformance",
        "Conformance",
        "answers the message ids the conformance suite sends",
        ["conformance"],
      ),
    ],
  ).capable({
    streaming: true,
    push_notifications: true,
    extended_agent_card: false,
    extensions: [],
  })
}

///|
async fn main {
  let port = 9999
  let store = @moona2a.MemoryStore::new()
  let server = @moona2a.Server::new(Conformance::{ artifacts: 0L, }, card(port))
    .storing(store)
    .notifying(@fetch.Webhook::{ })
  let app = @asgi.to_asgi(server)
  @async.with_task_group(async fn(group) {
    // A caller that asks not to wait leaves its run to this group, which outlives the request.
    server.attach(group) |> ignore
    let address = @socket.Addr::parse("0.0.0.0:\{port}")
    @http.Server(address, reuse_addr=true).run_forever(async fn(
      request,
      body,
      connection,
    ) {
      let whole = body.read_all()
      let scope = @spec.Http({
        http_version: "1.1",
        http_method: method_name(request.meth),
        scheme: "http",
        path: path_of(request.path),
        raw_path: None,
        query_string: b"",
        root_path: "",
        headers: request.headers
        .iter()
        .map(fn(pair) { (pair.0.to_string(), pair.1) })
        .collect(),
        client: None,
        server: None,
        asgi: @moonasgi.AsgiVersion::http(),
        extensions: http_extensions(),
        state: Map([]),
      })
      let receive : @moonasgi.Receive = fn() {
        @spec.HttpRequest(body=whole.binary(), more_body=false)
      }
      let send : @moonasgi.Send = async fn(event) {
        match event {
          @spec.HttpResponseStart(status~, headers~, ..) => {
            let extra : Map[@http.CaseInsensitiveString, String] = Map([])
            for pair in headers {
              extra[@http.CaseInsensitiveString(pair.0)] = pair.1
            }
            connection.send_response(status, "OK", extra_headers=extra)
          }
          @spec.HttpResponseBody(body~, more_body~) => {
            connection.write(body)
            // A streamed answer is only a stream if each frame leaves as it is written.
            if more_body {
              connection.flush()
            }
          }
          _ => ()
        }
      }
      app(scope, receive, send)
      // The server closes the response itself once this handler returns; closing it here would
      // write a second terminator and corrupt the next request on a kept-alive connection.
    })
  })
}

///|
/// The path part of a request target. RFC 9112 lets a client send the target in absolute form
/// (`http://host/path`), and the scope wants the path alone either way.
fn path_of(target : String) -> String {
  for scheme in ["http://", "https://"] {
    if target.has_prefix(scheme) {
      let rest = target[scheme.length():].to_owned()
      return match rest.find("/") {
        Some(slash) => rest[slash:].to_owned()
        None => "/"
      }
    }
  }
  target
}

///|
/// The HTTP method as the ASGI scope spells it.
fn method_name(meth : @http.RequestMethod) -> String {
  match meth {
    @http.Get => "GET"
    @http.Head => "HEAD"
    @http.Post => "POST"
    @http.Put => "PUT"
    @http.Delete => "DELETE"
    @http.Connect => "CONNECT"
    @http.Options => "OPTIONS"
    @http.Trace => "TRACE"
    @http.Patch => "PATCH"
  }
}

///|
/// The ASGI extensions this host turns off: it answers plain HTTP/1.1 and pushes nothing.
fn http_extensions() -> @spec.Extensions {
  {
    tls: None,
    http_response_push: false,
    http_response_trailers: false,
    http_response_pathsend: false,
    http_response_zerocopysend: false,
    http_response_early_hint: false,
    http_response_debug: false,
    websocket_http_response: false,
    custom: Map([]),
  }
}
