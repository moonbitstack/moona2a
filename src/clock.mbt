// The one clock reading the protocol needs: a task status timestamp in UTC, to the millisecond,
// which is what the specification asks a JSON binding to write.

///|
/// The current instant as an ISO 8601 timestamp in UTC, e.g. `2026-11-06T02:02:55.123Z`.
///
/// Millisecond precision is what the specification asks for and all `@env.now` offers on every
/// backend; a timestamp that is a few milliseconds coarse still orders correctly.
pub fn timestamp_now() -> String {
  let millis = @env.now().reinterpret_as_int64()
  let seconds = millis / 1000L
  let nano = (millis % 1000L).to_int() * 1000000
  @moondate.Moment::of_epoch(seconds, nano~, zone=@moondate.Zone::Utc).layout(
    "2006-01-02T15:04:05.000Z07:00",
  )
}
