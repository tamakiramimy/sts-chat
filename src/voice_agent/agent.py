"""LiveKit worker for turn state, local-first LLM routing and interruption.

The production ASR/TTS adapters are intentionally process-isolated: SenseVoice and
Piper can be upgraded independently without changing the public LiveKit protocol.
This worker already consumes client text turns and emits the canonical data events;
the `VoicePipeline` adapter is the sole extension point for live audio tracks.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from typing import Coroutine

from livekit import agents, rtc

from model_router import ModelRouter, NoTokenReceived
from safety import build_messages

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("sts_chat_agent")


class HealthRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler requires this name.
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"healthy","component":"voice-agent"}')
            return
        self.send_error(404)

    def log_message(self, format: str, *args: object) -> None:
        return


def start_health_server() -> None:
    host = os.getenv("VOICE_AGENT_HEALTH_HOST", "0.0.0.0")
    port = int(os.getenv("VOICE_AGENT_HEALTH_PORT", "8082"))
    server = ThreadingHTTPServer((host, port), HealthRequestHandler)
    Thread(target=server.serve_forever, name="voice-agent-health", daemon=True).start()


@dataclass
class Turn:
    cancel: asyncio.Event
    recipient_identity: str
    task: asyncio.Task[None] | None = None


async def publish(room: rtc.Room, event_type: str, *, destination_identities: list[str] | None = None, **payload: object) -> None:
    message = json.dumps({"type": event_type, **payload}, ensure_ascii=False).encode("utf-8")
    await room.local_participant.publish_data(
        message,
        reliable=True,
        destination_identities=destination_identities or [],
        topic="sts-chat-events",
    )


class VoiceSession:
    def __init__(self, room: rtc.Room) -> None:
        self.room = room
        self.router = ModelRouter()
        self.current: Turn | None = None

    async def interrupt(self, recipient_identity: str | None = None) -> None:
        if self.current is None:
            if recipient_identity is not None:
                await publish(self.room, "agent_state", destination_identities=[recipient_identity], state="listening")
            return
        recipient = self.current.recipient_identity
        self.current.cancel.set()
        if self.current.task is not None:
            self.current.task.cancel()
            try:
                await self.current.task
            except asyncio.CancelledError:
                pass
        self.current = None
        await publish(self.room, "interrupted", destination_identities=[recipient])
        await publish(self.room, "agent_state", destination_identities=[recipient], state="listening")

    async def answer(self, question: str, recipient_identity: str) -> None:
        await self.interrupt()
        turn = Turn(cancel=asyncio.Event(), recipient_identity=recipient_identity)
        self.current = turn
        turn.task = asyncio.current_task()
        destinations = [recipient_identity]
        await publish(self.room, "transcript_final", destination_identities=destinations, text=question)
        await publish(self.room, "agent_state", destination_identities=destinations, state="thinking")
        answer_parts: list[str] = []
        try:
            async for token in self.router.stream(build_messages(question), turn.cancel):
                if turn.cancel.is_set():
                    return
                answer_parts.append(token)
                await publish(self.room, "answer_delta", text=token)
            if not turn.cancel.is_set():
                await publish(self.room, "answer_final", destination_identities=destinations, text="".join(answer_parts))
                await publish(self.room, "agent_state", destination_identities=destinations, state="speaking")
                # Piper audio is published by the audio adapter after this event.
        except NoTokenReceived:
            await publish(self.room, "error", destination_identities=destinations, code="model_unavailable", message="现在不能回答，请稍后再试。")
            await publish(self.room, "agent_state", destination_identities=destinations, state="listening")
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Turn failed")
            await publish(self.room, "error", destination_identities=destinations, code="turn_failed", message="这次没有听清楚，请再问一次。")
            await publish(self.room, "agent_state", destination_identities=destinations, state="listening")
        finally:
            if self.current is turn:
                self.current = None


async def entrypoint(job: agents.JobContext) -> None:
    await job.connect(auto_subscribe=agents.AutoSubscribe.SUBSCRIBE_ALL)
    session = VoiceSession(job.room)
    loop = asyncio.get_running_loop()

    def schedule(coroutine: Coroutine[object, object, None]) -> None:
        def create_task() -> None:
            task = asyncio.create_task(coroutine)
            task.add_done_callback(log_task_exception)

        loop.call_soon_threadsafe(create_task)

    def log_task_exception(task: asyncio.Task[None]) -> None:
        if task.cancelled():
            return
        exception = task.exception()
        if exception is not None:
            logger.exception("Client event task failed", exc_info=exception)

    @job.room.on("data_received")
    def on_data(packet: rtc.DataPacket) -> None:
        if packet.topic != "sts-chat-turns":
            return
        try:
            event = json.loads(packet.data.decode("utf-8"))
            event_type = event.get("type")
            if event_type == "session.ready":
                schedule(publish(job.room, "agent_state", destination_identities=[packet.participant.identity], state="idle"))
            elif event_type == "turn.text" and isinstance(event.get("text"), str):
                schedule(session.answer(event["text"], packet.participant.identity))
            elif event_type == "barge_in":
                schedule(session.interrupt(packet.participant.identity))
        except (UnicodeDecodeError, json.JSONDecodeError):
            logger.warning("Ignoring malformed client data event")
        except Exception:
            logger.exception("Unable to process client data event")

    await publish(job.room, "agent_state", state="idle")
    await asyncio.Future()


if __name__ == "__main__":
    start_health_server()
    agents.cli.run_app(
        agents.WorkerOptions(
            entrypoint_fnc=entrypoint,
            agent_name="sts-chat-agent",
            num_idle_processes=1,
        )
    )
