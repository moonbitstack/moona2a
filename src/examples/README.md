# Examples

| # | Example | What it shows |
|:--:|:--|:--|
| 01 | [`card`](01-card/) | The agent card as JSON: interfaces, capabilities, skills, and what a client reads first |
| 02 | [`client`](02-client/) | A client calling `SendMessage` over a transport that answers from a table |
| 03 | [`server`](03-server/) | A server answering a `SendMessage` body and folding what the agent says into a task |
| 04 | [`stream`](04-stream/) | A streaming answer, one event at a time, into a sink that prints as it goes |
| 05 | [`conformance`](05-conformance/) | The server the conformance suite drives: an agent that answers the suite's message ids, served over HTTP |
| 06 | [`interop`](06-interop/) | A client calling an agent that is already running: card, message, stream, over HTTP |

Examples 01 to 04 print and exit; 05 and 06 have to be pointed at something — 05 is a server and
runs until it is stopped, 06 takes the endpoint of one that is already up.
