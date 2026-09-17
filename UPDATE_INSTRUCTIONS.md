# Apply retry/storage fix

Replace these files in the repo:

- `provision.sh`
- `worker.py`
- `.env.example`
- `VAST_TEMPLATE_ARGS.txt`
- `README.md`
- `RETRY_STORAGE_FIX.md` (new)

Then run:

```bash
chmod +x provision.sh
git add provision.sh worker.py .env.example VAST_TEMPLATE_ARGS.txt README.md RETRY_STORAGE_FIX.md
git commit -m "Make Vast H3 provisioning idempotent"
git push origin main
```

For the Vast template, use **150 GiB disk** and keep:

```text
MIN_FREE_DISK_GB=85
MIN_EXTRACT_FREE_GB=45
```

The S3 model keys stay unchanged:

```text
models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst
models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst.sha256
```
