# 10Eros beta_5 update bundle

This ZIP contains **drop-in replacement files**, not the 35.7 GiB model bundle.

## Apply

From the root of your local clone:

```bash
unzip -o rosely-minimax-h3-10eros-beta5-update.zip -d .
chmod +x provision.sh
git status
git diff -- . ':!UPDATE_INSTRUCTIONS.md'
```

Review, then commit:

```bash
git add \
  provision.sh \
  .env.example \
  VAST_TEMPLATE_ARGS.txt \
  model_manifest.json \
  model_server.py \
  worker.py \
  test_vast_endpoint.py \
  workflows/minimax_h3_ref2va_api.json \
  README.md \
  README_PATCH.md \
  notebooks/test_vast_h3_serverless.ipynb

git commit -m "Deploy 10Eros beta5 non-Turbo INT8 bundle on RTX 5090"
git push
```

## Important

The updated provisioner expects these already-created S3 objects:

```text
s3://rosely-infrastructure/models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst
s3://rosely-infrastructure/models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst.sha256
```

The archive checksum is verified before extraction, and the `model-files.sha256`
inside the archive is verified after extraction.

The old ZIP path and HMNSFW LoRA are no longer used.
