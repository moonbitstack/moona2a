"""Call the MoonBit agent with the official Python SDK, over one binding.

This script reads the card the MoonBit server publishes, picks the interface of the binding it
was asked for, sends a message without streaming, sends one with streaming, reads the task back,
and checks that two refusals arrive as the errors the specification names. The assertions are the
point: a run that prints but does not check proves nothing.
"""

import argparse
import asyncio
import sys

import grpc
import httpx

from a2a.client import A2ACardResolver, ClientConfig, ClientFactory
from a2a.types import (
    CancelTaskRequest,
    GetTaskRequest,
    Message,
    Part,
    Role,
    SendMessageRequest,
    TaskState,
)
from a2a.utils.errors import TaskNotCancelableError, TaskNotFoundError


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


def config(binding: str, streaming: bool, http: httpx.AsyncClient) -> ClientConfig:
    """A client that speaks `binding` alone, so the card's other interfaces cannot stand in."""
    return ClientConfig(
        streaming=streaming,
        httpx_client=http,
        supported_protocol_bindings=[binding],
        grpc_channel_factory=grpc.aio.insecure_channel,
    )


async def main(base_url: str, binding: str) -> int:
    async with httpx.AsyncClient(timeout=20.0) as http:
        card = await A2ACardResolver(http, base_url).get_agent_card()
        bindings = [i.protocol_binding for i in card.supported_interfaces]
        print(f"card: {card.name} {card.version}, {bindings}; speaking {binding}", flush=True)
        if binding not in bindings:
            fail(f"the card declares no {binding} interface")

        unary = ClientFactory(config(binding, False, http)).create(card)
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

        streaming = ClientFactory(config(binding, True, http)).create(card)
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

        try:
            await unary.get_task(GetTaskRequest(id="interop-no-such-task"))
            fail("an unknown task was found")
        except TaskNotFoundError:
            print("refusal: an unknown task is TaskNotFoundError", flush=True)
        try:
            await unary.cancel_task(CancelTaskRequest(id=read.id))
            fail("a finished task was cancelled")
        except TaskNotCancelableError:
            print("refusal: a finished task is TaskNotCancelableError", flush=True)

    print(f"python client over {binding}: ok", flush=True)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Call a MoonBit agent with the Python SDK")
    parser.add_argument("--url", default="http://127.0.0.1:9999")
    parser.add_argument("--binding", default="JSONRPC", choices=["JSONRPC", "HTTP+JSON", "GRPC"])
    args = parser.parse_args()
    sys.exit(asyncio.run(main(args.url, args.binding)))
