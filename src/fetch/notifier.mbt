// Push notifications over HTTP: the agent posts each task update to the webhook the caller left,
// authenticated the way the registration says.

///|
/// A notifier that posts to whatever URL a registration names.
pub(all) struct Webhook {}

///|
/// How the token in a registration travels, when the caller set one. The specification names the
/// field but not the header, so this is the name the rest of the ecosystem uses.
pub let token_header : String = "x-a2a-notification-token"

///|
/// How long to wait for the caller's webhook before giving up on this delivery. Section 4.3.3
/// suggests ten to thirty seconds; ten keeps a slow webhook from holding a task's run.
pub let webhook_timeout_millis : Int32 = 10000

///|
/// The headers a delivery goes out under: the payload type, the registration's token, and the
/// credentials it names. Separate from the send so the part a caller cares about can be read
/// without a webhook to read it from.
pub fn delivery_headers(
  config : @moona2a.TaskPushConfig,
) -> Array[(String, String)] {
  let headers : Array[(String, String)] = [
    ("content-type", "application/a2a+json"),
  ]
  match config.token {
    Some(token) => headers.push((token_header, token))
    None => ()
  }
  match config.authentication {
    Some(authentication) =>
      match authentication.credentials {
        Some(credentials) =>
          headers.push(
            ("authorization", "\{authentication.scheme} \{credentials}"),
          )
        None => ()
      }
    None => ()
  }
  headers
}

///|
pub impl @moona2a.Notifier for Webhook with fn notify(self, config, event) {
  ignore(self)
  let headers = delivery_headers(config)
  let response = @moonfetch.post(
    config.url,
    body=@moonfetch.Body::Text(event.to_json().stringify()),
    headers~,
    timeout=webhook_timeout_millis,
  )
  if !response.is_success() {
    raise Unreachable("\{config.url} answered \{response.status}")
  }
}

///|
/// A webhook that did not take the delivery.
pub suberror Unreachable {
  Unreachable(String)
}

///|
pub extend Webhook with @moona2a.Notifier::{notify}
