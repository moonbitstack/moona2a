// Reading and writing the JSON shapes the protocol shares: optional fields that vanish when unset,
// arrays of strings, integers that arrive as numbers or as strings, and a timestamp in UTC.

///|
/// An empty object, ready for fields to be put into.
fn object() -> Map[String, Json] {
  Map([])
}

///|
/// Put `value` under `key` when it is set; an unset optional field is absent, not null.
fn put_str(fields : Map[String, Json], key : String, value : String?) -> Unit {
  match value {
    Some(s) => fields[key] = Json::string(s)
    None => ()
  }
}

///|
/// Put `value` under `key` when it is set.
fn put_json(fields : Map[String, Json], key : String, value : Json?) -> Unit {
  match value {
    Some(json) => fields[key] = json
    None => ()
  }
}

///|
/// Put `value` under `key` when it is set.
fn put_int(fields : Map[String, Json], key : String, value : Int32?) -> Unit {
  match value {
    Some(n) => fields[key] = Json::number(n.to_double(), repr=n.to_string())
    None => ()
  }
}

///|
/// Put `values` under `key` when it is set.
fn put_strs(
  fields : Map[String, Json],
  key : String,
  values : Array[String]?,
) -> Unit {
  match values {
    Some(xs) => fields[key] = strings(xs)
    None => ()
  }
}

///|
/// A JSON array of strings.
fn strings(values : Array[String]) -> Json {
  Json::array(values.map(fn(s) { Json::string(s) }))
}

///|
/// The string under `key`, or none when absent or of another type.
fn opt_str(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// The object under `key`, or none when absent or of another type.
fn opt_object(fields : Map[String, Json], key : String) -> Map[String, Json]? {
  match fields.get(key) {
    Some(Object(o)) => Some(o)
    _ => None
  }
}

///|
/// The boolean under `key`, or none when absent or of another type.
fn opt_bool(fields : Map[String, Json], key : String) -> Bool? {
  match fields.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
/// The integer under `key`, or none when absent. ProtoJSON writes 64-bit integers as strings, so a
/// quoted integer is read as one.
fn opt_int(fields : Map[String, Json], key : String) -> Int32? {
  match fields.get(key) {
    Some(Number(n, ..)) => Some(n.to_int())
    Some(String(s)) => Some(@string.parse_int(s)) catch { _ => None }
    _ => None
  }
}

///|
/// The string array under `key`, or none when absent. Entries that are not strings are dropped.
fn opt_strs(fields : Map[String, Json], key : String) -> Array[String]? {
  match fields.get(key) {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        if item is String(s) {
          out.push(s)
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
/// The string array under `key`, empty when absent.
fn strs_or_empty(fields : Map[String, Json], key : String) -> Array[String] {
  match opt_strs(fields, key) {
    Some(xs) => xs
    None => []
  }
}

///|
/// The value under either spelling of a name. The protocol writes camelCase; a client that sends
/// the proto field name instead is understood rather than refused, which section 5.7 asks for.
fn pick(fields : Map[String, Json], camel : String, snake : String) -> Json? {
  match fields.get(camel) {
    Some(value) => Some(value)
    None => fields.get(snake)
  }
}

///|
/// The string under either spelling of a name.
fn pick_str(
  fields : Map[String, Json],
  camel : String,
  snake : String,
) -> String? {
  match pick(fields, camel, snake) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// The integer under either spelling of a name.
fn pick_int(
  fields : Map[String, Json],
  camel : String,
  snake : String,
) -> Int32? {
  match pick(fields, camel, snake) {
    Some(Number(n, ..)) => Some(n.to_int())
    Some(String(s)) => Some(@string.parse_int(s)) catch { _ => None }
    _ => None
  }
}

///|
/// The boolean under either spelling of a name.
fn pick_bool(
  fields : Map[String, Json],
  camel : String,
  snake : String,
) -> Bool? {
  match pick(fields, camel, snake) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
/// The object under either spelling of a name.
fn pick_object(
  fields : Map[String, Json],
  camel : String,
  snake : String,
) -> Map[String, Json]? {
  match pick(fields, camel, snake) {
    Some(Object(o)) => Some(o)
    _ => None
  }
}

///|
/// An optional field of the wrong shape has no reading; say which field it was.
fn wrong_type(
  path : @json.JsonPath,
  key : String,
  want : String,
) -> @json.JsonDecodeError {
  @json.JsonDecodeError((path.add_key(key), "want \{want}"))
}

///|
/// The object that `json` must be, or a decode error naming the path.
fn as_object(
  json : Json,
  path : @json.JsonPath,
) -> Map[String, Json] raise @json.JsonDecodeError {
  match json {
    Object(fields) => fields
    _ => raise @json.JsonDecodeError((path, "want an object"))
  }
}

///|
/// The required string under `key`.
fn need_str(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> String raise @json.JsonDecodeError {
  match opt_str(fields, key) {
    Some(s) => s
    None => raise wrong_type(path, key, "a string")
  }
}

///|
/// The required array under `key`.
fn need_array(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Array[Json] raise @json.JsonDecodeError {
  match fields.get(key) {
    Some(Array(items)) => items
    _ => raise wrong_type(path, key, "an array")
  }
}

///|
/// Read an optional object-valued field with `read`, keeping it absent when the field is.
fn[A] read_opt(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
  read : (Json, @json.JsonPath) -> A raise @json.JsonDecodeError,
) -> A? raise @json.JsonDecodeError {
  match fields.get(key) {
    Some(json) => Some(read(json, path.add_key(key)))
    None => None
  }
}

///|
/// Read an array-valued field with `read`, absent when the field is.
fn[A] read_opt_array(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
  read : (Json, @json.JsonPath) -> A raise @json.JsonDecodeError,
) -> Array[A]? raise @json.JsonDecodeError {
  match fields.get(key) {
    Some(Array(items)) => {
      let out : Array[A] = []
      let mut index = 0
      for item in items {
        out.push(read(item, path.add_key(key).add_index(index)))
        index = index + 1
      }
      Some(out)
    }
    None => None
    _ => raise wrong_type(path, key, "an array")
  }
}

///|
/// Read a required array-valued field with `read`.
fn[A] read_array(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
  read : (Json, @json.JsonPath) -> A raise @json.JsonDecodeError,
) -> Array[A] raise @json.JsonDecodeError {
  let items = need_array(fields, key, path)
  let out : Array[A] = []
  let mut index = 0
  for item in items {
    out.push(read(item, path.add_key(key).add_index(index)))
    index = index + 1
  }
  out
}
