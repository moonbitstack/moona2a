// The gRPC client against this library's own gRPC server, over a real HTTP/2 connection on a
// port the system picks.

///|
/// An agent that works every message to the end in two steps.
struct Echo {}

///|
impl @moona2a.Executor for Echo with fn execute(self, ctx, out) {
  ignore(self)
  out.emit(ctx.status(@moona2a.Working))
  out.emit(ctx.artifact(@moona2a.Artifact::text("a-1", "heard")))
  out.emit(ctx.status(@moona2a.Completed))
}

///|
impl @moona2a.Executor for Echo with fn cancel(self, task_id) {
  ignore(self)
  ignore(task_id)
}

///|
/// A sink that keeps every reply.
struct Kept {
  replies : Array[@moonjrpc.Message]
}

///|
impl @moona2a.ReplySink for Kept with fn reply(self, message) {
  self.replies.push(message)
}

///|
/// Serve an agent over gRPC, connect a client to it, and run `body` with the client.
async fn with_agent(body : async (@moona2a.Client) -> Unit) -> Unit {
  let card = @moona2a.AgentCard::new("echo", "repeats", "1.0.0", "http://h", []).capable(
    @moona2a.AgentCapabilities::streaming_and_push(),
  )
  let server = @net.GrpcServer::new()
  @grpc.register(server, @moona2a.Server::new(Echo::{ }, card))
  let port = server.bind(port=0).port()
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, () => server.serve())
    let transport = @channel.GrpcTransport::connect(
      "127.0.0.1:\{port}",
      group,
      card=card.to_json(),
    )
    body(@moona2a.Client::new(transport))
    transport.close()
    group.return_immediately(())
  })
}

///|
async test "grpc channel: a send, a read and the card go through the gRPC binding" {
  with_agent(async fn(client) {
    guard client.send_message(@moona2a.Message::user("m-1", "hi"))
      is @moona2a.TaskSnapshot(task) else {
      fail("the send did not answer with a task")
    }
    assert_eq(task.status.state.wire(), "TASK_STATE_COMPLETED")
    assert_eq(task.artifacts[0].text_of(), "heard")
    let read = client.get_task(task.id, history_length=0)
    assert_eq(read.id, task.id)
    assert_eq(client.discover().name, "echo")
  })
}

///|
async test "grpc channel: refusals come back as the errors their ErrorInfo names" {
  with_agent(async fn(client) {
    let missing = try {
      ignore(client.get_task("ghost"))
      false
    } catch {
      @moona2a.TaskNotFound(_) => true
      _ => false
    }
    assert_true(missing)
    guard client.send_message(@moona2a.Message::user("m-2", "hi"))
      is @moona2a.TaskSnapshot(task) else {
      fail("the send did not answer with a task")
    }
    let finished = try {
      ignore(client.cancel_task(task.id))
      false
    } catch {
      @moona2a.TaskNotCancelable(_) => true
      _ => false
    }
    assert_true(finished)
  })
}

///|
async test "grpc channel: a streamed send arrives message by message, in order" {
  with_agent(async fn(client) {
    let kept = Kept::{ replies: [], }
    client.send_streaming_message(@moona2a.Message::user("m-3", "hi"), kept)
    let kinds = kept.replies.map(reply => {
      match reply {
        Reply(result~, ..) =>
          match result {
            Object(fields) =>
              if fields.get("task") is Some(_) {
                "task"
              } else if fields.get("statusUpdate") is Some(_) {
                "status"
              } else if fields.get("artifactUpdate") is Some(_) {
                "artifact"
              } else {
                "other"
              }
            _ => "other"
          }
        _ => "refusal"
      }
    })
    assert_eq(kinds, ["task", "status", "artifact", "status"])
  })
}

///|
async test "grpc channel: a stream refused before it starts hands over one refusal" {
  with_agent(async fn(client) {
    let kept = Kept::{ replies: [], }
    client.subscribe_to_task("ghost", kept)
    guard kept.replies is [Refusal(failure~, ..)] else {
      fail("expected one refusal")
    }
    assert_eq(failure.code, -32001)
  })
}
