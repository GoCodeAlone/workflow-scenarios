# Scenario 76: Tofu Generate Pipeline (Multi-Cloud)

Config-validation scenario for HCL generation across all four supported cloud providers.

## What it tests

One `tofu.generator` per provider:
- `aws-tofu` — `hashicorp/aws ~> 5.0`, backend: s3, outputDir: /tmp/tofu-output/aws
- `gcp-tofu` — `hashicorp/google ~> 5.0`, backend: gcs, outputDir: /tmp/tofu-output/gcp
- `azure-tofu` — `hashicorp/azurerm ~> 3.0`, backend: azurerm, outputDir: /tmp/tofu-output/azure
- `do-tofu` — `digitalocean/digitalocean ~> 2.0`, backend: local, outputDir: /tmp/tofu-output/digitalocean

`step.iac_generate_hcl` steps for each provider's VPC resource, plus a `generate-all` pipeline.

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live Tofu execution or cloud credentials required.
