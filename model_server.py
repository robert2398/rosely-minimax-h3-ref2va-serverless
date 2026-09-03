from __future__ import annotations

import asyncio
import base64
import copy
import json
import logging
import mimetypes
import os
import time
import uuid
from io import BytesIO
from pathlib import Path
from typing import Any

import boto3
import httpx
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel, ConfigDict, Field

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("rosely-minimax-h3")

COMFY_URL = os.getenv("COMFY_URL", "http://127.0.0.1:18189")
WORKFLOW_PATH = Path(
    os.getenv(
        "H3_WORKFLOW_PATH",
        "/workspace/vast-pyworker/workflows/minimax_h3_ref2va_api.json",
    )
)
INPUT_DIR = Path(os.getenv("COMFY_INPUT_DIR", "/workspace/ComfyUI/input"))
OUTPUT_DIR = Path(os.getenv("COMFY_OUTPUT_DIR", "/workspace/ComfyUI/output"))

GENERATION_TIMEOUT = int(os.getenv("GENERATION_TIMEOUT_SECONDS", "3600"))
KEEP_LOCAL_OUTPUTS = os.getenv("KEEP_LOCAL_OUTPUTS", "false").lower() == "true"
MAX_INPUT_IMAGE_BYTES = int(os.getenv("MAX_INPUT_IMAGE_BYTES", str(30 * 1024 * 1024)))

BASE_MODEL = "minimax_h3_ref2va_pruned_hybrid_ffn_nvfp4_blackwell.safetensors"
TEXT_ENCODER = "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
VIDEO_VAE = "minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE = "minimax_h3_audio_vae_fp32.safetensors"
MOTION_LORA = "HMNSFW-AIO-V2.5.safetensors"

EXPECTED_MODELS = {
    "diffusion": Path("/workspace/ComfyUI/models/diffusion_models") / BASE_MODEL,
    "text_encoder": Path("/workspace/ComfyUI/models/text_encoders") / TEXT_ENCODER,
    "video_vae": Path("/workspace/ComfyUI/models/vae") / VIDEO_VAE,
    "audio_vae": Path("/workspace/ComfyUI/models/vae") / AUDIO_VAE,
    "motion_lora": Path("/workspace/ComfyUI/models/loras") / MOTION_LORA,
}

VALID_SCHEDULERS = {"simple", "normal", "beta"}
VALID_REF_IMAGE_SIZES = {"match", "max"}

app = FastAPI(title="Rosely MiniMax H3 Ref2VA Serverless Model Server")
generation_lock = asyncio.Lock()


class GenerateEnvelope(BaseModel):
    model_config = ConfigDict(extra="allow")
    input: dict[str, Any] = Field(default_factory=dict)


def _load_base_workflow() -> dict[str, Any]:
    if not WORKFLOW_PATH.is_file():
        raise RuntimeError(f"Workflow not found: {WORKFLOW_PATH}")

    workflow = json.loads(WORKFLOW_PATH.read_text(encoding="utf-8"))
    required_types = {
        "1": "CLIPLoader",
        "2": "UNETLoader",
        "3": "LoraLoaderModelOnly",
        "4": "VAELoader",
        "5": "VAELoader",
        "6": "MiniMaxH3SigmaShift",
        "7": "LoadImage",
        "8": "MiniMaxH3ReferenceToVideo",
        "9": "BasicGuider",
        "10": "RandomNoise",
        "11": "BasicScheduler",
        "12": "KSamplerSelect",
        "13": "SamplerCustomAdvanced",
        "14": "VAEDecode",
        "15": "VAEDecodeAudio",
        "16": "CreateVideo",
        "17": "SaveVideo",
    }

    for node_id, expected_type in required_types.items():
        node = workflow.get(node_id)
        if not node:
            raise RuntimeError(f"Workflow node {node_id} is missing")
        if node.get("class_type") != expected_type:
            raise RuntimeError(
                f"Workflow node {node_id}: expected {expected_type}, "
                f"got {node.get('class_type')}"
            )

    expected_names = {
        ("1", "clip_name"): TEXT_ENCODER,
        ("2", "unet_name"): BASE_MODEL,
        ("3", "lora_name"): MOTION_LORA,
        ("4", "vae_name"): VIDEO_VAE,
        ("5", "vae_name"): AUDIO_VAE,
    }
    for (node_id, input_name), expected in expected_names.items():
        actual = workflow[node_id]["inputs"].get(input_name)
        if actual != expected:
            raise RuntimeError(
                f"Workflow {node_id}.{input_name}: expected {expected!r}, got {actual!r}"
            )

    if workflow["8"]["inputs"].get("ref_images.ref_image_0") != ["7", 0]:
        raise RuntimeError("Workflow reference image must route LoadImage -> H3 ref_image_0")

    return workflow


