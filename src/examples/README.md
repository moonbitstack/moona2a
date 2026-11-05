# Examples

| # | Example | What it shows |
|:--:|:--|:--|
| 01 | [`card`](01-card/) | The Agent-to-Agent `AgentCard`: transports, provider, skills, capabilities — round-tripped through its wire JSON and fetched by `resolve_agent_card` |
| 02 | [`protocol`](02-protocol/) | The A2A JSON-RPC protocol end to end over a real `A2AServer`: `message/send`, `tasks/get`, `tasks/cancel`, push configs, `parse_sse`, and `stream_message` into typed events |
