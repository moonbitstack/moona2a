// The demo engine for the documentation site's star page.
//
// A foreign library: it re-exposes the library to JavaScript, so the page shows what the protocol
// actually encodes rather than a hand-written imitation of it. Every function returns a String —
// records separated by \x1e, fields within a record by \x1f — so the page never meets a MoonBit
// type, an error, or an array.
//
// Built with `moon build --target js --release src/examples/browser`.

///|
/// The record and field separators, which the page splits on.
let record_separator : String = "\u{1e}"

///|
let field_separator : String = "\u{1f}"

///|
/// One agent of the star: the five spokes and the hub that convenes them.
pub(all) struct Agent {
  id : String
  name : String
  role : String
  skill : String
  title : String
  description : String
  tags : Array[String]
  streaming : Bool
  push : Bool
}

///|
fn agents() -> Array[Agent] {
  [
    {
      id: "convener",
      name: "Convener",
      role: "hub",
      skill: "orchestrate",
      title: "Orchestrate",
      description: "Holds the star: takes a goal, hands each part to a spoke, and keeps the task's history in one place.",
      tags: ["orchestration", "tasks"],
      streaming: true,
      push: true,
    },
    {
      id: "planner",
      name: "Planner",
      role: "spoke",
      skill: "decompose",
      title: "Decompose",
      description: "Turns a goal into steps and stops for a decision when the next step depends on one.",
      tags: ["planning", "multi-turn"],
      streaming: true,
      push: false,
    },
    {
      id: "archivist",
      name: "Archivist",
      role: "spoke",
      skill: "write",
      title: "Write",
      description: "Writes the result as an artifact, in chunks, so a reader sees the document grow.",
      tags: ["artifacts", "streaming"],
      streaming: true,
      push: false,
    },
    {
      id: "herald",
      name: "Herald",
      role: "spoke",
      skill: "report",
      title: "Report",
      description: "Reports progress to a webhook the caller registered, authenticated the way the registration says.",
      tags: ["push", "webhooks"],
      streaming: false,
      push: true,
    },
    {
      id: "sentinel",
      name: "Sentinel",
      role: "spoke",
      skill: "watch",
      title: "Watch",
      description: "Watches a run and stops it when asked, or says why it cannot be stopped.",
      tags: ["cancellation"],
      streaming: true,
      push: false,
    },
    {
      id: "scout",
      name: "Scout",
      role: "spoke",
      skill: "discover",
      title: "Discover",
      description: "Publishes what the star can do: one card, two interfaces, the skills behind them.",
      tags: ["discovery", "cards"],
      streaming: false,
      push: false,
    },
  ]
}

///|
fn agent_of(id : String) -> Agent {
  for agent in agents() {
    if agent.id == id {
      return agent
    }
  }
  agents()[0]
}

///|
/// The card an agent publishes, as the protocol writes it.
fn card_of_agent(agent : Agent) -> @moona2a.AgentCard {
  @moona2a.AgentCard::new(
    agent.name,
    agent.description,
    "1.0.0",
    "https://\{agent.id}.hive.example/a2a",
    [
      @moona2a.AgentSkill::new(
        agent.skill,
        agent.title,
        agent.description,
        agent.tags,
      ),
    ],
  ).capable({
    streaming: agent.streaming,
    push_notifications: agent.push,
    extended_agent_card: agent.id == "scout",
    extensions: [],
  })
}

///|
/// The card of the agent named `id`, indented for reading.
#export_name("card")
pub fn demo_card(id : String) -> String {
  card_of_agent(agent_of(id)).to_json().stringify(indent=2)
}

///|
/// Every agent of the star, one record each: id, name, role, skill, description, tags, streaming,
/// push. The page draws the star from this rather than from numbers written into the HTML.
#export_name("agents")
pub fn demo_agents() -> String {
  let records : Array[String] = []
  for agent in agents() {
    records.push(
      [
        agent.id,
        agent.name,
        agent.role,
        agent.skill,
        agent.description,
        agent.tags.join(","),
        if agent.streaming {
          "1"
        } else {
          "0"
        },
        if agent.push {
          "1"
        } else {
          "0"
        },
      ].join(field_separator),
    )
  }
  records.join(record_separator)
}