BASE_WORKFLOW = _load_base_workflow()


def _payload(envelope: GenerateEnvelope) -> dict[str, Any]:
    data = dict(envelope.input)
    if not data:
        raise HTTPException(status_code=422, detail="input object is required")
    return data


def _length_from_duration(seconds: float) -> int:
    target = max(5, round(seconds * 24))
    return target + (5 - (target % 17)) % 17


def _validate_dimensions(width: int, height: int) -> None:
    if width < 256 or height < 256:
        raise HTTPException(status_code=422, detail="width and height must be >= 256")
    if width % 32 or height % 32:
        raise HTTPException(
            status_code=422,
            detail="MiniMax H3 width and height must be divisible by 32",
        )
    if width * height > 1344 * 768:
        raise HTTPException(
            status_code=422,
            detail=(
                "Requested canvas exceeds the recommended 1344x768 pixel area. "
                "For portrait use up to 768x1344."
            ),
        )


def _validate_length(data: dict[str, Any]) -> tuple[int, float]:
    if data.get("length") is not None:
        length = int(data["length"])
        if length < 5 or length > 362 or length % 17 != 5:
            raise HTTPException(
                status_code=422,
                detail=(
                    "length must be in the H3 17k+5 grid and <= 362; "
                    "examples: 124 (~5s), 243 (~10s), 362 (~15s)"
                ),
            )
        return length, length / 24.0

    duration = float(data.get("duration_seconds", 5.0))
    if duration < 5.0 or duration > 15.0:
        raise HTTPException(
            status_code=422,
            detail="duration_seconds must be between 5 and 15 for this production preset",
        )
    length = _length_from_duration(duration)
    return length, length / 24.0


def _prepare_prompt(data: dict[str, Any], lora_strength: float) -> str:
    prompt = str(data.get("prompt") or "").strip()
    if not prompt:
        raise HTTPException(status_code=422, detail="prompt is required")

    # Ref2VA references must be named in the prompt.
    if "<Picture 1>" not in prompt:
        prompt = f"<Picture 1> {prompt}"

    # HMNSFW V2.5 publishes `hmmotion` as its trigger. Make it automatic
    # while still allowing callers to disable this behavior.
    auto_trigger = bool(data.get("auto_hmmotion_trigger", True))
    if lora_strength > 0 and auto_trigger and "hmmotion" not in prompt.lower():
        prompt = f"hmmotion {prompt}"

    return prompt


