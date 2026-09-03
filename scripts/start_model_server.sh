#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p /var/log/portal
: > /var/log/portal/model-server.log

source /venv/main/bin/activate
cd /workspace/vast-pyworker

set -o pipefail
python -m uvicorn model_server:app \
  --host 127.0.0.1 \
  --port 18288 \
  --workers 1 \
  2>&1 | tee -a /var/log/portal/model-server.log
