#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export PYTHONUNBUFFERED=1

mkdir -p /var/log/portal
touch /var/log/portal/h3-provision.log
exec > >(tee -a /var/log/portal/h3-provision.log) 2>&1

APP_DIR=${APP_DIR:-/workspace/vast-pyworker}
COMFY_DIR=${COMFY_DIR:-/workspace/ComfyUI}
COMFY_COMMIT=${COMFY_COMMIT:-345c9190497c82cff53e71fb4ae00d1e135a6542}

PYWORKER_REPO=${PYWORKER_REPO:?PYWORKER_REPO must point to the H3 serverless repository}
PYWORKER_REF=${PYWORKER_REF:-main}

# Rosely-namespaced S3 settings. Generic S3_* variables are intentionally not
# consumed because Vast/base images may populate them for unrelated services.
H3_S3_BUCKET=${ROSELY_H3_S3_BUCKET:?ROSELY_H3_S3_BUCKET is required}
H3_S3_MODEL_KEY=${ROSELY_H3_S3_MODEL_KEY:-models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst}
H3_S3_CHECKSUM_KEY=${ROSELY_H3_S3_CHECKSUM_KEY:-models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst.sha256}
H3_S3_REGION=${ROSELY_H3_S3_REGION:-us-east-1}
H3_S3_ENDPOINT_URL=${ROSELY_H3_S3_ENDPOINT_URL:-}

H3_S3_DOWNLOAD_CONCURRENCY=${ROSELY_H3_S3_DOWNLOAD_CONCURRENCY:-16}
H3_S3_DOWNLOAD_CHUNK_MIB=${ROSELY_H3_S3_DOWNLOAD_CHUNK_MIB:-64}

# Fresh provisioning peaks at roughly 36 GiB compressed + 40 GiB extracted
# plus ComfyUI/runtime overhead. 120 GiB works, but 150 GiB is recommended
# for retry/debug headroom. Disk checks are state-aware so retries are idempotent.
MIN_FREE_DISK_GB=${MIN_FREE_DISK_GB:-85}
MIN_EXTRACT_FREE_GB=${MIN_EXTRACT_FREE_GB:-45}

MODEL_ARCHIVE=/workspace/10eros-beta5-5090-comfyui.tar.zst
CHECKSUM_FILE=/workspace/10eros-beta5-5090-comfyui.tar.zst.sha256
MODEL_MANIFEST=/workspace/model-files.sha256
MODEL_READY_MARKER=/workspace/.rosely-h3-10eros-beta5.ready

export APP_DIR COMFY_DIR
export H3_S3_BUCKET H3_S3_MODEL_KEY H3_S3_CHECKSUM_KEY H3_S3_REGION
export H3_S3_ENDPOINT_URL H3_S3_DOWNLOAD_CONCURRENCY H3_S3_DOWNLOAD_CHUNK_MIB
export MODEL_ARCHIVE CHECKSUM_FILE MODEL_MANIFEST MODEL_READY_MARKER

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

log "Rosely MiniMax H3 / 10Eros beta_5 provisioning STARTED"
log "Repo: ${PYWORKER_REPO} @ ${PYWORKER_REF}"
log "H3 S3: s3://${H3_S3_BUCKET}/${H3_S3_MODEL_KEY}"
log "Region: ${H3_S3_REGION}"

if [[ -n "${S3_BUCKET:-}" ]]; then
  log "NOTICE: legacy S3_BUCKET is present and intentionally ignored."
fi

ensure_system_packages() {
  local packages=()

  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v ffmpeg >/dev/null 2>&1 || packages+=(ffmpeg)
  command -v git >/dev/null 2>&1 || packages+=(git)
  command -v jq >/dev/null 2>&1 || packages+=(jq)
  command -v zstd >/dev/null 2>&1 || packages+=(zstd)
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
  local required_gb=${1:?required GiB missing}
  local purpose=${2:-operation}
  local available_kb required_kb

  mkdir -p /workspace
  available_kb=$(df -Pk /workspace | awk 'NR==2 {print $4}')
  required_kb=$((required_gb * 1024 * 1024))

  log "Available /workspace disk: $((available_kb / 1024 / 1024)) GiB (${purpose})"

  if (( available_kb < required_kb )); then
    fail "At least ${required_gb} GiB free is required for ${purpose}. Increase the Vast disk (150 GiB recommended)."
  fi
}

