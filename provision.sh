#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1

APP_DIR=${APP_DIR:-/workspace/vast-pyworker}
COMFY_DIR=${COMFY_DIR:-/workspace/ComfyUI}

# Pinned 2026-09-03 ComfyUI main commit with native MiniMax H3 support.
COMFY_COMMIT=${COMFY_COMMIT:-345c9190497c82cff53e71fb4ae00d1e135a6542}

PYWORKER_REPO=${PYWORKER_REPO:?PYWORKER_REPO must point to this H3 provisioning repository}
PYWORKER_REF=${PYWORKER_REF:-main}

# Final artifact created in rosely-infrastructure.
S3_BUCKET=${S3_BUCKET:-rosely-infrastructure}
S3_MODEL_KEY=${S3_MODEL_KEY:-models/minimax-h3/rosely-h3-ref2va-quality-5090.zip}
S3_CHECKSUM_KEY=${S3_CHECKSUM_KEY:-models/minimax-h3/rosely-h3-ref2va-quality-5090.zip.sha256}
S3_REGION=${S3_REGION:-us-east-1}
S3_ENDPOINT_URL=${S3_ENDPOINT_URL:-}

# The ZIP is ~37 GiB and expands to another ~37 GiB before the ZIP is deleted.
MIN_FREE_DISK_GB=${MIN_FREE_DISK_GB:-85}
S3_DOWNLOAD_CONCURRENCY=${S3_DOWNLOAD_CONCURRENCY:-16}
S3_DOWNLOAD_CHUNK_MIB=${S3_DOWNLOAD_CHUNK_MIB:-64}

MODEL_ZIP=/workspace/rosely-h3-ref2va-quality-5090.zip
CHECKSUM_FILE=/workspace/rosely-h3-ref2va-quality-5090.zip.sha256

export APP_DIR COMFY_DIR
export S3_BUCKET S3_MODEL_KEY S3_CHECKSUM_KEY S3_REGION S3_ENDPOINT_URL
export S3_DOWNLOAD_CONCURRENCY S3_DOWNLOAD_CHUNK_MIB
export MODEL_ZIP CHECKSUM_FILE

