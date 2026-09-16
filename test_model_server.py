from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path
from unittest.mock import AsyncMock

import pytest

os.environ["H3_WORKFLOW_PATH"] = str(
    Path(__file__).parent / "workflows" / "minimax_h3_ref2va_api.json"
)

import model_server


class ConnectedRequest:
    async def is_disconnected(self) -> bool:
        return False


def test_model_server_defaults_are_latency_safe():
    workflow, metadata = model_server._patch_workflow(
        {
            "prompt": "Subtle natural movement",
            "duration_seconds": 5,
            "negative_prompt": "must remain unused",
        },
        "input.png",
        "defaults-test",
    )

    assert metadata["steps"] == 10
    assert metadata["scheduler"] == "beta"
    assert metadata["ref_image_size"] == "match"
    assert metadata["lora_strength"] == 0.7
    assert metadata["include_audio"] is True
    assert "must remain unused" not in str(workflow)


def test_comfy_history_is_split_into_structured_timings():
    base_seconds = 1_800_000_000.0
    history = {
        "status": {
            "messages": [
                ["execution_start", {"timestamp": (base_seconds + 1) * 1000}],
                ["executing", {"node": "1", "timestamp": (base_seconds + 2) * 1000}],
                ["executing", {"node": "2", "timestamp": (base_seconds + 4) * 1000}],
                ["executing", {"node": "13", "timestamp": (base_seconds + 5) * 1000}],
                ["executing", {"node": "14", "timestamp": (base_seconds + 15) * 1000}],
                ["executing", {"node": "15", "timestamp": (base_seconds + 18) * 1000}],
                ["executing", {"node": "16", "timestamp": (base_seconds + 20) * 1000}],
                ["executing", {"node": None, "timestamp": (base_seconds + 22) * 1000}],
            ]
        }
    }

    timings = model_server._extract_comfy_timings(history, base_seconds)

    assert timings == {
        "prompt_queue_seconds": 1.0,
        "model_load_seconds": 3.0,
        "sampling_seconds": 10.0,
        "vae_decode_seconds": 5.0,
    }


@pytest.mark.asyncio
async def test_interrupt_is_scoped_to_active_locked_generation(monkeypatch):
    posted_urls: list[str] = []

    class FakeResponse:
        def raise_for_status(self) -> None:
            return None

        def json(self):
            return {"queue_running": [], "queue_pending": []}

    class FakeClient:
        def __init__(self, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, traceback):
            return False

        async def post(self, url):
            posted_urls.append(url)
            return FakeResponse()

        async def get(self, url):
            return FakeResponse()

    monkeypatch.setattr(model_server.httpx, "AsyncClient", FakeClient)
    monkeypatch.setattr(model_server, "generation_lock", asyncio.Lock())

    async with model_server.generation_lock:
        model_server._set_active_generation("active-request", "prompt-123")
        assert not await model_server._interrupt_active_generation("other-request")
        assert await model_server._interrupt_active_generation("active-request")

    model_server._clear_active_generation("active-request")
    assert posted_urls == [f"{model_server.COMFY_URL}/interrupt"]


@pytest.mark.asyncio
async def test_cancelled_generation_interrupts_cleans_files_and_reraises(
    monkeypatch,
    tmp_path,
    caplog,
):
    input_dir = tmp_path / "input"
    output_dir = tmp_path / "output"
    input_dir.mkdir()
    output_dir.mkdir()
    request_id = "cancel-test"
    image_name = f"h3_{request_id}.png"
    input_path = input_dir / image_name
    partial_output = output_dir / "video" / "h3" / f"{request_id}_partial.mp4"

    async def fake_download(data, received_request_id):
        assert received_request_id == request_id
        input_path.write_bytes(b"input")
        return image_name

    async def fake_submit(workflow, received_request_id, request):
        assert received_request_id == request_id
        partial_output.parent.mkdir(parents=True)
        partial_output.write_bytes(b"partial")
        model_server._set_active_generation(request_id, "prompt-cancelled")
        raise asyncio.CancelledError

    interrupt = AsyncMock(return_value=True)
    monkeypatch.setattr(model_server, "INPUT_DIR", input_dir)
    monkeypatch.setattr(model_server, "OUTPUT_DIR", output_dir)
    monkeypatch.setattr(model_server, "KEEP_LOCAL_OUTPUTS", True)
    monkeypatch.setattr(model_server, "generation_lock", asyncio.Lock())
    monkeypatch.setattr(model_server, "_s3_output_config", lambda: ("bucket", "prefix", 3600))
    monkeypatch.setattr(model_server, "_download_input_image", fake_download)
    monkeypatch.setattr(model_server, "_submit_and_wait", fake_submit)
    monkeypatch.setattr(model_server, "_interrupt_active_generation", interrupt)

    envelope = model_server.GenerateEnvelope(
        input={
            "request_id": request_id,
            "prompt": "Subtle motion",
            "duration_seconds": 5,
            "width": 480,
            "height": 864,
            "steps": 8,
            "scheduler": "beta",
        }
    )

    with caplog.at_level(logging.INFO, logger="rosely-minimax-h3"):
        with pytest.raises(asyncio.CancelledError):
            await model_server.generate_sync(envelope, ConnectedRequest())

    interrupt.assert_awaited_once_with(request_id)
    assert not input_path.exists()
    assert not partial_output.exists()
    assert model_server.active_generation is None
    assert not model_server.generation_lock.locked()
    assert (
        f"request={request_id} cancelled; interrupting ComfyUI"
        in caplog.text
    )
    assert "generation_timings" in caplog.text
