# Vast retry/storage fix

This patch fixes the worker-stuck-in-Loading failure observed on instance `51268483`.

## Root cause

The first provisioning attempt downloaded and extracted the model pack. Vast then invoked provisioning again while both the ~35.7 GiB archive and ~40 GiB extracted models were still present. The old provisioner performed an unconditional free-disk check before recognizing existing model state, so the retry failed with only ~43 GiB free.

## Fixes

- Provisioning is now idempotent.
- A verified model-ready marker is created after model validation.
- Existing valid extracted models are reused on retries.
- Existing models without a marker are SHA-256 verified once, then marked ready.
- A leftover valid `.tar.zst` is reused rather than downloaded again.
- Incomplete model files are removed before retry extraction to reclaim disk.
- The compressed archive is removed as soon as a valid extracted pack is available.
- Fresh-download and extraction disk checks are separate.
- `worker.py` now tracks `/var/log/portal/model-server.log` for the model server.

## Vast storage

Use **150 GiB** for new workers. 120 GiB can work with this fix, but 150 GiB gives materially safer headroom during model extraction, retries, logs, and generated-video staging.

Recommended env values:

```text
MIN_FREE_DISK_GB=85
MIN_EXTRACT_FREE_GB=45
```

## Current stuck worker

Because provisioning on the existing worker already exhausted all three attempts and SSH is unavailable, the clean path is:

1. Push this patch to `main`.
2. Terminate/recycle the stuck worker.
3. Change the Vast template disk to 150 GiB.
4. Create a new worker from the updated template.

The model bundle remains in S3 and does not need to be rebuilt.
