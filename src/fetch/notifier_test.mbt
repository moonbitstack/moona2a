///|
/// A registration with nothing but a URL.
fn plain_config() -> @moona2a.TaskPushConfig {
  @moona2a.TaskPushConfig::new("cfg-1", "t-1", "https://caller.example/hook")
}

///|
/// The value under `name`, when the header list has it.
fn header_of(headers : Array[(String, String)], name : String) -> String? {
  for (key, value) in headers {
    if key == name {
      return Some(value)
    }
  }
  None
}

///|
test "a delivery says what it carries" {
  let headers = @fetch.delivery_headers(plain_config())
  assert_eq(header_of(headers, "content-type"), Some("application/a2a+json"))
  // Nothing the caller did not name travels with it.
  assert_eq(header_of(headers, @fetch.token_header), None)
  assert_eq(header_of(headers, "authorization"), None)
}

///|
test "a registration's token travels in its own header" {
  let config = plain_config().with_token("s3cret")
  let headers = @fetch.delivery_headers(config)
  assert_eq(header_of(headers, @fetch.token_header), Some("s3cret"))
}

///|
test "named credentials travel as the scheme and the credentials" {
  let config = plain_config().authenticating(
    @moona2a.AuthenticationInfo::bearer("abc123"),
  )
  let headers = @fetch.delivery_headers(config)
  assert_eq(header_of(headers, "authorization"), Some("Bearer abc123"))
}

///|
test "a scheme with no credentials sends no authorization" {
  let config = plain_config().authenticating(@moona2a.AuthenticationInfo::{
    scheme: "Bearer",
    credentials: None,
  })
  let headers = @fetch.delivery_headers(config)
  assert_eq(header_of(headers, "authorization"), None)
}
