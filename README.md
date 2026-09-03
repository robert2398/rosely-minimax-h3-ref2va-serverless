# Rosely MiniMax H3 Ref2VA — Vast provisioning

This repository is the provisioning layer for the **quality-first MiniMax H3 Ref2VA stack on RTX 5090 / Blackwell**.

It is adapted from the existing `rosely-wan22-v3-serverless` deployment pattern: pinned ComfyUI, S3-hosted models, Supervisor-managed ComfyUI, fail-fast hardware checks, and deterministic file validation.

## Final model pack

The provisioner expects one S3 ZIP:

`S3://rosely-infrastructure/models/minimax-h3/rosely-h3-ref2va-quality-5090.zip`

with this layout:

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

A sibling SHA-256 file is required:

`S3://rosely-infrastructure/models/minimax-h3/rosely-h3-ref2va-quality-5090.zip.sha256`

The provisioner downloads the ZIP with multipart S3 transfer, verifies SHA-256, extracts into `/workspace`, deletes the ZIP to reclaim disk, validates the five expected files, and then starts ComfyUI.

## Hardware target

This artifact is intentionally **5090 / Blackwell-only**.

The selected quality-first diffusion checkpoint uses native NVFP4 operations. `provision.sh` rejects GPUs with CUDA compute capability major < 12 so a 4090 is not accidentally assigned to this workergroup.

Recommended first worker:

- RTX 5090 32 GB
- 64 GB+ system RAM
- **120 GB worker disk**
- recent Vast PyTorch image with CUDA 13.x

The model ZIP and extracted files coexist briefly, so a 100 GB disk can be uncomfortably tight depending on the base image. 120 GB is safer.

## Vast environment

Push this repository to GitHub, then configure:

```text
SERVERLESS=true
PYWORKER_REPO=https://github.com/YOUR_GITHUB_USER/rosely-h3-ref2va-serverless.git
PYWORKER_REF=main
PROVISIONING_SCRIPT=https://raw.githubusercontent.com/YOUR_GITHUB_USER/rosely-h3-ref2va-serverless/main/provision.sh

S3_BUCKET=rosely-infrastructure
S3_REGION=us-east-1
S3_MODEL_KEY=models/minimax-h3/rosely-h3-ref2va-quality-5090.zip
S3_CHECKSUM_KEY=models/minimax-h3/rosely-h3-ref2va-quality-5090.zip.sha256
MIN_FREE_DISK_GB=85
```

Configure these as **Vast secrets**, not repository variables committed to Git:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

If temporary AWS credentials are used, also set `AWS_SESSION_TOKEN`.

## ComfyUI

Pinned commit:

```text
345c9190497c82cff53e71fb4ae00d1e135a6542
```

ComfyUI listens only locally:

```text
127.0.0.1:18189
```

The provisioner uses default ComfyUI memory management first. Do not start with `--disable-smart-memory`; the selected H3 checkpoint relies on ComfyUI/DynamicVRAM to stage large components efficiently.

To force low-VRAM mode on a problematic host:

```text
COMFYUI_ARGS=--lowvram
```

## After provisioning

Useful checks inside a worker:

```bash
supervisorctl status h3-comfyui
curl -s http://127.0.0.1:18189/system_stats | jq .
nvidia-smi
find /workspace/ComfyUI/models -type f -name '*.safetensors' -printf '%s %p\n' | sort -n
```

## Scope of this repository

This package is the **provisioning/runtime foundation**. It intentionally does not yet hard-code a `/generate/sync` H3 API workflow.

The previous Wan repository's `model_server.py` is tightly coupled to Wan-specific node IDs and routing, so copying it directly would be unsafe. The next step is to validate the official MiniMax H3 Ref2VA workflow with this exact hybrid checkpoint + HMNSFW V2.5, export the tested workflow in ComfyUI API format, and then add the H3-specific model server on top.

## License note

Before production deployment, review the MiniMax H3 Community License and the license/NOTICE of the hybrid derivative. The hybrid model card states territorial restrictions, including exclusion of the United States, EU, UK, and Republic of Korea from its defined applicable territory. Your current S3 bucket is in `us-east-1`, so this deserves review before treating the setup as a production distribution path.