///|
/// The protocol exchange for one turn with an agent, as frames.
///
/// Each frame is `kind`, a separator, and the JSON-RPC envelope the protocol puts on the wire:
/// `request` for what the caller sends, `event` for one streamed result, `reply` for a single
/// result, `error` for a refusal.
#export_name("trace")
pub fn demo_trace(id : String, text : String) -> String {
  let agent = agent_of(id)
  let message = @moona2a.Message::user("m-1", text)
  let frames : Array[String] = []
  let push = fn(kind : String, envelope : @moonjrpc.Message) {
    frames.push(kind + field_separator + envelope.to_json().stringify(indent=2))
  }
  match agent.id {
    "herald" => {
      let config = @moona2a.TaskPushConfig::new(
        "cfg-1", "t-1", "https://caller.example/hook",
      ).with_token("s3cret")
      push(
        "request",
        @moonjrpc.Message::Call(
          id=@moonjrpc.Id::int(1),
          name="CreateTaskPushNotificationConfig",
          params=Some(
            Json::object({
              "taskId": Json::string("t-1"),
              "config": config.to_json(),
            }),
          ),
        ),
      )
      push(
        "reply",
        @moonjrpc.Message::Reply(
          id=@moonjrpc.Id::int(1),
          result=config.to_json(),
        ),
      )
    }
    "sentinel" => {
      push(
        "request",
        @moonjrpc.Message::Call(
          id=@moonjrpc.Id::int(2),
          name="CancelTask",
          params=Some(Json::object({ "id": Json::string("t-1") })),
        ),
      )
      let update = @moona2a.TaskStatusUpdate::of("t-1", "c-1", Canceled)
      push(
        "event",
        @moonjrpc.Message::Reply(
          id=@moonjrpc.Id::int(2),
          result=Json::object({ "statusUpdate": update.to_json() }),
        ),
      )
    }
    "scout" => {
      push(
        "request",
        @moonjrpc.Message::Call(
          id=@moonjrpc.Id::int(3),
          name="GetExtendedAgentCard",
          params=Some(Json::object({})),
        ),
      )
      push(
        "reply",
        @moonjrpc.Message::Reply(
          id=@moonjrpc.Id::int(3),
          result=card_of_agent(agent).to_json(),
        ),
      )
    }
    _ => {
      let request = @moona2a.SendMessageRequest::new(message)
      push(
        "request",
        @moonjrpc.Message::Call(
          id=@moonjrpc.Id::int(1),
          name="SendStreamingMessage",
          params=Some(request.to_json()),
        ),
      )
      let task = @moona2a.Task::new("t-1", "c-1")
        .saying(message)
        .with_state(@moona2a.Submitted)
      push(
        "event",
        @moonjrpc.Message::Reply(
          id=@moonjrpc.Id::int(1),
          result=Json::object({ "task": task.to_json() }),
        ),
      )
      push(
        "event",
        @moonjrpc.Message::Reply(
          id=@moonjrpc.Id::int(1),
          result=Json::object({
            "statusUpdate": @moona2a.TaskStatusUpdate::of("t-1", "c-1", Working).to_json(),
          }),
        ),
      )
      if agent.id == "archivist" {
        let first = @moona2a.TaskArtifactUpdate::of(
          "t-1",
          "c-1",
          @moona2a.Artifact::text("a-1", "## The comb\n"),
          append=true,
          last_chunk=false,
        )
        push(
          "event",
          @moonjrpc.Message::Reply(
            id=@moonjrpc.Id::int(1),
            result=Json::object({ "artifactUpdate": first.to_json() }),
          ),
        )
        let second = @moona2a.TaskArtifactUpdate::of(
          "t-1",
          "c-1",
          @moona2a.Artifact::text("a-1", "Every cell is a task.\n"),
          append=true,
          last_chunk=true,
        )
        push(
          "event",
          @moonjrpc.Message::Reply(
            id=@moonjrpc.Id::int(1),
            result=Json::object({ "artifactUpdate": second.to_json() }),
          ),
        )
      } else if agent.id == "planner" {
        let question = @moona2a.Message::agent(
          "m-2", "Two ways to split this. Which one?",
        )
        let asking : @moona2a.TaskStatusUpdate = {
          task_id: "t-1",
          context_id: "c-1",
          status: {
            ..@moona2a.TaskStatus::recorded(InputRequired),
            message: Some(question),
          },
          metadata: None,
        }
        push(
          "event",
          @moonjrpc.Message::Reply(
            id=@moonjrpc.Id::int(1),
            result=Json::object({ "statusUpdate": asking.to_json() }),
          ),
        )
      } else {
        push(
          "event",
          @moonjrpc.Message::Reply(
            id=@moonjrpc.Id::int(1),
            result=Json::object({
              "statusUpdate": @moona2a.TaskStatusUpdate::of(
                "t-1",
                "c-1",
                Completed,
              ).to_json(),
            }),
          ),
        )
      }
    }
  }
  frames.join(record_separator)
}

///|
/// The states a task can be in, in the protocol's own words, with what each means. The page draws
/// the lifecycle from this.
#export_name("states")
pub fn demo_states() -> String {
  let rows : Array[(String, String)] = [
    ("TASK_STATE_SUBMITTED", "the task exists; the agent has not started"),
    ("TASK_STATE_WORKING", "the agent is on it"),
    ("TASK_STATE_INPUT_REQUIRED", "the agent needs a decision to go on"),
    ("TASK_STATE_AUTH_REQUIRED", "the caller has to authenticate to go on"),
    ("TASK_STATE_COMPLETED", "done, and its artifacts are there to read"),
    (
      "TASK_STATE_FAILED", "the run broke; the task stays, so a watcher can stop",
    ),
    ("TASK_STATE_CANCELED", "the caller asked it to stop, and it did"),
    ("TASK_STATE_REJECTED", "the agent would not take it at all"),
  ]
  let records : Array[String] = []
  for (name, meaning) in rows {
    records.push(name + field_separator + meaning)
  }
  records.join(record_separator)
}
