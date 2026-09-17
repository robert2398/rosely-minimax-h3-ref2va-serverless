from __future__ import annotations

import base64
import os
from io import BytesIO
from typing import Any

from PIL import Image, ImageDraw
from vastai import BenchmarkConfig, HandlerConfig, LogActionConfig, Worker, WorkerConfig

MODEL_SERVER_URL = "http://127.0.0.1"
MODEL_SERVER_PORT = 18288
MODEL_LOG_FILE = "/var/log/portal/comfyui.log"
MODEL_HEALTHCHECK_ENDPOINT = "/health"

MODEL_LOAD_LOG_MSGS = [
    "To see the GUI go to:",
]

MODEL_ERROR_LOG_MSGS = [
    "torch.OutOfMemoryError",
    "CUDA out of memory",
    "CUDA error: an illegal memory access was encountered",
    "ERROR UNSUPPORTED UNET",
    "MetadataIncompleteBuffer",
    "Value not in list:",
]

MODEL_INFO_LOG_MSGS = [
    "Requested to load",
    "loaded completely",
    "loaded partially",
]


def _workload(payload: dict[str, Any]) -> float:
    data = payload.get("input", payload)
    width = float(data.get("width", 480))
    height = float(data.get("height", 864))
    if data.get("length") is not None:
        frames = float(data["length"])
    else:
        frames = max(5.0, float(data.get("duration_seconds", 5.0)) * 24.0)
    steps = float(data.get("steps", 8))
    return max(1.0, width * height * frames * steps / 100_000_000.0)


def _benchmark_image() -> str:
    image = Image.new("RGB", (256, 256), (226, 229, 235))
    draw = ImageDraw.Draw(image)
    draw.ellipse((70, 35, 186, 151), fill=(191, 148, 118))
    draw.rectangle((85, 145, 171, 238), fill=(72, 103, 154))
    draw.ellipse((103, 78, 113, 88), fill=(30, 30, 30))
    draw.ellipse((143, 78, 153, 88), fill=(30, 30, 30))
    buf = BytesIO()
    image.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


_benchmark_worker_id = (
    os.getenv("CONTAINER_ID")
    or os.getenv("INSTANCE_ID")
    or os.getenv("HOSTNAME")
    or "worker"
)

benchmark_dataset = [
    {
        "input": {
            "request_id": f"vast-benchmark-minimax-h3-{_benchmark_worker_id}",
            "input_image_base64": _benchmark_image(),
            "prompt": (
                "Preserve <Picture 1>. Tiny natural head movement, stable camera, "
                "coherent identity and geometry."
            ),
            "width": 256,
            "height": 256,
            "length": 5,
            "steps": 4,
            "scheduler": "simple",
            "ref_image_size": "match",
            "include_audio": False,
            "seed": 12345,
        }
    }
]

worker_config = WorkerConfig(
    model_server_url=MODEL_SERVER_URL,
    model_server_port=MODEL_SERVER_PORT,
    model_log_file=MODEL_LOG_FILE,
    model_healthcheck_url=MODEL_HEALTHCHECK_ENDPOINT,
    handlers=[
        HandlerConfig(
            route="/generate/sync",
            allow_parallel_requests=False,
            max_queue_time=4200.0,
            workload_calculator=_workload,
            benchmark_config=BenchmarkConfig(
                dataset=benchmark_dataset,
                runs=1,
                concurrency=1,
                do_warmup=False,
            ),
        )
    ],
    log_action_config=LogActionConfig(
        on_load=MODEL_LOAD_LOG_MSGS,
        on_error=MODEL_ERROR_LOG_MSGS,
        on_info=MODEL_INFO_LOG_MSGS,
    ),
)

Worker(worker_config).run()