async def _download_input_image(data: dict[str, Any], request_id: str) -> str:
    INPUT_DIR.mkdir(parents=True, exist_ok=True)

    raw: bytes
    encoded = data.get("input_image_base64")
    url = data.get("input_image_url")

    if encoded:
        if not isinstance(encoded, str):
            raise HTTPException(status_code=422, detail="input_image_base64 must be a string")
        if encoded.startswith("data:"):
            encoded = encoded.split(",", 1)[1]
        try:
            raw = base64.b64decode(encoded, validate=False)
        except Exception as exc:
            raise HTTPException(
                status_code=422, detail=f"Invalid input_image_base64: {exc}"
            ) from exc
    elif url:
        headers = data.get("input_image_headers") or {}
        timeout = httpx.Timeout(120.0, connect=30.0)
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            try:
                response = await client.get(str(url), headers=headers)
                response.raise_for_status()
            except httpx.HTTPError as exc:
                raise HTTPException(
                    status_code=422, detail=f"Could not download input image: {exc}"
                ) from exc
            raw = response.content
    else:
        raise HTTPException(
            status_code=422,
            detail="Provide input_image_url or input_image_base64",
        )

    if len(raw) > MAX_INPUT_IMAGE_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Input image exceeds {MAX_INPUT_IMAGE_BYTES // (1024 * 1024)} MiB limit",
        )

    target = INPUT_DIR / f"h3_{request_id}.png"
    try:
        with Image.open(BytesIO(raw)) as image:
            image = image.convert("RGB")
            image.save(target, format="PNG")
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Invalid input image: {exc}") from exc

    return target.name


def _patch_workflow(
    data: dict[str, Any],
    image_name: str,
    request_id: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    workflow = copy.deepcopy(BASE_WORKFLOW)

    width = int(data.get("width", 480))
    height = int(data.get("height", 864))
    _validate_dimensions(width, height)

    length, actual_duration = _validate_length(data)

    steps = int(data.get("steps", 20))
    if steps < 4 or steps > 50:
        raise HTTPException(status_code=422, detail="steps must be between 4 and 50")

    scheduler = str(data.get("scheduler", "normal"))
    if scheduler not in VALID_SCHEDULERS:
        raise HTTPException(
            status_code=422,
            detail=f"scheduler must be one of {sorted(VALID_SCHEDULERS)}",
        )

    ref_image_size = str(data.get("ref_image_size", "match"))
    if ref_image_size not in VALID_REF_IMAGE_SIZES:
        raise HTTPException(
            status_code=422,
            detail="ref_image_size must be 'match' or 'max'",
        )

    lora_strength = float(data.get("lora_strength", 0.7))
    if lora_strength < 0 or lora_strength > 1.2:
        raise HTTPException(
            status_code=422,
            detail="lora_strength must be between 0 and 1.2",
        )

    shift_video = float(data.get("shift_video", 12.0))
    shift_audio = float(data.get("shift_audio", 3.0))

    seed = int(data.get("seed", int.from_bytes(os.urandom(6), "big")))
    if seed < 0:
        raise HTTPException(status_code=422, detail="seed must be >= 0")

    include_audio = bool(data.get("include_audio", True))
    prompt = _prepare_prompt(data, lora_strength)

    workflow["3"]["inputs"]["strength_model"] = lora_strength
    workflow["6"]["inputs"]["shift_video"] = shift_video
    workflow["6"]["inputs"]["shift_audio"] = shift_audio

    workflow["7"]["inputs"]["image"] = image_name

    workflow["8"]["inputs"].update(
        {
            "prompt": prompt,
            "width": width,
            "height": height,
            "length": length,
            "ref_image_size": ref_image_size,
            "ref_images.ref_image_0": ["7", 0],
        }
    )

    workflow["10"]["inputs"]["noise_seed"] = seed

    workflow["11"]["inputs"].update(
        {
            "scheduler": scheduler,
            "steps": steps,
            "denoise": 1.0,
        }
    )

    workflow["17"]["inputs"]["filename_prefix"] = f"video/h3/{request_id}"

    if not include_audio:
        workflow["16"]["inputs"].pop("audio", None)
        workflow.pop("15", None)

    metadata = {
        "seed": seed,
        "width": width,
        "height": height,
        "length": length,
        "fps": 24,
        "duration_seconds_actual": actual_duration,
        "steps": steps,
        "scheduler": scheduler,
        "sampler": "res_multistep",
        "lora_strength": lora_strength,
        "ref_image_size": ref_image_size,
        "include_audio": include_audio,
        "shift_video": shift_video,
        "shift_audio": shift_audio,
        "effective_prompt": prompt,
    }
    return workflow, metadata


async def _submit_and_wait(
    workflow: dict[str, Any],
    request_id: str,
) -> tuple[str, dict[str, Any]]:
    client_id = str(uuid.uuid4())
    timeout = httpx.Timeout(120.0, connect=20.0)

    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(
            f"{COMFY_URL}/prompt",
            json={"prompt": workflow, "client_id": client_id},
        )

        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail=f"ComfyUI rejected prompt: {response.text}",
            )

        body = response.json()
        if body.get("error") or body.get("node_errors"):
            raise HTTPException(status_code=502, detail=body)

        prompt_id = body["prompt_id"]
        logger.info("request=%s comfy_prompt_id=%s submitted", request_id, prompt_id)

        deadline = time.monotonic() + GENERATION_TIMEOUT
        while time.monotonic() < deadline:
            history_response = await client.get(f"{COMFY_URL}/history/{prompt_id}")
            history_response.raise_for_status()
            history = history_response.json()

            if prompt_id in history:
                item = history[prompt_id]
                status = item.get("status", {})
                if status.get("status_str") == "error":
                    raise HTTPException(
                        status_code=500,
                        detail={
                            "request_id": request_id,
                            "prompt_id": prompt_id,
                            "status": status,
                        },
                    )
                return prompt_id, item

            await asyncio.sleep(3)

        try:
            await client.post(f"{COMFY_URL}/interrupt")
        except Exception:
            logger.exception("Failed to interrupt timed-out prompt %s", prompt_id)

        raise HTTPException(
            status_code=504,
            detail=f"H3 generation timed out after {GENERATION_TIMEOUT}s",
        )


