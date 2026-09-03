# Rosely MiniMax H3 Ref2VA — Vast Serverless

Quality-first MiniMax H3 Ref2VA deployment for RTX 5090 / Blackwell.

## Runtime

The worker runs:

- ComfyUI: `127.0.0.1:18189`
- H3 FastAPI model server: `127.0.0.1:18288`
- Serverless route: `POST /generate/sync`

The API accepts a reference image + prompt and returns a **private S3 presigned URL** for the generated video.

## Models

```text
ComfyUI/models/
├── diffusion_models/
│   └── minimax_h3_ref2va_pruned_hybrid_ffn_nvfp4_blackwell.safetensors
├── text_encoders/
│   └── qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
├── vae/
│   ├── minimax_h3_video_vae_fp16.safetensors
│   └── minimax_h3_audio_vae_fp32.safetensors
└── loras/
    └── HMNSFW-AIO-V2.5.safetensors
```

The S3 model artifact is expected at:

```text
s3://rosely-infrastructure/models/minimax-h3/rosely-h3-ref2va-quality-5090.zip
s3://rosely-infrastructure/models/minimax-h3/rosely-h3-ref2va-quality-5090.zip.sha256
```

## Vast environment variables

```text
SERVERLESS=true

PYWORKER_REPO=https://github.com/robert2398/rosely-minimax-h3-ref2va-serverless.git
PYWORKER_REF=main
PROVISIONING_SCRIPT=https://raw.githubusercontent.com/robert2398/rosely-minimax-h3-ref2va-serverless/main/provision.sh

AWS_ACCESS_KEY_ID=<Vast secret>
AWS_SECRET_ACCESS_KEY=<Vast secret>

S3_BUCKET=rosely-infrastructure
S3_REGION=us-east-1
S3_MODEL_KEY=models/minimax-h3/rosely-h3-ref2va-quality-5090.zip
S3_CHECKSUM_KEY=models/minimax-h3/rosely-h3-ref2va-quality-5090.zip.sha256

S3_OUTPUT_BUCKET=rosely-infrastructure
S3_OUTPUT_PREFIX=generated/minimax-h3
S3_PRESIGNED_URL_EXPIRES_SECONDS=3600

MIN_FREE_DISK_GB=85
GENERATION_TIMEOUT_SECONDS=3600
COMFYUI_ARGS=
```

Keep the AWS values in Vast secrets. Do not commit them.

## Recommended worker

- RTX 5090 32 GB
- 64 GB+ RAM
- 120 GB+ disk
- Recent PyTorch/CUDA image with Blackwell/NVFP4 support

The provisioner rejects non-Blackwell GPUs.

## API request

```json
{
  "input": {
    "request_id": "video_123",
    "input_image_url": "https://example.com/reference.png",
    "prompt": "Natural coherent motion while preserving identity and pose consistency.",
    "width": 480,
    "height": 864,
    "duration_seconds": 5,
    "steps": 20,
    "scheduler": "normal",
    "ref_image_size": "match",
    "lora_strength": 0.7,
    "include_audio": true
  }
}
```

The server automatically adds `<Picture 1>` when missing. With a non-zero motion-LoRA strength it also adds `hmmotion` unless `auto_hmmotion_trigger=false`.

H3 length is snapped to the model's `17k+5` frame grid at 24 fps:

- ~5 s → 124 frames
- ~10 s → 243 frames
- ~15 s → 362 frames

Width and height must be multiples of 32. The server caps the generation canvas to the 1344×768 pixel area.

## Successful response

Vast wraps the worker response. `result["response"]` contains data similar to:

```json
{
  "request_id": "video_123",
  "status": "completed",
  "output_url": "https://rosely-infrastructure.s3.amazonaws.com/...",
  "output_url_expires_in_seconds": 3600,
  "s3_uri": "s3://rosely-infrastructure/generated/minimax-h3/video_123.mp4",
  "size_bytes": 12345678,
  "generation_seconds": 184.2,
  "seed": 123456789,
  "width": 480,
  "height": 864,
  "length": 124,
  "fps": 24
}
```

The S3 bucket remains private. `output_url` is a temporary signed GET URL.

## Deployment checks

Inside a worker:

```bash
supervisorctl status h3-comfyui h3-model-server
curl -s http://127.0.0.1:18189/system_stats | jq .
curl -s http://127.0.0.1:18288/health | jq .
nvidia-smi
```

Logs:

```bash
tail -f /var/log/portal/comfyui.log
tail -f /var/log/portal/model-server.log
```

## Test after deployment

Notebook:

```text
notebooks/test_vast_h3_serverless.ipynb
```

Terminal client:

```bash
pip install "vastai[serverless]"
export VAST_API_KEY='...'
export VAST_ENDPOINT_NAME='rosely-minimax-h3-ref2va'
export INPUT_IMAGE_URL='https://.../reference.png'
python test_vast_endpoint.py
```

## Workflow basis

`workflows/minimax_h3_ref2va_api.json` is a ComfyUI API-format graph using:

`CLIPLoader → UNETLoader → HMNSFW LoRA → MiniMaxH3SigmaShift → MiniMaxH3ReferenceToVideo → BasicGuider → res_multistep → joint video/audio decode → SaveVideo`

It uses the flat autogrow API input key:

```text
ref_images.ref_image_0
```

for the reference image.
