// Publish a card: the document a caller reads before it talks to the agent.

///|
fn main {
  let skill = @moona2a.AgentSkill::new(
    "summarise",
    "Summarise",
    "condenses a document into a short paragraph",
    ["text", "summarise"],
  )
  let card = @moona2a.AgentCard::new(
    "summariser",
    "An agent that condenses documents",
    "1.0.0",
    "https://summariser.example.com",
    [skill],
  ).capable({
    streaming: true,
    push_notifications: false,
    extended_agent_card: false,
    extensions: [],
  })
  println(card.to_json().stringify(indent=2))
}
