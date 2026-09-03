#!/usr/bin/env bash
set -euo pipefail

echo "=== Supervisor ==="
supervisorctl status h3-comfyui || true

echo
echo "=== GPU ==="
nvidia-smi || true

echo
echo "=== ComfyUI health ==="
curl -fsS http://127.0.0.1:18189/system_stats | jq . || true

echo
echo "=== H3 model files ==="
find /workspace/ComfyUI/models \
  -type f \
  -name '*.safetensors' \
  -printf '%s %p\n' \
  | sort -n || true

echo
echo "=== Disk ==="
df -h /workspace
