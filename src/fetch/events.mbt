// What the two HTTP transports share: the headers of a request, the card, and the events of a
// streamed answer read as they arrive.

///|
/// The headers of one request: what the protocol asks for, then what the host supplies for this
/// moment, then what this one call asked for. A name that appears twice is sent once, with the
/// last value, so a per-call `traceparent` cannot leave an older one beside it on the wire.
fn headers_for(
  extra : () -> Array[(String, String)],
  own : Array[(String, String)],
  per_call : Array[(String, String)],
) -> Array[(String, String)] {
  @moona2a.merge_headers(@moona2a.merge_headers(own, extra()), per_call)
}

///|
/// Read the agent's card from its well-known address.
async fn card_of(
  client : @moonfetch.Client,
  path : String,
  headers : Array[(String, String)],
) -> Json {
  let response = client.get(path, headers~)
  @moonjson.loads(response.text(), @moonjson.strict) catch {
    _ => raise WrongShape("the card is not JSON")
  }
}

///|
/// Hand each server-sent event of `stream` to `each` as soon as the blank line that ends it
/// arrives, rather than when the response does.
async fn each_event(
  stream : @moonfetch.Stream,
  each : async (@sse.Event) -> Unit,
) -> Unit {
  // Bytes, not text, until a whole block is in: a chunk may end inside a character.
  let mut buffered = b""
  while stream.next() is Some(Data(bytes)) {
    buffered = buffered + bytes
    guard boundary(buffered) is Some(end) else { continue }
    for event in @sse.decode(@utf8.decode_lossy(buffered[:end])) {
      each(event)
    }
    buffered = buffered[end:].to_owned()
  }
  let rest = @utf8.decode_lossy(buffered)
  if rest.trim() != "" {
    for event in @sse.decode(rest + "\n\n") {
      each(event)
    }
  }
}

///|
/// Where the last complete block of events ends: just past the last blank line, written `\n\n`
/// or `\r\n\r\n`.
fn boundary(bytes : Bytes) -> Int32? {
  for i = bytes.length() - 1; i >= 1; i = i - 1 {
    if bytes[i] == b'\n' &&
      (
        bytes[i - 1] == b'\n' ||
        (i >= 3 && bytes[i - 1] == b'\r' && bytes[i - 2] == b'\n')
      ) {
      return Some(i + 1)
    }
  }
  None
}

///|
/// Whether a response is a stream of events rather than one body.
fn is_event_stream(content_type : String?) -> Bool {
  match content_type {
    Some(value) => value.contains("text/event-stream")
    None => false
  }
}
