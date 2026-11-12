// One exchange recorded from both ends: the client's calls, the server's answer, and the
// spans each of them puts on the wire.
//
//     moon run src/examples/07-otel --target native -- 127.0.0.1:4317
//
// The address is a collector's OTLP/gRPC port. The program requires it to be there and
// exits non-zero when the spans could not be delivered, which is what the conformance
// job runs. With no address it prints how to run it and stops, since a span that goes
// nowhere is the one thing this example is not about.

///|
/// An agent that repeats what it is told.
struct Echo {}

///|
impl @moona2a.Executor for Echo with fn execute(self, ctx, out) {
  ignore(self)
  out.emit(ctx.status(@moona2a.Working))
  out.emit(
    ctx.artifact(
      @moona2a.Artifact::text("answer", "You said: " + ctx.message.text()),
    ),
  )
  out.emit(ctx.status(@moona2a.Completed))
}

///|
impl @moona2a.Executor for Echo with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
pub extend Echo with @moona2a.Executor::{execute, cancel}

///|
/// A transport that hands a call to a server in this process, carrying the headers of
/// that call. The protocol does not care where the messages go: a socket would carry
/// the same headers, which is what the `fetch` transport does with them.
struct Local {
  server : @moona2a.Server
}

///|
async fn Local::answer(
  self : Local,
  message : @moonjrpc.Message,
  headers : @moona2a.Headers,
) -> @moonjrpc.Message {
  let answer = self.server.answer(
    message.to_json().stringify(),
    version="1.0",
    headers~,
  ) catch {
    _ => None
  }
  match answer {
    Some(text) => {
      let body = @moonjson.loads(text, @moonjson.strict) catch {
        _ => Json::null()
      }
      let reply : @moonjrpc.Message = @json.from_json(body) catch {
        _ => @moonjrpc.Message::unreadable()
      }
      reply
    }
    None => @moonjrpc.Message::unreadable()
  }
}

///|
impl @moona2a.Transport for Local with fn exchange(self, message) {
  self.answer(message, [])
}

///|
impl @moona2a.Transport for Local with fn exchange_with(self, message, headers) {
  self.answer(message, headers)
}

///|
async fn Local::deliver(
  self : Local,
  message : @moonjrpc.Message,
  out : &@moona2a.ReplySink,
  headers : @moona2a.Headers,
) -> Unit {
  self.server.answer_stream(
    message.to_json().stringify(),
    out,
    version="1.0",
    headers~,
  )
}

///|
impl @moona2a.Transport for Local with fn stream(self, message, out) {
  self.deliver(message, out, [])
}

///|
impl @moona2a.Transport for Local with fn stream_with(
  self,
  message,
  out,
  headers,
) {
  self.deliver(message, out, headers)
}

///|
impl @moona2a.Transport for Local with fn discover(self) {
  self.server.card_json()
}

///|
impl @moona2a.Transport for Local with fn discover_with(self, headers) {
  ignore(headers)
  self.server.card_json()
}

///|
pub extend Local with @moona2a.Transport::{
  exchange,
  exchange_with,
  stream,
  stream_with,
  discover,
  discover_with,
}

///|
/// A reply sink that prints what a stream carries as it arrives.
struct Printer {}

///|
impl @moona2a.ReplySink for Printer with fn reply(self, message) {
  ignore(self)
  match message {
    @moonjrpc.Reply(result~, ..) => {
      let event : @moona2a.StreamEvent = @json.from_json(result) catch {
        _ => return
      }
      match event {
        @moona2a.TaskSnapshot(task) =>
          println("  event: task \{task.id} \{task.status.state.wire()}")
        @moona2a.StatusChange(update) =>
          println("  event: status \{update.status.state.wire()}")
        @moona2a.ArtifactChunk(update) =>
          println("  event: artifact \{update.artifact.artifact_id}")
        @moona2a.TaskMessage(text) => println("  event: message \{text.text()}")
      }
    }
    @moonjrpc.Refusal(failure~, ..) => println("  refused: \{failure.message}")
    _ => ()
  }
}

