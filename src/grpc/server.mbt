// The server side of the gRPC binding: each method of `A2AService` answered by a moona2a server,
// with the version and extensions read from the call's metadata (section 10.2).

///|
/// Register the eleven methods of `A2AService` on `registrar`, each answered by `server` as the
/// other two bindings answer it. The handlers answer through a responder, so the moonrpc server
/// they go on runs its calls concurrently, as `GrpcServer` does.
pub fn register(
  registrar : &@stream.Registrar,
  server : @moona2a.Server,
) -> Unit {
  for rpc in @moona2a.Method::all() {
    registrar.register_handler(
      rpc.grpc_path(),
      @stream.Pushed(async fn(ctx, requests, out) {
        answer(server, rpc, ctx, requests, out)
      }),
    )
  }
}

///|
/// Answer one call. A refusal ends the call with the status section 5.4 maps it to, and its
/// `ErrorInfo` goes into `grpc-status-details-bin`.
async fn answer(
  server : @moona2a.Server,
  rpc : @moona2a.Method,
  ctx : @stream.RpcContext,
  requests : Array[Bytes],
  out : @stream.Responder,
) -> Unit {
  let (request_type, reply_type) = types_of(rpc)
  let headers = ctx.metadata.map(header => header.ascii())
  let version = match ctx.metadata_get(b"a2a-version") {
    Some(value) => @utf8.decode_lossy(value)
    None => ""
  }
  let extensions = match ctx.metadata_get(b"a2a-extensions") {
    Some(value) =>
      @utf8.decode_lossy(value)
      .split(",")
      .map(part => part.trim().to_owned())
      .filter(part => part != "")
      .collect()
    None => []
  }
  let refused = try {
    let request = if requests.is_empty() { b"" } else { requests[0] }
    let params = decode(request_type, request) catch {
      error =>
        raise @moona2a.InvalidParams("the request does not read: \{error}")
    }
    if rpc.streams() {
      let replies = Replies::{ out, reply_type, }
      server.invoke_stream(
        rpc,
        replies,
        params~,
        extensions~,
        version~,
        headers~,
      )
    } else {
      let answer = server.invoke(rpc, params~, extensions~, version~, headers~)
      // `google.protobuf.Empty` is `{}` in JSON; the server answers a deletion with null.
      let shown = if answer is Null { Json::object({}) } else { answer }
      (out.send)([encode(reply_type, shown)])
    }
    None
  } catch {
    error => Some(@moona2a.failure_of(error))
  }
  if refused is Some(failure) {
    ctx.fail(@moona2a.Status::of(failure.code).grpc, failure.message)
    if failure.data is Some(Array(details)) {
      for detail in details {
        ctx.add_error_detail(encode("google.protobuf.Any", detail)) catch {
          _ => ()
        }
      }
    }
  }
  (out.finish)()
}

///|
/// A sink that sends each event as one `StreamResponse` of the call.
priv struct Replies {
  out : @stream.Responder
  reply_type : String
}

///|
impl @moona2a.EventSink for Replies with fn emit(self, event) {
  (self.out.send)([encode(self.reply_type, event.to_json())])
}
