# H3 namespaced S3 environment patch

Replace these files in the repository:

- `provision.sh`
- `model_server.py`
- `.env.example`

Then:

```bash
chmod +x provision.sh
git add provision.sh model_server.py .env.example
git commit -m "Namespace H3 S3 environment variables"
git push origin main
```

## Vast template

Remove the old generic variables:

```text
S3_BUCKET
S3_REGION
S3_MODEL_KEY
S3_CHECKSUM_KEY
S3_OUTPUT_BUCKET
S3_OUTPUT_PREFIX
S3_PRESIGNED_URL_EXPIRES_SECONDS
S3_DOWNLOAD_CONCURRENCY
S3_DOWNLOAD_CHUNK_MIB
S3_ENDPOINT_URL
```

Use the `VAST_TEMPLATE_ARGS.txt` values instead.

Do NOT rename:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
```

Those are standard boto3 credential variables.

The new provisioner explicitly ignores a runtime `S3_BUCKET` even if Vast or
`/workspace/.env` injects one. The first H3 provisioning lines should show:

```text
H3 S3: s3://rosely-infrastructure/models/minimax-h3/...
```