///|
#coverage.skip
async fn main {
  let arguments = @env.args()
  if arguments.length() < 2 {
    println(
      "usage: 07-otel <host:port>   the OTLP/gRPC port of a collector, usually 4317",
    )
    return
  }
  let address = arguments[1]
  let (host, port) = host_and_port(address)
  let transport = @grpc.GrpcTransport::connect(host~, port~)
  // gRPC carries the binary encoding only, so the exporter is built for it.
  let traces = @otlp.TraceExporter::new(
    transport~,
    endpoint="http://\{address}",
    resource=@otlp.Resource::of_service("moona2a-example"),
    encoding=@binary.protobuf,
    now=millis,
    rand=random_bytes,
    attempts=5,
  )
  let tracer = @trace.Tracer::new(
    sink=traces,
    rand=random_bytes,
    sampler=@trace.always,
  )
  let card = @moona2a.AgentCard::new(
    "echo",
    "repeats what it is told",
    "1.0.0",
    "https://echo.example.com",
    [@moona2a.AgentSkill::new("echo", "Echo", "repeats a message", ["echo"])],
  )
  let tracing = @otel.Tracing::new(
    tracer~,
    now=nanoseconds,
    agent=@otel.Agent::of_card(card),
  )
  let server = @moona2a.Server::new(tracing.executing(Echo::{ }), card)
  // Each call carries its own headers to this transport, which hands them to the server;
  // the server hands them to the run. No cell, so several calls can be in flight at once.
  let client = @moona2a.Client::new(tracing.calling(Local::{ server, }))

  println("reading the card")
  let read = client.discover()
  println("  card: \{read.name}, version \{read.version}")

  println("sending a message")
  let answer = client.send_message(@moona2a.Message::user("m-1", "hello"))
  let task_id = match answer {
    @moona2a.TaskSnapshot(task) => {
      println("  task: \{task.id} \{task.status.state.wire()}")
      task.id
    }
    @moona2a.TaskMessage(message) => {
      println("  message: \{message.text()}")
      ""
    }
    _ => ""
  }

  if task_id != "" {
    let task = client.get_task(task_id)
    println("read the task back: \{task.status.state.wire()}")

    println("following a stream")
    client.send_streaming_message(@moona2a.Message::user("m-2", "again"), Printer::{
    })

    // A finished task takes no more work, so the cancel is refused — which is one of
    // the spans worth having, since a refusal is what an error span looks like here.
    let cancelled = try {
      client.cancel_task(task_id) |> ignore
      false
    } catch {
      @moona2a.TaskNotCancelable(_) => true
      _ => false
    }
    println("cancelling a finished task was refused: \{cancelled}")
  }

  let report = traces.flush()
  transport.close()
  println(
    "spans: delivered \{report.delivered}, rejected \{report.rejected}, " +
    "dropped \{report.dropped}, requests \{report.attempts}",
  )
  if report.delivered == 0 || report.rejected != 0 {
    abort("a collector was named at \{address} and did not take the spans")
  }
}

///|
/// `host:port`, as a channel connects.
fn host_and_port(address : String) -> (String, Int32) {
  match address.find(":") {
    Some(at) =>
      (
        address.exact_view(start=0, end=at).to_owned(),
        @string.parse_int(
          address.exact_view(start=at + 1, end=address.length()),
        ) catch {
          _ => 4317
        },
      )
    None => (address, 4317)
  }
}

///|
/// The clock the exporter batches with, in milliseconds.
fn millis() -> Int64 {
  @async.now()
}

///|
/// The clock a span is timed with, in nanoseconds, which is the unit a span's start and
/// end are in.
fn nanoseconds() -> Int64 {
  @async.now() * 1_000_000L
}

///|
fn random_bytes(width : Int32) -> Bytes {
  @moonseed.bytes(width, @system.source) catch {
    _ => abort("the platform has no entropy source")
  }
}
