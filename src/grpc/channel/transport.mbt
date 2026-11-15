// The gRPC endpoint of one agent as a moona2a transport: a call becomes the method of
// `A2AService` it names, its parameters the request message, and a refusal the status and
// `ErrorInfo` the server ended the call with (section 10.6).

///|
/// One agent's gRPC interface over a multiplexed HTTP/2 connection.
pub struct GrpcTransport {
  channel : @net.MuxChannel
  /// The card a caller chose this interface from, which `discover` hands back: the binding
  /// itself has no method for the public card.
  card : Json?
  /// Metadata to add to every call, read as each one is built.
  extra : () -> Array[(String, String)]
}

///|
/// Connect to the agent at `url`, written `host:port` as a card's interface gives it, and keep
/// the connection's reader running in `group`. With `tls` the connection is a TLS one settled
/// on `h2`, which section 10.1 asks for outside a test.
pub async fn GrpcTransport::connect(
  url : String,
  group : @async.TaskGroup[Unit],
  tls? : @tls.Client,
  card? : Json,
  headers? : () -> Array[(String, String)],
) -> GrpcTransport {
  let (host, port) = match url.rev_find(":") {
    Some(colon) =>
      (
        url.exact_view(start=0, end=colon).to_owned(),
        @string.parse_int(url.exact_view(start=colon + 1, end=url.length())) catch {
          _ =>
            raise @moona2a.InvalidParams("the port of \{url} is not a number")
        },
      )
    None => raise @moona2a.InvalidParams("\{url} is not host:port")
  }
  let channel = @net.MuxChannel::connect(host, port, tls?)
  group.spawn_bg(no_wait=true, allow_failure=true, () => channel.read_pump())
  {
    channel,
    card,
    extra: headers.unwrap_or(fn() { ([] : Array[(String, String)]) }),
  }
}

///|
/// Close the connection.
pub fn GrpcTransport::close(self : GrpcTransport) -> Unit {
  self.channel.close()
}

///|
/// The metadata of one call: the version this library speaks, then the host's, then the
/// call's own, names in lower case as gRPC writes them.
fn GrpcTransport::metadata(
  self : GrpcTransport,
  per_call : Array[(String, String)],
) -> Array[@header.Header] {
  @moona2a.merge_headers(
    @moona2a.merge_headers(
      [("a2a-version", @moona2a.protocol_version)],
      (self.extra)(),
    ),
    per_call,
  ).map(pair => @header.Header::{
    name: @utf8.encode(pair.0.to_lower()),
    value: @utf8.encode(pair.1),
  })
}

///|
/// The method a call names and its request in binary form.
fn prepare(
  name : String,
  params : Json?,
) -> (@moona2a.Method, String, Bytes) raise {
  guard @moona2a.Method::from_name(name) is Some(rpc) else {
    raise @moona2a.UnsupportedOperation("the gRPC binding has no \{name}")
  }
  let (request_type, reply_type) = @grpc.types_of(rpc)
  let request = @grpc.encode(request_type, params.unwrap_or(Json::object({}))) catch {
    error => raise @moona2a.InvalidParams("\{name}: \{error}")
  }
  (rpc, reply_type, request)
}

///|
/// The failure a call ended with, when it did not end well.
fn failure_of(reply : @moonrpc.CallReply) -> @moonjrpc.Failure? {
  if reply.grpc_status == 0 {
    return None
  }
  // moonrpc hands a `-bin` trailer over already decoded from base64.
  let details = reply.trailers
    .iter()
    .filter(header => header.name == b"grpc-status-details-bin")
    .head()
    .map(header => @grpc.details_of(header.value) catch { _ => [] })
    .unwrap_or([])
  Some(
    @moona2a.failure_of_status(reply.grpc_status, reply.grpc_message, details),
  )
}

///|
/// Read one reply message.
fn read(reply_type : String, bytes : BytesView) -> Json raise {
  @grpc.decode(reply_type, bytes) catch {
    error => raise @moona2a.InvalidAgentResponse("\{reply_type}: \{error}")
  }
}

///|
/// Make one call and return its answer.
async fn GrpcTransport::reply(
  self : GrpcTransport,
  message : @moonjrpc.Message,
  headers : Array[(String, String)],
) -> @moonjrpc.Message {
  guard message is Call(id~, name~, params~) else {
    raise @moona2a.InvalidRequest("only a call has an answer")
  }
  let (rpc, reply_type, request) = prepare(name, params) catch {
    error =>
      return @moonjrpc.Message::Refusal(id~, failure=@moona2a.failure_of(error))
  }
  let reply = self.channel.unary(
    rpc.grpc_path(),
    request,
    metadata=self.metadata(headers),
  )
  match failure_of(reply) {
    Some(failure) => @moonjrpc.Message::Refusal(id~, failure~)
    None => {
      let result = match reply.messages {
        [first, ..] => read(reply_type, first)
        [] => Json::object({})
      }
      @moonjrpc.Message::Reply(id~, result~)
    }
  }
}

///|
/// Make one streaming call and hand each message to `out` as it arrives, then the failure the
/// call ended with, if it did not end well.
async fn GrpcTransport::deliver(
  self : GrpcTransport,
  message : @moonjrpc.Message,
  out : &@moona2a.ReplySink,
  headers : Array[(String, String)],
) -> Unit {
  guard message is Call(id~, name~, params~) else {
    raise @moona2a.InvalidRequest("only a call has an answer")
  }
  let (rpc, reply_type, request) = prepare(name, params) catch {
    error => {
      out.reply(
        @moonjrpc.Message::Refusal(id~, failure=@moona2a.failure_of(error)),
      )
      return
    }
  }
  let stream = self.channel.open_bidi(
    rpc.grpc_path(),
    metadata=self.metadata(headers),
  )
  stream.send(request)
  stream.close_send()
  while stream.recv() is Some(bytes) {
    out.reply(@moonjrpc.Message::Reply(id~, result=read(reply_type, bytes)))
  }
  if failure_of(stream.reply()) is Some(failure) {
    out.reply(@moonjrpc.Message::Refusal(id~, failure~))
  }
}

///|
pub impl @moona2a.Transport for GrpcTransport with fn exchange(self, message) {
  self.reply(message, [])
}

///|
pub impl @moona2a.Transport for GrpcTransport with fn exchange_with(
  self,
  message,
  headers,
) {
  self.reply(message, headers)
}

///|
pub impl @moona2a.Transport for GrpcTransport with fn stream(self, message, out) {
  self.deliver(message, out, [])
}

///|
pub impl @moona2a.Transport for GrpcTransport with fn stream_with(
  self,
  message,
  out,
  headers,
) {
  self.deliver(message, out, headers)
}

///|
/// The card this transport was made from. The gRPC binding has no method for the public card,
/// which an agent serves at its HTTP well-known address.
pub impl @moona2a.Transport for GrpcTransport with fn discover(self) {
  match self.card {
    Some(card) => card
    None =>
      raise @moona2a.UnsupportedOperation(
        "the gRPC binding serves no public card; read it from the agent's well-known address",
      )
  }
}

///|
pub extend GrpcTransport with @moona2a.Transport::{
  exchange,
  exchange_with,
  stream,
  stream_with,
  discover,
  discover_with,
}