model_pack_files_present() {
  [[ -f "$COMFY_DIR/models/diffusion_models/10Eros_Max_h3_hybrid_beta5_int8.safetensors" ]] &&
  [[ -f "$COMFY_DIR/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" ]] &&
  [[ -f "$COMFY_DIR/models/vae/minimax_h3_video_vae_fp16.safetensors" ]] &&
  [[ -f "$COMFY_DIR/models/vae/minimax_h3_audio_vae_fp32.safetensors" ]]
}

model_pack_sizes_sane() {
  model_pack_files_present || return 1

  [[ $(stat -c %s "$COMFY_DIR/models/diffusion_models/10Eros_Max_h3_hybrid_beta5_int8.safetensors") -ge 20000000000 ]] &&
  [[ $(stat -c %s "$COMFY_DIR/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors") -ge 15000000000 ]] &&
  [[ $(stat -c %s "$COMFY_DIR/models/vae/minimax_h3_video_vae_fp16.safetensors") -ge 5000000000 ]] &&
  [[ $(stat -c %s "$COMFY_DIR/models/vae/minimax_h3_audio_vae_fp32.safetensors") -ge 500000000 ]]
}

verify_expected_model_hashes() {
  local checksum_tmp
  checksum_tmp=$(mktemp /workspace/.10eros-model-hashes.XXXXXX)
  cat > "$checksum_tmp" <<'EOF'
488e0d51fad9fd6b277b6ebfbe46b3fd44374ff7baa1e3c9dfce58d3a1e5b33c  ComfyUI/models/diffusion_models/10Eros_Max_h3_hybrid_beta5_int8.safetensors
35a88d51044231fe332301d7a62aa81e3f2cba62febeb446e2c1e3e0ef76f2c6  ComfyUI/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522  ComfyUI/models/vae/minimax_h3_video_vae_fp16.safetensors
8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48  ComfyUI/models/vae/minimax_h3_audio_vae_fp32.safetensors
EOF

  if (cd /workspace && sha256sum -c "$checksum_tmp"); then
    rm -f "$checksum_tmp"
    return 0
  fi

  rm -f "$checksum_tmp"
  return 1
}

mark_model_pack_ready() {
  cat > "$MODEL_READY_MARKER" <<EOF
profile=10eros-beta5-non-turbo-int8-5090
archive_sha256=dbecf6da69978835ef2be92efe1104a8c4ee904abe7ac35b8108bcba3835c006
verified_at=$(date -Iseconds)
EOF
}

model_pack_ready() {
  if [[ -f "$MODEL_READY_MARKER" ]] && model_pack_sizes_sane; then
    log "Validated model-ready marker found; reusing extracted 10Eros model pack"
    return 0
  fi

  if model_pack_sizes_sane; then
    log "Existing 10Eros model files found without a ready marker; verifying SHA-256 once"
    if verify_expected_model_hashes; then
      mark_model_pack_ready
      return 0
    fi
    log "Existing model files are incomplete/corrupt; they will be replaced"
  fi

  return 1
}

