# Scenario 72: IaC State Backends

Config-validation scenario testing all six `iac.state` backend types in a single config.

## What it tests

- `iac.state` with `backend: memory` (no config required)
- `iac.state` with `backend: filesystem` (path configured)
- `iac.state` with `backend: postgres` (connectionString + table)
- `iac.state` with `backend: gcs` (bucket + prefix + credentialsFile)
- `iac.state` with `backend: azure_blob` (storageAccount + container + blobPrefix)
- `iac.state` with `backend: s3` (bucket + region + prefix + encrypt)
- Per-backend plan pipelines for each of the 6 backends

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
