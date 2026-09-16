# 10Eros beta_5 deployment migration

Replace the files in `rosely-minimax-h3-10eros-beta5-update.zip` at the same
paths in the repository.

The migration changes the model artifact from the old ZIP pack:

```text
models/minimax-h3/rosely-h3-ref2va-quality-5090.zip
```

to:

```text
models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst
```

and changes the runtime from:

```text
NVFP4 Ref2VA base + HMNSFW LoRA
```

to:

```text
10Eros-Max beta_5 non-Turbo INT8
```

The new provisioner:

- downloads the single `.tar.zst` with concurrent S3 multipart transfer;
- validates the archive SHA-256 from S3;
- extracts into `/workspace`;
- validates each extracted model with `model-files.sha256`;
- removes the compressed archive to reclaim disk;
- starts ComfyUI and the model server only after all checks pass.

Keep standard AWS credential variable names unchanged:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
```

Use the Rosely namespaced H3 variables from `VAST_TEMPLATE_ARGS.txt`.
