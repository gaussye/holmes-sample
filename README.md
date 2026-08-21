# holmes-sample

A minimal public image layer that adds a `holmes` command to the official HolmesGPT 0.39.0 image. It does not vendor or copy the HolmesGPT source.

The image is based on the exact pinned artifact:

```text
robustadev/holmes:0.39.0@sha256:035bb9f788c8a5df851b023d6b3be21384bff75b4496299a547fbf52b0fb67d8
```

The wrapper executes:

```text
python3 /app/holmes_cli.py "$@"
```

If `HOME` is unset or not writable, it uses `/tmp`. This makes the CLI work in the official Helm chart's read-only root filesystem without changing the inherited image entrypoint or default command.

## Pull

```console
docker pull ypyholmespublic.azurecr.io/holmes-sample:0.39.0-cli.1
```

Anonymous pull is enabled on the dedicated public sample registry, so authentication is not required.

## Build and publish

PowerShell 7 and Azure CLI are required. The script uses ACR Tasks; local Docker is not required.

```powershell
.\scripts\build-and-push.ps1
```

The script safely reconciles the approved resource group and dedicated Standard ACR, enables anonymous pull, and publishes both `0.39.0-cli.1` and `latest`.

## Deploy to AKS

PowerShell 7, Azure CLI, Helm, and kubectl are required.

Validate the upgrade against the current release:

```powershell
.\scripts\deploy-aks.ps1 -ValidateOnly
```

Upgrade and verify the release:

```powershell
.\scripts\deploy-aks.ps1 -RunLiveQuery
```

The deployment reuses the current `holmes-default` release values so existing Azure model settings and Kubernetes Secret references remain intact. It changes only the top-level registry and image values, and verifies that the customized `holmes` and `holmes-ui` deployment pod templates are unchanged.

No credentials or model secret values belong in this repository. Supply sensitive settings through the existing Kubernetes Secrets.
