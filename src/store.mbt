// Where a server keeps its tasks between requests, and where it hands the events of a running task
// to whoever is watching.

///|
/// The storage a server needs. A store only has to remember tasks; the server decides what goes in
/// them. Implement this to keep tasks in memory, on disk, or in a database.
pub(open) trait TaskStore {
  /// The task with `id`, when this store has it.
  fn get(Self, id : String) -> Task?
  /// Remember `task`, replacing any earlier copy with the same id.
  fn put(Self, task : Task) -> Unit
  /// Every task this store holds, in no particular order.
  fn all(Self) -> Array[Task]
  /// Forget the task with `id`.
  fn remove(Self, id : String) -> Unit
}

///|
/// How many tasks an in-memory store keeps before it starts forgetting the ones that finished.
/// 1024 is enough for a session's worth of work and small enough that a forgotten task cannot grow
/// without bound.
pub let default_capacity : Int32 = 1024

///|
/// A store that keeps tasks in memory, good for a single process and a bounded session.
pub struct MemoryStore {
  tasks : Map[String, Task]
  mut order : Array[String]
  capacity : Int32
}

///|
/// An empty store holding up to `capacity` tasks.
pub fn MemoryStore::new(capacity? : Int32) -> MemoryStore {
  { tasks: Map([]), order: [], capacity: capacity.unwrap_or(default_capacity), }
}

///|
/// Make room for one more task by forgetting the oldest task that has finished. A store full of
/// running tasks forgets nothing: dropping a task a caller is watching would be worse than growing.
fn MemoryStore::make_room(self : MemoryStore) -> Unit {
  if self.order.length() < self.capacity {
    return
  }
  let kept : Array[String] = []
  let mut dropped = false
  for id in self.order {
    let finished = match self.tasks.get(id) {
      Some(task) => task.status.state.terminal()
      None => true
    }
    if !dropped && finished {
      dropped = true
      self.tasks.remove(id)
    } else {
      kept.push(id)
    }
  }
  self.order = kept
}

///|
pub impl TaskStore for MemoryStore with fn get(self, id) {
  self.tasks.get(id)
}

///|
pub impl TaskStore for MemoryStore with fn put(self, task) {
  if !self.tasks.contains(task.id) {
    self.make_room()
    self.order.push(task.id)
  }
  self.tasks[task.id] = task
}

///|
pub impl TaskStore for MemoryStore with fn all(self) {
  let out : Array[Task] = []
  for id in self.order {
    match self.tasks.get(id) {
      Some(task) => out.push(task)
      None => ()
    }
  }
  out
}

///|
pub impl TaskStore for MemoryStore with fn remove(self, id) {
  self.tasks.remove(id)
  let kept : Array[String] = []
  for kept_id in self.order {
    if kept_id != id {
      kept.push(kept_id)
    }
  }
  self.order = kept
}

///|
/// Somewhere for a running task's events to go: a streamed response, a webhook, or a test's
/// notebook.
pub(open) trait EventSink {
  /// Take one event. Raising here stops the task's run, which is what a client that has gone away
  /// deserves.
  async fn emit(Self, StreamEvent) -> Unit
}

///|
/// A sink that keeps every event it is handed, for a caller that waits for the whole answer.
pub struct Collected {
  taken : Array[StreamEvent]
}

///|
/// An empty collection.
pub fn Collected::new() -> Collected {
  { taken: [], }
}

///|
/// The events the sink took, in the order they happened.
pub fn Collected::events(self : Collected) -> Array[StreamEvent] {
  self.taken
}

///|
/// The message the agent answered with directly, when the run produced one instead of a task.
pub fn Collected::message(self : Collected) -> Message? {
  for event in self.taken {
    guard event is TaskMessage(message) else { continue }
    return Some(message)
  }
  None
}

///|
pub impl EventSink for Collected with fn emit(self, event) {
  self.taken.push(event)
}

///|
/// One task's events, kept in the order they happened, for subscribers who arrived late or twice.
pub struct TaskLog {
  events : Array[StreamEvent]
  mut open : Bool
}

///|
/// An empty log for a task that has not finished.
pub fn TaskLog::new() -> TaskLog {
  { events: [], open: true, }
}

///|
/// How long a follower waits between looks at the log it is watching.
///
/// The log is the ordering guarantee, not the wake-up: a follower reads forward from its own
/// cursor, so it sees every event once, in order, whether it woke on the first tick or the fifth.
/// 25 milliseconds is short enough that a stream feels live and long enough that an idle
/// subscription costs nothing worth measuring.
pub let follow_tick_millis : Int32 = 25

///|
pub extend MemoryStore with TaskStore::{get, put, all, remove}

///|
pub extend Collected with EventSink::{emit}