log() {
  printf '\n[%s] %s\n' "$(date -Iseconds)" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  log "Provisioning failed at line ${line_no} with exit code ${exit_code}"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

ensure_system_packages() {
  local packages=()

  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v ffmpeg >/dev/null 2>&1 || packages+=(ffmpeg)
  command -v git >/dev/null 2>&1 || packages+=(git)
  command -v jq >/dev/null 2>&1 || packages+=(jq)
  command -v unzip >/dev/null 2>&1 || packages+=(unzip)
  command -v supervisorctl >/dev/null 2>&1 || packages+=(supervisor)

  dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null \
    | grep -q 'install ok installed' || packages+=(ca-certificates)

  dpkg-query -W -f='${Status}' libgl1 2>/dev/null \
    | grep -q 'install ok installed' || packages+=(libgl1)

  if ! dpkg-query -W -f='${Status}' libglib2.0-0t64 2>/dev/null \
      | grep -q 'install ok installed'; then
    if apt-cache show libglib2.0-0t64 >/dev/null 2>&1; then
      packages+=(libglib2.0-0t64)
    else
      packages+=(libglib2.0-0)
    fi
  fi

  if (( ${#packages[@]} > 0 )); then
    log "Installing missing system packages: ${packages[*]}"
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${packages[@]}"
    rm -rf /var/lib/apt/lists/*
  else
    log "Required system packages are already present"
  fi
}

check_disk_space() {
  local available_kb required_kb
  mkdir -p /workspace
  available_kb=$(df -Pk /workspace | awk 'NR==2 {print $4}')
  required_kb=$((MIN_FREE_DISK_GB * 1024 * 1024))

  log "Available /workspace disk: $((available_kb / 1024 / 1024)) GiB"

  if (( available_kb < required_kb )); then
    fail "At least ${MIN_FREE_DISK_GB} GiB free is required. Use a larger Vast disk (120 GiB recommended)."
  fi
}

clone_exact_commit() {
  local repo_url=$1
  local commit=$2
  local destination=$3

  rm -rf "$destination"
  git init -q "$destination"
  git -C "$destination" remote add origin "$repo_url"
  git -C "$destination" fetch --depth 1 origin "$commit"
  git -C "$destination" checkout --detach -q FETCH_HEAD
}

install_comfyui_preserving_models() {
  local current_commit=""
  local backup_dir=""

  if [[ -d "$COMFY_DIR/.git" ]]; then
    current_commit=$(git -C "$COMFY_DIR" rev-parse HEAD 2>/dev/null || true)
  fi

  if [[ "$current_commit" == "$COMFY_COMMIT" ]]; then
    log "Pinned ComfyUI already installed"
    return 0
  fi

  if [[ -d "$COMFY_DIR/models" ]]; then
    backup_dir=$(mktemp -d /workspace/.h3-models-backup.XXXXXX)
    log "Temporarily preserving existing model directory"
    mv "$COMFY_DIR/models" "$backup_dir/models"
  fi

  log "Installing pinned ComfyUI commit ${COMFY_COMMIT}"
  clone_exact_commit \
    "https://github.com/Comfy-Org/ComfyUI.git" \
    "$COMFY_COMMIT" \
    "$COMFY_DIR"

  if [[ -n "$backup_dir" && -d "$backup_dir/models" ]]; then
    rm -rf "$COMFY_DIR/models"
    mv "$backup_dir/models" "$COMFY_DIR/models"
    rmdir "$backup_dir" || true
  fi
}

ensure_system_packages
check_disk_space

log "Cloning H3 provisioning repository"
rm -rf "$APP_DIR"
git clone \
  --depth 1 \
  --single-branch \
  --branch "$PYWORKER_REF" \
  "$PYWORKER_REPO" \
  "$APP_DIR"

[[ -f /venv/main/bin/activate ]] \
  || fail "/venv/main is missing. Use a recent Vast PyTorch CUDA 13.x image."

source /venv/main/bin/activate

log "Checking CUDA and Blackwell GPU"
python - <<'PY'
import torch

print("Torch:", torch.__version__)
print("CUDA runtime:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())

if not torch.cuda.is_available():
    raise SystemExit("PyTorch cannot access CUDA")

name = torch.cuda.get_device_name(0)
cap = torch.cuda.get_device_capability(0)

print("GPU:", name)
print("Compute capability:", cap)

# The selected H3 checkpoint contains native NVFP4 operations and is intended
# for Blackwell (RTX 50-series / SM 12.x).
if cap[0] < 12:
    raise SystemExit(
        f"Blackwell GPU required for this artifact. Detected {name}, compute capability {cap}."
    )
PY

log "Installing provisioning dependencies"
python -m pip install --prefer-binary -r "$APP_DIR/requirements.txt"

install_comfyui_preserving_models

log "Installing ComfyUI Python requirements"
python -m pip install --prefer-binary -r "$COMFY_DIR/requirements.txt"

mkdir -p \
  "$COMFY_DIR/models/diffusion_models" \
  "$COMFY_DIR/models/text_encoders" \
  "$COMFY_DIR/models/vae" \
  "$COMFY_DIR/models/loras" \
  "$COMFY_DIR/input" \
  "$COMFY_DIR/output" \
  "$COMFY_DIR/temp" \
  /var/log/portal

check_disk_space

log "Downloading H3 model ZIP and checksum from S3"

python - <<'PY'
from __future__ import annotations

import hashlib
import os
from pathlib import Path

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config

MIB = 1024 * 1024
GIB = 1024 * 1024 * 1024

bucket = os.environ["S3_BUCKET"]
model_key = os.environ["S3_MODEL_KEY"]
checksum_key = os.environ["S3_CHECKSUM_KEY"]
region = os.environ.get("S3_REGION", "us-east-1")
endpoint_url = os.environ.get("S3_ENDPOINT_URL") or None
concurrency = max(1, int(os.environ.get("S3_DOWNLOAD_CONCURRENCY", "16")))
chunk_mib = max(16, int(os.environ.get("S3_DOWNLOAD_CHUNK_MIB", "64")))
model_zip = Path(os.environ["MODEL_ZIP"])
checksum_file = Path(os.environ["CHECKSUM_FILE"])

client = boto3.client(
    "s3",
    region_name=region,
    endpoint_url=endpoint_url,
    config=Config(
        connect_timeout=60,
        read_timeout=900,
        tcp_keepalive=True,
        max_pool_connections=max(32, concurrency * 2),
        retries={"mode": "standard", "max_attempts": 20},
        signature_version="s3v4",
    ),
)

head = client.head_object(Bucket=bucket, Key=model_key)
size = int(head["ContentLength"])
print(f"S3 model artifact: s3://{bucket}/{model_key}")
print(f"Artifact size: {size / GIB:.2f} GiB")

checksum_obj = client.get_object(Bucket=bucket, Key=checksum_key)
checksum_text = checksum_obj["Body"].read().decode("utf-8").strip()
checksum_file.write_text(checksum_text + "\n", encoding="utf-8")
expected = checksum_text.split()[0].lower()

transfer = TransferConfig(
    multipart_threshold=64 * MIB,
    multipart_chunksize=chunk_mib * MIB,
    max_concurrency=concurrency,
    use_threads=True,
)

tmp = model_zip.with_suffix(model_zip.suffix + ".part")
tmp.unlink(missing_ok=True)

print(f"Downloading with {concurrency} workers, {chunk_mib} MiB chunks...")
client.download_file(bucket, model_key, str(tmp), Config=transfer)

print("Verifying SHA-256...")
digest = hashlib.sha256()
with tmp.open("rb") as handle:
    for block in iter(lambda: handle.read(32 * MIB), b""):
        digest.update(block)
actual = digest.hexdigest()

if actual != expected:
    tmp.unlink(missing_ok=True)
    raise SystemExit(
        f"ZIP SHA mismatch: expected {expected}, got {actual}"
    )

tmp.replace(model_zip)
print(f"Verified artifact: {model_zip} ({model_zip.stat().st_size / GIB:.2f} GiB)")
PY

log "Extracting H3 model artifact into /workspace"
unzip -q -o "$MODEL_ZIP" -d /workspace

log "Deleting ZIP after extraction to reclaim disk"
rm -f "$MODEL_ZIP" "$CHECKSUM_FILE"

log "Validating exact H3 model pack"

python - <<'PY'
from pathlib import Path

base = Path("/workspace/ComfyUI/models")

files = {
    "quality-first Ref2VA diffusion": (
        base / "diffusion_models/minimax_h3_ref2va_pruned_hybrid_ffn_nvfp4_blackwell.safetensors",
        16_000_000_000,
    ),
    "Qwen3-VL H3 text encoder": (
        base / "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
        15_000_000_000,
    ),
    "H3 video VAE": (
        base / "vae/minimax_h3_video_vae_fp16.safetensors",
        5_000_000_000,
    ),
    "H3 audio VAE": (
        base / "vae/minimax_h3_audio_vae_fp32.safetensors",
        500_000_000,
    ),
    "HMNSFW AIO V2.5": (
        base / "loras/HMNSFW-AIO-V2.5.safetensors",
        80_000_000,
    ),
}

for label, (path, minimum) in files.items():
    if not path.is_file():
        raise SystemExit(f"Missing {label}: {path}")
    size = path.stat().st_size
    if size < minimum:
        raise SystemExit(
            f"{label} is unexpectedly small: {size:,} bytes at {path}"
        )
    print(f"OK  {label}: {size / (1024**3):.2f} GiB  {path}")

print("All five H3 files are present.")
PY

log "Disabling generic ComfyUI services that can conflict with this stack"
for service in api-wrapper comfyui; do
  supervisorctl stop "$service" >/dev/null 2>&1 || true
done

for config in \
  /etc/supervisor/conf.d/api-wrapper.conf \
  /etc/supervisor/conf.d/comfyui.conf; do
  if [[ -f "$config" ]]; then
    mv "$config" "${config}.disabled"
  fi
done

supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true

log "Installing H3 ComfyUI service"
mkdir -p /opt/rosely-h3-serverless
cp "$APP_DIR/scripts/start_comfyui.sh" /opt/rosely-h3-serverless/
chmod +x /opt/rosely-h3-serverless/start_comfyui.sh
cp "$APP_DIR/supervisor/h3-services.conf" /etc/supervisor/conf.d/h3-services.conf

supervisorctl reread
supervisorctl update

log "Waiting for H3 ComfyUI health"
comfy_ok=0
for _ in $(seq 1 180); do
  if curl -fsS http://127.0.0.1:18189/system_stats >/dev/null 2>&1; then
    comfy_ok=1
    break
  fi

  state=$(supervisorctl status h3-comfyui 2>/dev/null | awk '{print $2}' || true)
  if [[ "$state" == "FATAL" || "$state" == "EXITED" ]]; then
    break
  fi

  sleep 2
done

(( comfy_ok == 1 )) || {
  supervisorctl status || true
  nvidia-smi || true
  tail -250 /var/log/portal/comfyui.log 2>/dev/null || true
  fail "H3 ComfyUI did not become healthy within 360 seconds"
}

log "H3 provisioning complete"
supervisorctl status h3-comfyui || true
nvidia-smi || true

log "Installed H3 files"
find "$COMFY_DIR/models" \
  -type f \
  \( -name "*.safetensors" -o -name "*.gguf" \) \
  -printf "%s %p\n" \
  | sort -n

df -h /workspace
