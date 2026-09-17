# Rosely H3 Vast PyWorker readiness fix

Replace the repository-root `worker.py` with this file.

Changes:
- Watches `/var/log/portal/comfyui.log`, matching Vast's official WAN/ComfyUI worker.
- Uses only `To see the GUI go to:` as the startup/load marker.
- Removes `Prompt executed` from `on_load`.
- Keeps health checking on `http://127.0.0.1:18288/health`.
- Gives benchmark requests a per-worker request id where possible.
- Keeps the existing `/generate/sync` request contract.

No changes are required to the S3 bundle or the 120 GB disk setting.

Apply:
    git add worker.py
    git commit -m "Fix Vast PyWorker readiness detection"
    git push origin main

Then recycle/recreate the stuck worker so it clones the updated `main`.
