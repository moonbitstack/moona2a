// The bytes a part carries travel as base64. The writer always pads; the reader takes either
// spelling, and refuses a character the alphabet does not hold.

///|
test "part: raw bytes read the same with and without the trailing padding" {
  let padded = "{\"raw\":\"YTJhIf8=\",\"mediaType\":\"text/plain\"}"
  let bare = "{\"raw\":\"YTJhIf8\",\"mediaType\":\"text/plain\"}"
  let read_padded = read_part(padded)
  let read_bare = read_part(bare)
  assert_true(read_padded == read_bare)
  assert_eq(read_padded.media_type(), Some("text/plain"))
}

///|
test "part: raw bytes come back padded when they go out again" {
  let part = read_part("{\"raw\":\"YTJhIf8\"}")
  let fields = match part.to_json() {
    Object(fields) => fields
    _ => fail("a part is not an object")
  }
  assert_eq(field_str(fields, "raw"), Some("YTJhIf8="))
}

///|
test "part: a raw field that is not base64 is refused" {
  let json = @moonjson.loads("{\"raw\":\"YTJhIf8*\"}", @moonjson.strict) catch {
    _ => fail("the text does not read")
  }
  let refused = try {
    let _ : @moona2a.Part = @json.from_json(json)
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}

///|
/// A part read from the text the wire carries.
fn read_part(text : String) -> @moona2a.Part raise {
  let json = @moonjson.loads(text, @moonjson.strict) catch {
    _ => fail("the text does not read: \{text}")
  }
  @json.from_json(json)
}
