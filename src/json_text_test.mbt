// The text the wire carries. A body is read as RFC 8259 writes JSON, so what the grammar does not
// allow is refused rather than repaired, and the reader stops at a depth instead of exhausting the
// stack.

///|
async test "json text: a trailing comma makes the body unreadable" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"GetTask\",}"
  assert_eq(error_code_of(server.answer(body)), -32700)
}

///|
async test "json text: a comment makes the body unreadable" {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let body = "{\"jsonrpc\":\"2.0\",\"id\":1,/* a note */\"method\":\"GetTask\"}"
  assert_eq(error_code_of(server.answer(body)), -32700)
}

///|
async test "json text: a body nested past the reader's bound is unreadable" {
  assert_eq(stream_refusal_code(deep_params(600)), Some(-32700))
}

///|
async test "json text: a streaming call with a comment in its body is unreadable" {
  assert_eq(
    stream_refusal_code(
      "{\"jsonrpc\":\"2.0\",\"id\":1,/* a note */\"method\":\"SendStreamingMessage\"}",
    ),
    Some(-32700),
  )
}

///|
test "json text: a body that does not read names no method" {
  assert_eq(@moona2a.request_method("{\"method\":\"GetTask\",}"), None)
  assert_eq(
    @moona2a.request_method("{\"method\":\"GetTask\"}"),
    Some("GetTask"),
  )
  assert_eq(@moona2a.request_method(deep_params(600)), None)
  assert_eq(@moona2a.request_method(deep_params(100)), Some("SendMessage"))
}

///|
test "json text: a number keeps the digits it arrived with" {
  let text = "{\"data\":{\"big\":9007199254740993}}"
  let json = @moonjson.loads(text, @moonjson.strict) catch {
    _ => fail("the text does not read: \{text}")
  }
  let part : @moona2a.Part = @json.from_json(json) catch {
    _ => fail("a part does not read")
  }
  assert_eq(@moonjson.dumps(part.to_json()), text)
}

///|
test "json text: text that is not ASCII goes out as the characters, not as escapes" {
  let part = @moona2a.Part::text("世界")
  assert_eq(@moonjson.dumps(part.to_json()), "{\"text\":\"世界\"}")
}

///|
/// The code of the one reply a streaming call gives to `body` when it is refused, or `None` when
/// the call went through to the method.
async fn stream_refusal_code(body : String) -> Int32? {
  let server = @moona2a.Server::new(Scripted::{ }, test_card())
  let out : Recorder = { replies: [], }
  server.answer_stream(body, out)
  if out.replies.length() != 1 {
    return None
  }
  match out.replies[0] {
    Refusal(failure~, ..) => Some(failure.code)
    _ => None
  }
}

///|
/// `depth` arrays, one inside the next, which is well-formed JSON of no use to anyone.
fn nested_arrays(depth : Int32) -> String {
  let out = StringBuilder()
  for _ in 0..<depth {
    out.write_char('[')
  }
  for _ in 0..<depth {
    out.write_char(']')
  }
  out.to_string()
}

///|
/// A `SendMessage` call whose parameters are `depth` arrays deep.
fn deep_params(depth : Int32) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendMessage\",\"params\":\{nested_arrays(depth)}}"
}
