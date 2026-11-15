"""An A2A agent served by the official Python SDK.

The interoperability run starts this and calls it with the MoonBit client, so the two
implementations meet on the wire rather than on the page. All three bindings: JSON-RPC and
HTTP+JSON on one port, gRPC on the next.
"""

import argparse
import asyncio
import contextlib
import logging
import sys

import grpc
import uvicorn

from fastapi import FastAPI

from a2a.server.agent_execution.agent_executor import AgentExecutor
from a2a.server.events.event_queue import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler, GrpcHandler
from a2a.server.routes import (
    add_a2a_routes_to_fastapi,
    create_agent_card_routes,
    create_jsonrpc_routes,
    create_rest_routes,
)
from a2a.server.tasks.inmemory_task_store import InMemoryTaskStore
from a2a.server.tasks.task_updater import TaskUpdater
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentInterface,
    AgentProvider,
    AgentSkill,
    Part,
    Task,
    TaskState,
    TaskStatus,
)
from a2a.types import a2a_pb2_grpc


logger = logging.getLogger("interop.server")

RPC_PATH = "/a2a/jsonrpc"
REST_PATH = "/a2a/rest"


class EchoAgent(AgentExecutor):
    """Answers with the text it was given, and reports each step as it takes it."""

    def __init__(self) -> None:
        self.running: set[str] = set()

    async def execute(self, context, event_queue: EventQueue) -> None:
        message = context.message
        task_id = context.task_id
        context_id = context.context_id
        if message is None or task_id is None or context_id is None:
            return
        self.running.add(task_id)
        await event_queue.enqueue_event(
            Task(
                id=task_id,
                context_id=context_id,
                status=TaskStatus(state=TaskState.TASK_STATE_SUBMITTED),
                history=[message],
            )
        )
        updater = TaskUpdater(
            event_queue=event_queue,
            task_id=task_id,
            context_id=context_id,
        )
        await updater.start_work()
        await updater.add_artifact(
            parts=[Part(text=f"python heard: {context.get_user_input()}")],
            name="reply",
            last_chunk=True,
        )
        if task_id in self.running:
            self.running.discard(task_id)
            await updater.complete()

    async def cancel(self, context, event_queue: EventQueue) -> None:
        task_id = context.task_id or ""
        self.running.discard(task_id)
        updater = TaskUpdater(
            event_queue=event_queue,
            task_id=task_id,
            context_id=context.context_id or "",
        )
        await updater.cancel()


def card_for(host: str, port: int) -> AgentCard:
    """The card a caller reads first: one interface per binding."""
    return AgentCard(
        name="Python echo",
        description="An agent from the official Python SDK that repeats what it is told.",
        provider=AgentProvider(
            organization="A2A interoperability run", url="https://example.com"
        ),
        version="1.0.0",
        capabilities=AgentCapabilities(streaming=True, push_notifications=True),
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        skills=[
            AgentSkill(
                id="echo",
                name="Echo",
                description="Repeats the text it is given.",
                tags=["echo"],
                examples=["hello"],
                input_modes=["text/plain"],
                output_modes=["text/plain"],
            )
        ],
        supported_interfaces=[
            AgentInterface(
                protocol_binding="JSONRPC",
                protocol_version="1.0",
                url=f"http://{host}:{port}{RPC_PATH}",
            ),
            AgentInterface(
                protocol_binding="HTTP+JSON",
                protocol_version="1.0",
                url=f"http://{host}:{port}{REST_PATH}",
            ),
            AgentInterface(
                protocol_binding="GRPC",
                protocol_version="1.0",
                url=f"{host}:{port + 1}",
            ),
        ],
    )


async def serve(host: str, port: int) -> None:
    card = card_for(host, port)
    handler = DefaultRequestHandler(
        agent_executor=EchoAgent(),
        task_store=InMemoryTaskStore(),
        agent_card=card,
    )
    app = FastAPI()
    add_a2a_routes_to_fastapi(
        app,
        agent_card_routes=create_agent_card_routes(agent_card=card),
        jsonrpc_routes=create_jsonrpc_routes(request_handler=handler, rpc_url=RPC_PATH),
        rest_routes=create_rest_routes(request_handler=handler, path_prefix=REST_PATH),
    )
    rpc = grpc.aio.server()
    a2a_pb2_grpc.add_A2AServiceServicer_to_server(GrpcHandler(request_handler=handler), rpc)
    rpc.add_insecure_port(f"{host}:{port + 1}")
    await rpc.start()
    server = uvicorn.Server(uvicorn.Config(app, host=host, port=port, log_level="warning"))
    print(f"agent card: http://{host}:{port}/.well-known/agent-card.json", flush=True)
    print(f"json-rpc:   http://{host}:{port}{RPC_PATH}", flush=True)
    print(f"http+json:  http://{host}:{port}{REST_PATH}", flush=True)
    print(f"grpc:       {host}:{port + 1}", flush=True)
    try:
        await server.serve()
    finally:
        await rpc.stop(None)


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    parser = argparse.ArgumentParser(description="An A2A agent from the official Python SDK")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8001)
    args = parser.parse_args()
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(serve(args.host, args.port))
    sys.exit(0)
