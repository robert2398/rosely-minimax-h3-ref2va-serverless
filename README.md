# Rosely 10Eros-Max beta_5 / MiniMax H3 Ref2VA — Vast Serverless

Quality-first Vast Serverless deployment for **RTX 5090 / Blackwell** using the
**10Eros-Max beta_5 non-Turbo INT8** MiniMax H3 hybrid.

## Runtime

- ComfyUI: `127.0.0.1:18189`
- H3 FastAPI model server: `127.0.0.1:18288`
- Serverless route: `POST /generate/sync`
- Input: reference image + prompt
- Output: private S3 object + presigned GET URL

## Model pack

The single S3 deployment artifact is:

```text
s3://rosely-infrastructure/models/minimax-h3/10eros-beta5-5090/
├── 10eros-beta5-5090-comfyui.tar.zst
└── 10eros-beta5-5090-comfyui.tar.zst.sha256
```

The archive contains:

```text
ComfyUI/models/
├── diffusion_models/
│   └── 10Eros_Max_h3_hybrid_beta5_int8.safetensors
├── text_encoders/
│   └── qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
└── vae/
    ├── minimax_h3_video_vae_fp16.safetensors
    └── minimax_h3_audio_vae_fp32.safetensors

model-files.sha256
```

The provisioner performs two integrity layers:

1. verifies the downloaded `.tar.zst` against the S3 `.sha256`;
2. after extraction, runs `sha256sum -c /workspace/model-files.sha256`.

The compressed archive is deleted after successful extraction and verification.

## Why there is no HMNSFW LoRA

The previous repo version used a separate H3 model plus `HMNSFW-AIO-V2.5`.
This version uses **10Eros beta_5 as the diffusion model itself**, so the old
LoRA node and `hmmotion` auto-trigger were removed.

For backward compatibility, an old caller may still include `lora_strength`;
the API ignores it and returns `legacy_lora_strength_ignored` in metadata.

## Vast environment variables

```text
SERVERLESS=true

PYWORKER_REPO=https://github.com/robert2398/rosely-minimax-h3-ref2va-serverless.git
PYWORKER_REF=main
PROVISIONING_SCRIPT=https://raw.githubusercontent.com/robert2398/rosely-minimax-h3-ref2va-serverless/main/provision.sh

AWS_ACCESS_KEY_ID=<Vast secret>
AWS_SECRET_ACCESS_KEY=<Vast secret>
# AWS_SESSION_TOKEN=<only for temporary credentials>

ROSELY_H3_S3_BUCKET=rosely-infrastructure
ROSELY_H3_S3_REGION=us-east-1
ROSELY_H3_S3_MODEL_KEY=models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst
ROSELY_H3_S3_CHECKSUM_KEY=models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst.sha256

ROSELY_H3_OUTPUT_BUCKET=rosely-infrastructure
ROSELY_H3_OUTPUT_PREFIX=generated/minimax-h3
ROSELY_H3_PRESIGNED_URL_EXPIRES_SECONDS=3600

ROSELY_H3_S3_DOWNLOAD_CONCURRENCY=16
ROSELY_H3_S3_DOWNLOAD_CHUNK_MIB=64

MIN_FREE_DISK_GB=85
MIN_EXTRACT_FREE_GB=45
GENERATION_TIMEOUT_SECONDS=3600
KEEP_LOCAL_OUTPUTS=false
COMFYUI_ARGS=
```

Keep AWS credentials in Vast secrets. Do not commit them.

## Recommended worker

- RTX 5090 32 GB
- Blackwell-capable PyTorch/CUDA image
- 64 GB RAM minimum; 96 GB+ preferred
- 120 GB minimum disk; **150 GB recommended** for retry/debug headroom

The provisioner intentionally rejects non-Blackwell GPUs because the bundled
Qwen3-VL encoder is NVFP4-AWQ.

## Generation preset

Default server values:

```text
sampler    = res_multistep
scheduler  = simple
steps      = 8
fps        = 24
audio      = enabled
```

The model author recommends 6–8 step `simple`-scheduler setups for beta_5 and
warns against reference-degrading cache/spectrum optimizations. This repo keeps
those optimizations off.

H3 frame lengths use the `17k+5` grid:

- ~5 s → 124 frames
- ~10 s → 243 frames
- ~15 s → 362 frames

Width and height must be divisible by 32. Canvas area is capped at `1344x768`
(or an equivalent portrait area such as `768x1344`).

## API request

```json
{
  "input": {
    "request_id": "video_123",
    "input_image_url": "https://example.com/reference.png",
    "prompt": "Natural coherent movement while preserving identity, anatomy, lighting and camera consistency.",
    "width": 480,
    "height": 864,
    "duration_seconds": 5,
    "steps": 8,
    "scheduler": "simple",
    "ref_image_size": "match",
    "include_audio": true
  }
}
```

The server automatically prefixes `<Picture 1>` when it is missing.

## Health / diagnostics

```bash
supervisorctl status h3-comfyui h3-model-server
curl -s http://127.0.0.1:18189/system_stats | jq .
curl -s http://127.0.0.1:18288/health | jq .
nvidia-smi
df -h /workspace
```

Logs:

```bash
tail -f /var/log/portal/h3-provision.log
tail -f /var/log/portal/comfyui.log
tail -f /var/log/portal/model-server.log
```

## Test after deployment

```bash
pip install "vastai[serverless]"
export VAST_API_KEY='...'
export VAST_ENDPOINT_NAME='rosely-minimax-h3-ref2va'
export INPUT_IMAGE_URL='https://.../reference.png'
python test_vast_endpoint.py
```

## Workflow

`workflows/minimax_h3_ref2va_api.json` uses:

```text
CLIPLoader
→ 10Eros UNETLoader
→ MiniMaxH3SigmaShift
→ MiniMaxH3ReferenceToVideo
→ BasicGuider
→ res_multistep / simple
→ video + audio decode
→ SaveVideo
```

The reference image uses the flat autogrow API key:

```text
ref_images.ref_image_0
```

## S3 permissions required by the worker

The Vast worker needs read access to the model bundle/checksum and write/read
access to the generated-output prefix. A minimal policy should cover:

- `s3:GetObject` for the model bundle and checksum;
- `s3:PutObject` for `generated/minimax-h3/*`;
- `s3:GetObject` for generated files when using presigned GET URLs.
