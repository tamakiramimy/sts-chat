"""OpenAI-compatible local-first text generation with a safe pre-token fallback."""

from __future__ import annotations

import asyncio
import json
import os
from collections.abc import AsyncIterator
from dataclasses import dataclass

import httpx


class NoTokenReceived(RuntimeError):
    pass


@dataclass(frozen=True)
class ModelEndpoint:
    base_url: str
    model: str
    api_key: str | None = None

    @property
    def enabled(self) -> bool:
        return bool(self.base_url and self.model)


class ModelRouter:
    def __init__(self) -> None:
        self.local = ModelEndpoint(
            os.getenv("LLM_LOCAL_BASE_URL", "http://llama:8080/v1").rstrip("/"),
            os.getenv("LLM_LOCAL_MODEL", "Qwen2.5-3B-Instruct-Q4_K_M"),
        )
        self.cloud = ModelEndpoint(
            os.getenv("CLOUD_API_BASE_URL", "").rstrip("/"),
            os.getenv("CLOUD_API_MODEL", ""),
            os.getenv("CLOUD_API_KEY") or None,
        )
        self.timeout = float(os.getenv("LLM_LOCAL_TIMEOUT_SECONDS", "12"))

    async def stream(self, messages: list[dict[str, str]], cancel: asyncio.Event) -> AsyncIterator[str]:
        try:
            async for token in self._stream_endpoint(self.local, messages, cancel, self.timeout):
                yield token
            return
        except NoTokenReceived:
            if not self.cloud.enabled:
                raise

        async for token in self._stream_endpoint(self.cloud, messages, cancel, 30):
            yield token

    async def _stream_endpoint(
        self,
        endpoint: ModelEndpoint,
        messages: list[dict[str, str]],
        cancel: asyncio.Event,
        timeout_seconds: float,
    ) -> AsyncIterator[str]:
        if not endpoint.enabled:
            raise NoTokenReceived("model endpoint is not configured")

        headers = {"Authorization": f"Bearer {endpoint.api_key}"} if endpoint.api_key else {}
        payload = {
            "model": endpoint.model,
            "messages": messages,
            "stream": True,
            "temperature": 0.4,
            "max_tokens": 300,
        }
        received_token = False
        proxy = os.getenv("HTTPS_PROXY") or None
        timeout = httpx.Timeout(timeout_seconds, connect=5)
        async with httpx.AsyncClient(timeout=timeout, proxy=proxy) as client:
            try:
                async with client.stream("POST", f"{endpoint.base_url}/chat/completions", json=payload, headers=headers) as response:
                    response.raise_for_status()
                    async for line in response.aiter_lines():
                        if cancel.is_set():
                            return
                        if not line.startswith("data: "):
                            continue
                        data = line[6:]
                        if data == "[DONE]":
                            return
                        choice = json.loads(data).get("choices", [{}])[0]
                        token = choice.get("delta", {}).get("content")
                        if token:
                            received_token = True
                            yield token
            except (httpx.HTTPError, json.JSONDecodeError) as exc:
                if not received_token:
                    raise NoTokenReceived(str(exc)) from exc
                raise

        if not received_token:
            raise NoTokenReceived("model ended before producing a token")