cleanup_partial_current_pack() {
  rm -f \
    "$COMFY_DIR/models/diffusion_models/10Eros_Max_h3_hybrid_beta5_int8.safetensors" \
    "$COMFY_DIR/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
    "$COMFY_DIR/models/vae/minimax_h3_video_vae_fp16.safetensors" \
    "$COMFY_DIR/models/vae/minimax_h3_audio_vae_fp32.safetensors" \
    "$MODEL_MANIFEST" \
    "$MODEL_READY_MARKER"
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

cleanup_stale_h3_models() {
  # Remove only files from the previous Rosely H3 pack. Do not wipe generic
  # ComfyUI model directories because a Vast image may contain unrelated assets.
  local stale=(
    "$COMFY_DIR/models/diffusion_models/minimax_h3_ref2va_pruned_hybrid_ffn_nvfp4_blackwell.safetensors"
    "$COMFY_DIR/models/loras/HMNSFW-AIO-V2.5.safetensors"
  )

  for path in "${stale[@]}"; do
    if [[ -f "$path" ]]; then
      log "Removing stale model from previous pack: $path"
      rm -f "$path"
    fi
  done
}

ensure_system_packages

log "Cloning H3 serverless repository"
rm -rf "$APP_DIR"
git clone \
  --progress \
  --depth 1 \
  --single-branch \
  --branch "$PYWORKER_REF" \
  "$PYWORKER_REPO" \
  "$APP_DIR"

[[ -f "$APP_DIR/worker.py" ]] || fail "worker.py missing from PYWORKER_REPO"

[[ -f /venv/main/bin/activate ]] \
  || fail "/venv/main is missing. Use a recent Vast PyTorch CUDA image with Blackwell support."

source /venv/main/bin/activate

log "Checking CUDA and Blackwell GPU"
python -u - <<'PY'
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

# The Qwen3-VL encoder in this pack is NVFP4-AWQ, so keep the Blackwell guard.
if cap[0] < 12:
    raise SystemExit(
        f"Blackwell GPU required for this artifact. "
        f"Detected {name}, compute capability {cap}."
    )
PY

log "Installing H3 application dependencies"
python -m pip install --prefer-binary -r "$APP_DIR/requirements.txt"

install_comfyui_preserving_models

log "Installing ComfyUI requirements"
python -m pip install --prefer-binary -r "$COMFY_DIR/requirements.txt"

mkdir -p \
  "$COMFY_DIR/models/diffusion_models" \
  "$COMFY_DIR/models/text_encoders" \
  "$COMFY_DIR/models/vae" \
  "$COMFY_DIR/input" \
  "$COMFY_DIR/output" \
  "$COMFY_DIR/temp" \
  /var/log/portal

cleanup_stale_h3_models

MODEL_PACK_READY=0
if model_pack_ready; then
  MODEL_PACK_READY=1
  # A previous attempt may have left the compressed archive behind. Once the
  # extracted model pack is known-good, remove it before any free-space check.
  rm -f "$MODEL_ARCHIVE" "$CHECKSUM_FILE" "$MODEL_ARCHIVE.part" "$MODEL_MANIFEST"
  log "Model pack already ready; skipping S3 download and extraction"
else
  # Free any incomplete extracted files before a retry. Keep a complete cached
  # archive if present; the Python block below will verify it and reuse it.
  cleanup_partial_current_pack

  if [[ ! -f "$MODEL_ARCHIVE" ]]; then
    check_disk_space "$MIN_FREE_DISK_GB" "fresh model download"
  else
    log "Cached model archive found; verifying it before deciding whether to re-download"
  fi

  log "STEP: Ensuring checksum-verified 10Eros beta_5 TAR.ZST is available"

python -u - <<'PY'
from __future__ import annotations

import hashlib
import os
import threading
import time
from pathlib import Path

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config

MIB = 1024 * 1024
GIB = 1024 * 1024 * 1024

bucket = os.environ["H3_S3_BUCKET"]
model_key = os.environ["H3_S3_MODEL_KEY"]
checksum_key = os.environ["H3_S3_CHECKSUM_KEY"]
region = os.environ.get("H3_S3_REGION", "us-east-1")
endpoint_url = os.environ.get("H3_S3_ENDPOINT_URL") or None
concurrency = max(1, int(os.environ.get("H3_S3_DOWNLOAD_CONCURRENCY", "16")))
chunk_mib = max(16, int(os.environ.get("H3_S3_DOWNLOAD_CHUNK_MIB", "64")))
archive = Path(os.environ["MODEL_ARCHIVE"])
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

print(f"[S3] HEAD s3://{bucket}/{model_key}", flush=True)
head = client.head_object(Bucket=bucket, Key=model_key)
size = int(head["ContentLength"])
print(f"[S3] Artifact size: {size / GIB:.2f} GiB", flush=True)

print(f"[S3] Fetching checksum s3://{bucket}/{checksum_key}", flush=True)
checksum_obj = client.get_object(Bucket=bucket, Key=checksum_key)
checksum_text = checksum_obj["Body"].read().decode("utf-8").strip()
checksum_file.write_text(checksum_text + "\n", encoding="utf-8")
expected = checksum_text.split()[0].lower()
if len(expected) != 64:
    raise SystemExit(f"Invalid SHA-256 checksum file: {checksum_text!r}")
print(f"[S3] Expected SHA-256: {expected}", flush=True)

transfer = TransferConfig(
    multipart_threshold=64 * MIB,
    multipart_chunksize=chunk_mib * MIB,
    max_concurrency=concurrency,
    use_threads=True,
)

tmp = archive.with_suffix(archive.suffix + ".part")
tmp.unlink(missing_ok=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(32 * MIB), b""):
            digest.update(block)
    return digest.hexdigest()


class Progress:
    def __init__(self, total: int):
        self.total = total
        self.seen = 0
        self.started = time.monotonic()
        self.last_print = 0.0
        self.lock = threading.Lock()

    def __call__(self, amount: int):
        with self.lock:
            self.seen += amount
            now = time.monotonic()
            if self.seen >= self.total or now - self.last_print >= 5.0:
                elapsed = max(0.001, now - self.started)
                speed = self.seen / elapsed
                remaining = max(0, self.total - self.seen)
                eta = remaining / speed if speed else 0
                pct = self.seen / self.total * 100 if self.total else 0
                print(
                    f"[S3] {pct:6.2f}% | "
                    f"{self.seen/GIB:6.2f}/{self.total/GIB:6.2f} GiB | "
                    f"{speed/MIB:7.1f} MiB/s | ETA {eta:6.0f}s",
                    flush=True,
                )
                self.last_print = now


reuse_archive = False
if archive.is_file() and archive.stat().st_size == size:
    print(f"[CACHE] Existing archive found ({archive.stat().st_size / GIB:.2f} GiB); verifying...", flush=True)
    actual = sha256_file(archive)
    if actual == expected:
        print("[CACHE] Existing archive SHA-256 OK; reusing without S3 download", flush=True)
        reuse_archive = True
    else:
        print(f"[CACHE] Existing archive SHA mismatch ({actual}); deleting and re-downloading", flush=True)
        archive.unlink(missing_ok=True)

if not reuse_archive:
    print(
        f"[S3] Downloading with {concurrency} workers, {chunk_mib} MiB chunks...",
        flush=True,
    )
    client.download_file(
        bucket,
        model_key,
        str(tmp),
        Config=transfer,
        Callback=Progress(size),
    )

    print("[SHA256] Verifying downloaded TAR.ZST...", flush=True)
    digest = hashlib.sha256()
    verified = 0
    verify_started = time.monotonic()
    last_verify = 0.0

    with tmp.open("rb") as handle:
        for block in iter(lambda: handle.read(32 * MIB), b""):
            digest.update(block)
            verified += len(block)
            now = time.monotonic()
            if verified >= size or now - last_verify >= 5.0:
                elapsed = max(0.001, now - verify_started)
                pct = verified / size * 100 if size else 0
                print(
                    f"[SHA256] {pct:6.2f}% | "
                    f"{verified/GIB:6.2f}/{size/GIB:6.2f} GiB | "
                    f"{verified/elapsed/MIB:7.1f} MiB/s",
                    flush=True,
                )
                last_verify = now

    actual = digest.hexdigest()
    if actual != expected:
        tmp.unlink(missing_ok=True)
        raise SystemExit(
            f"TAR.ZST SHA mismatch: expected {expected}, got {actual}"
        )

    tmp.replace(archive)

print(
    f"Verified artifact: {archive} "
    f"({archive.stat().st_size / GIB:.2f} GiB)",
    flush=True,
)
PY

check_disk_space "$MIN_EXTRACT_FREE_GB" "model extraction"

log "STEP: Extracting 10Eros model artifact into /workspace"
ls -lh "$MODEL_ARCHIVE"
df -h /workspace
tar --zstd -xf "$MODEL_ARCHIVE" -C /workspace

log "Extraction finished"
du -sh "$COMFY_DIR/models" || true
df -h /workspace

[[ -f "$MODEL_MANIFEST" ]] \
  || fail "Archive did not contain /workspace/model-files.sha256"

log "STEP: Verifying every extracted model against model-files.sha256"
(
  cd /workspace
  sha256sum -c "$(basename "$MODEL_MANIFEST")"
)

log "Deleting compressed archive after successful extraction/verification"
rm -f "$MODEL_ARCHIVE" "$CHECKSUM_FILE"

log "Validating exact 10Eros beta_5 model pack"
python -u - <<'PY'
from pathlib import Path

base = Path("/workspace/ComfyUI/models")

files = {
    "10Eros-Max beta_5 non-Turbo INT8 diffusion": (
        base / "diffusion_models/10Eros_Max_h3_hybrid_beta5_int8.safetensors",
        20_000_000_000,
    ),
    "Qwen3-VL H3 NVFP4-AWQ text encoder": (
        base / "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
        15_000_000_000,
    ),
    "H3 video VAE FP16": (
        base / "vae/minimax_h3_video_vae_fp16.safetensors",
        5_000_000_000,
    ),
    "H3 audio VAE FP32": (
        base / "vae/minimax_h3_audio_vae_fp32.safetensors",
        500_000_000,
    ),
}

for label, (path, minimum) in files.items():
    if not path.is_file():
        raise SystemExit(f"Missing {label}: {path}")
    size = path.stat().st_size
    if size < minimum:
        raise SystemExit(f"{label} unexpectedly small: {size:,} bytes")
    print(f"OK  {label}: {size / (1024**3):.2f} GiB")

print("All four 10Eros/H3 files are present.")
PY

mark_model_pack_ready
rm -f "$MODEL_MANIFEST"
MODEL_PACK_READY=1
fi

log "Model pack state: ready=${MODEL_PACK_READY}"

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

log "Installing H3 services"
mkdir -p /opt/rosely-h3-serverless

cp "$APP_DIR/scripts/start_comfyui.sh" /opt/rosely-h3-serverless/
cp "$APP_DIR/scripts/start_model_server.sh" /opt/rosely-h3-serverless/
chmod +x /opt/rosely-h3-serverless/*.sh

cp \
  "$APP_DIR/supervisor/h3-services.conf" \
  /etc/supervisor/conf.d/h3-services.conf

supervisorctl reread
supervisorctl update

log "Waiting for H3 ComfyUI"
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

log "Waiting for H3 model server"
server_ok=0
for _ in $(seq 1 180); do
  if curl -fsS http://127.0.0.1:18288/health >/dev/null 2>&1; then
    server_ok=1
    break
  fi

  state=$(supervisorctl status h3-model-server 2>/dev/null | awk '{print $2}' || true)
  if [[ "$state" == "FATAL" || "$state" == "EXITED" ]]; then
    break
  fi
  sleep 2
done

(( server_ok == 1 )) || {
  supervisorctl status || true
  nvidia-smi || true
  tail -250 /var/log/portal/comfyui.log 2>/dev/null || true
  tail -250 /var/log/portal/model-server.log 2>/dev/null || true
  fail "H3 model server did not become healthy within 360 seconds"
}

log "PROVISIONING COMPLETE"
supervisorctl status h3-comfyui h3-model-server || true
curl -fsS http://127.0.0.1:18288/health || true
echo
nvidia-smi || true
df -h /workspace

log "Dedicated log: /var/log/portal/h3-provision.log"
