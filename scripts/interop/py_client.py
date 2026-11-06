"""Call the MoonBit agent with the official Python SDK.

One run in each direction: this script reads the card the MoonBit server publishes, sends a
message without streaming, sends one with streaming, and reads the task back. The assertions are
the point — a run that prints but does not check proves nothing.
"""

import argparse
import asyncio
import sys

import httpx

from a2a.client import A2ACardResolver, ClientConfig, ClientFactory
from a2a.types import (
    GetTaskRequest,
    Message,
    Part,
    Role,
    SendMessageRequest,
    TaskState,
)


def fail(what: str) -> None:
    print(f"  FAIL {what}", flush=True)
    raise SystemExit(1)


def user_message(message_id: str, text: str) -> SendMessageRequest:
    return SendMessageRequest(
        message=Message(
            message_id=message_id,
            role=Role.ROLE_USER,
            parts=[Part(text=text)],
        )
    )


async def collect(client, request) -> list:
    """Every event a send produces, in order."""
    return [event async for event in client.send_message(request)]


def task_of(events: list):
    """The task an event stream opened with, or None."""
    for event in events:
        if event.WhichOneof("payload") == "task":
            return event.task
    return None


async def main(base_url: str) -> int:
    async with httpx.AsyncClient(timeout=20.0) as http:
        card = await A2ACardResolver(http, base_url).get_agent_card()
        bindings = [i.protocol_binding for i in card.supported_interfaces]
        print(f"card: {card.name} {card.version}, {bindings}", flush=True)
        if "JSONRPC" not in bindings:
            fail("the card declares no JSON-RPC interface")

        unary = ClientFactory(ClientConfig(streaming=False)).create(card)
        events = await collect(unary, user_message("interop-unary", "hello from Python"))
        task = task_of(events)
        if task is None:
            fail("an unary send did not open a task")
        state = TaskState.Name(task.status.state)
        print(f"unary: task {task.id} {state}", flush=True)
        if task.status.state != TaskState.TASK_STATE_COMPLETED:
            fail(f"the task finished {state}")
        if not task.history:
            fail("the task kept no history")
        if task.history[0].parts[0].text != "hello from Python":
            fail(f"the task opens with {task.history[0].parts[0].text!r}")
        # The agent's own words travel on the terminal status, as the reference server sends them.
        if task.status.message.parts[0].text != "Hello from TCK":
            fail(f"the agent said {task.status.message.parts[0].text!r}")

        streaming = ClientFactory(ClientConfig(streaming=True)).create(card)
        events = await collect(streaming, user_message("interop-stream", "hello again"))
        states = [
            event.status_update.status.state
            for event in events
            if event.WhichOneof("payload") == "status_update"
        ]
        print(f"stream: {len(events)} events, {[TaskState.Name(s) for s in states]}", flush=True)
        if not states or states[-1] != TaskState.TASK_STATE_COMPLETED:
            fail("the stream did not end at TASK_STATE_COMPLETED")
        if TaskState.TASK_STATE_WORKING not in states:
            fail("the stream carried no working state")

        read = await streaming.get_task(GetTaskRequest(id=task_of(events).id))
        print(
            f"get_task: {TaskState.Name(read.status.state)}, {len(read.history)} messages",
            flush=True,
        )
        if read.status.state != TaskState.TASK_STATE_COMPLETED:
            fail("the task reads back as unfinished")

    print("python client: ok", flush=True)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Call a MoonBit agent with the Python SDK")
    parser.add_argument("--url", default="http://127.0.0.1:9999")
    args = parser.parse_args()
    sys.exit(asyncio.run(main(args.url)))