def _find_output_metadata(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        filename = value.get("filename")
        if filename and Path(str(filename)).suffix.lower() in {
            ".mp4",
            ".webm",
            ".mov",
            ".mkv",
        }:
            return value
        for nested in value.values():
            found = _find_output_metadata(nested)
            if found:
                return found
    elif isinstance(value, list):
        for nested in value:
            found = _find_output_metadata(nested)
            if found:
                return found
    return None


def _resolve_output(
    history_item: dict[str, Any],
    request_id: str,
) -> tuple[Path, dict[str, Any]]:
    metadata = _find_output_metadata(history_item.get("outputs", {}))
    if metadata:
        subfolder = str(metadata.get("subfolder") or "")
        path = OUTPUT_DIR / subfolder / str(metadata["filename"])
        if path.is_file():
            return path, metadata

    # SaveVideo uses filename_prefix video/h3/{request_id}.
    request_candidates = sorted(
        (
            p
            for p in OUTPUT_DIR.rglob(f"{request_id}*")
            if p.suffix.lower() in {".mp4", ".webm", ".mov", ".mkv"}
        ),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if request_candidates:
        path = request_candidates[0]
        return path, {
            "filename": path.name,
            "subfolder": str(path.parent.relative_to(OUTPUT_DIR)),
            "type": "output",
        }

    raise HTTPException(
        status_code=500,
        detail="ComfyUI completed but the request-specific video file was not found",
    )


def _s3_output_config() -> tuple[str, str, int]:
    bucket = os.getenv("S3_OUTPUT_BUCKET") or os.getenv("S3_BUCKET")
    if not bucket:
        raise RuntimeError("S3_OUTPUT_BUCKET or S3_BUCKET must be configured")

    prefix = os.getenv("S3_OUTPUT_PREFIX", "generated/minimax-h3").strip("/")
    expires = int(os.getenv("S3_PRESIGNED_URL_EXPIRES_SECONDS", "3600"))
    if expires < 60 or expires > 604800:
        raise RuntimeError(
            "S3_PRESIGNED_URL_EXPIRES_SECONDS must be between 60 and 604800"
        )
    return bucket, prefix, expires


def _s3_client():
    # boto3 uses the standard AWS credential chain, including:
    # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN.
    return boto3.client(
        "s3",
        endpoint_url=os.getenv("S3_ENDPOINT_URL") or None,
        region_name=os.getenv("S3_REGION", "us-east-1"),
    )


def _upload_and_presign(
    path: Path,
    request_id: str,
) -> tuple[str, str, str, int]:
    bucket, prefix, expires = _s3_output_config()
    key = f"{prefix}/{request_id}{path.suffix.lower()}"
    content_type = mimetypes.guess_type(path.name)[0] or "video/mp4"

    client = _s3_client()
    client.upload_file(
        str(path),
        bucket,
        key,
        ExtraArgs={
            "ContentType": content_type,
            "ServerSideEncryption": "AES256",
        },
    )

    presigned = client.generate_presigned_url(
        ClientMethod="get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=expires,
    )

    return presigned, bucket, key, expires


@app.get("/health")
async def health() -> dict[str, Any]:
    missing = [name for name, path in EXPECTED_MODELS.items() if not path.is_file()]

    comfy_ok = False
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(f"{COMFY_URL}/system_stats")
            comfy_ok = response.status_code == 200
    except Exception:
        comfy_ok = False

    bucket = os.getenv("S3_OUTPUT_BUCKET") or os.getenv("S3_BUCKET")
    if missing or not comfy_ok or not bucket:
        raise HTTPException(
            status_code=503,
            detail={
                "comfyui": comfy_ok,
                "missing_models": missing,
                "s3_output_bucket_configured": bool(bucket),
            },
        )

    return {
        "status": "ok",
        "comfyui": True,
        "workflow": WORKFLOW_PATH.name,
        "s3_output_bucket": bucket,
        "s3_output_prefix": os.getenv(
            "S3_OUTPUT_PREFIX",
            "generated/minimax-h3",
        ),
    }


@app.post("/generate/sync")
async def generate_sync(envelope: GenerateEnvelope) -> dict[str, Any]:
    data = _payload(envelope)
    request_id = str(data.get("request_id") or f"h3_{uuid.uuid4().hex}")

    image_name: str | None = None
    output_path: Path | None = None

    async with generation_lock:
        started = time.monotonic()
        try:
            # Fail before expensive inference if output storage is not configured.
            _s3_output_config()

            image_name = await _download_input_image(data, request_id)
            workflow, generation_meta = _patch_workflow(
                data,
                image_name,
                request_id,
            )

            prompt_id, history_item = await _submit_and_wait(
                workflow,
                request_id,
            )

            output_path, comfy_metadata = _resolve_output(
                history_item,
                request_id,
            )

            try:
                (
                    output_url,
                    output_bucket,
                    output_key,
                    expires_in,
                ) = await asyncio.to_thread(
                    _upload_and_presign,
                    output_path,
                    request_id,
                )
            except Exception as exc:
                logger.exception("S3 upload failed for request=%s", request_id)
                raise HTTPException(
                    status_code=502,
                    detail=f"Video generated but S3 upload/presign failed: {exc}",
                ) from exc

            elapsed = time.monotonic() - started

            return {
                "request_id": request_id,
                "prompt_id": prompt_id,
                "status": "completed",
                "output_url": output_url,
                "output_url_expires_in_seconds": expires_in,
                "s3_uri": f"s3://{output_bucket}/{output_key}",
                "s3_bucket": output_bucket,
                "s3_key": output_key,
                "size_bytes": output_path.stat().st_size,
                "generation_seconds": round(elapsed, 2),
                "comfyui_output": comfy_metadata,
                **generation_meta,
            }
        finally:
            if image_name:
                (INPUT_DIR / image_name).unlink(missing_ok=True)
            if output_path and not KEEP_LOCAL_OUTPUTS:
                output_path.unlink(missing_ok=True)
