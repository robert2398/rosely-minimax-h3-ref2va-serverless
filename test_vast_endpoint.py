from __future__ import annotations

import asyncio
import base64
import json
import os
import uuid
from pathlib import Path

from vastai import Serverless


def build_image_input() -> dict:
    image_url = os.getenv("INPUT_IMAGE_URL", "").strip()
    local_image = os.getenv("INPUT_IMAGE_PATH", "").strip()

    if image_url:
        return {"input_image_url": image_url}

    if local_image:
        path = Path(local_image)
        encoded = base64.b64encode(path.read_bytes()).decode("ascii")
        return {"input_image_base64": encoded}

    raise SystemExit("Set INPUT_IMAGE_URL or INPUT_IMAGE_PATH")


async def main() -> None:
    api_key = os.environ["VAST_API_KEY"]
    endpoint_name = os.getenv(
        "VAST_ENDPOINT_NAME",
        "rosely-minimax-h3-ref2va",
    )

    payload = {
        "input": {
            "request_id": f"notebook_{uuid.uuid4().hex[:12]}",
            **build_image_input(),
            "prompt": os.getenv(
                "H3_PROMPT",
                "Subtle natural motion while preserving the subject identity, "
                "anatomy, pose coherence, lighting and camera consistency.",
            ),
            "width": int(os.getenv("H3_WIDTH", "480")),
            "height": int(os.getenv("H3_HEIGHT", "864")),
            "duration_seconds": float(os.getenv("H3_DURATION", "5")),
            "steps": int(os.getenv("H3_STEPS", "8")),
            "scheduler": os.getenv("H3_SCHEDULER", "simple"),
            "ref_image_size": os.getenv("H3_REF_IMAGE_SIZE", "match"),
            "include_audio": os.getenv("H3_INCLUDE_AUDIO", "true").lower() == "true",
        }
    }

    async with Serverless(
        api_key=api_key,
        default_request_timeout=4200,
    ) as client:
        endpoint = await client.get_endpoint(name=endpoint_name)
        result = await endpoint.request(
            "/generate/sync",
            payload,
            cost=100,
            retry=True,
        )

    print(json.dumps(result, indent=2))

    if not result.get("ok"):
        raise SystemExit(
            f"Request failed: status={result.get('status')} text={result.get('text')}"
        )

    body = result["response"]
    print("\nPresigned video URL:\n", body["output_url"])
    print("\nS3 URI:\n", body["s3_uri"])


if __name__ == "__main__":
    asyncio.run(main())
