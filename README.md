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

## Deploy with kubectl

The reusable manifest requires only `kubectl`. It creates a ServiceAccount, a cluster-wide binding to Kubernetes' built-in read-only `view` role, the Holmes model ConfigMap, a Service, and a Deployment. The public image needs no registry credentials.

The manifest deliberately does not contain provider credentials. It expects a Secret named `holmes-model-env` with these environment variables:

| Variable | Purpose |
| --- | --- |
| `AZURE_API_KEY` | Azure OpenAI API key |
| `AZURE_API_BASE` | Azure OpenAI endpoint, such as `https://<resource>.openai.azure.com` |
| `AZURE_API_VERSION` | API version supported by the deployment |

### PowerShell 7

Set the values only in the current process:

```powershell
$env:AZURE_API_KEY = Read-Host "Azure OpenAI API key" -MaskInput
$env:AZURE_API_BASE = "https://<resource>.openai.azure.com"
$env:AZURE_API_VERSION = "<api-version>"
```

Create the namespace and apply the Secret directly from memory. The credential is not written to disk:

```powershell
kubectl create namespace holmes-sample --dry-run=client -o yaml |
  kubectl apply -f -

$required = "AZURE_API_KEY", "AZURE_API_BASE", "AZURE_API_VERSION"
$missing = $required | Where-Object {
    [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_))
}
if ($missing) {
    throw "Missing environment variables: $($missing -join ', ')"
}

$secret = @{
    apiVersion = "v1"
    kind = "Secret"
    metadata = @{
        name = "holmes-model-env"
        namespace = "holmes-sample"
    }
    type = "Opaque"
    stringData = @{
        AZURE_API_KEY = $env:AZURE_API_KEY
        AZURE_API_BASE = $env:AZURE_API_BASE
        AZURE_API_VERSION = $env:AZURE_API_VERSION
    }
} | ConvertTo-Json -Depth 4 -Compress

$secret | kubectl apply -f -
Remove-Variable secret
Remove-Item Env:AZURE_API_KEY
```

Apply the workload and wait for readiness:

```powershell
kubectl apply -f .\deploy\kubernetes.yaml
kubectl rollout status deployment/holmes-sample -n holmes-sample --timeout=5m
```

### Bash

```bash
read -rsp 'Azure OpenAI API key: ' AZURE_API_KEY
export AZURE_API_KEY
echo
export AZURE_API_BASE='https://<resource>.openai.azure.com'
export AZURE_API_VERSION='<api-version>'

kubectl create namespace holmes-sample --dry-run=client -o yaml \
  | kubectl apply -f -

python3 -c '
import json
import os

required = ("AZURE_API_KEY", "AZURE_API_BASE", "AZURE_API_VERSION")
missing = [name for name in required if not os.environ.get(name)]
if missing:
    raise SystemExit(f"Missing environment variables: {missing}")

print(json.dumps({
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": "holmes-model-env", "namespace": "holmes-sample"},
    "type": "Opaque",
    "stringData": {name: os.environ[name] for name in required},
}))
' | kubectl apply -f -
unset AZURE_API_KEY

kubectl apply -f deploy/kubernetes.yaml
kubectl rollout status deployment/holmes-sample -n holmes-sample --timeout=5m
```

### Run the CLI

The Pod uses a read-only root filesystem and a writable `/tmp`. The `holmes` wrapper also detects an unwritable home directory automatically.

```console
kubectl exec -n holmes-sample deployment/holmes-sample -c holmes -- \
  holmes ask --model gpt-5.3-codex \
  "Check the cluster for unhealthy pods. Do not inspect Kubernetes Secrets."
```

For large clusters, prefer a focused prompt or ask Holmes to use `kubernetes_tabular_query`. The manifest sets `TOOL_MEMORY_LIMIT_MB=1500` while retaining the Pod's `2Gi` memory limit.

To update credentials, change the local environment variables, apply the Secret again, and restart the Deployment:

```console
kubectl rollout restart deployment/holmes-sample -n holmes-sample
```

No credentials or model secret values belong in this repository.
