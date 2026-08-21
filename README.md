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

This sample uses Azure OpenAI key authentication. If the target AI Services resource has local authentication disabled (`disableLocalAuth: true`), key-based model calls will fail; use a resource that permits key authentication or adapt the model configuration for Microsoft Entra authentication.

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

required = (
    "AZURE_API_KEY",
    "AZURE_API_BASE",
    "AZURE_API_VERSION",
)
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

## Adding more tools

The default deployment does not configure Prometheus or Elasticsearch. This keeps the sample portable for customers who only want to test Kubernetes troubleshooting. Add the integrations explicitly when the target cluster provides these services.

`holmes toolset list` shows `prometheus/metrics`, `elasticsearch/data`, and `elasticsearch/cluster` as `disabled` in the default deployment. Holmes may still auto-discover other built-in Kubernetes integrations when matching components exist in the cluster.

### Prometheus and Elasticsearch

The optional `deploy/observability-tools.yaml` manifest enables:

- `prometheus/metrics` for PromQL, metric discovery, and time-series analysis.
- `elasticsearch/data` for read-only index searches, mappings, and log/document analysis.
- `elasticsearch/cluster` for cluster health, nodes, shards, allocation, and index statistics.

Connection settings are resolved from a separate `holmes-observability-env` Secret. Prometheus requires only its URL in environments without authentication. Elasticsearch uses Basic Auth in this example. Grant the Elasticsearch user read-only access to the required indices and cluster monitoring privileges; do not use a superuser account.

For PowerShell 7, create the optional Secret directly from the current process:

```powershell
$env:PROMETHEUS_URL = "http://<prometheus-service>.<namespace>.svc.cluster.local:9090"
$env:ELASTICSEARCH_URL = "http://<elasticsearch-service>.<namespace>.svc.cluster.local:9200"
$env:ELASTICSEARCH_USERNAME = "<username>"
$env:ELASTICSEARCH_PASSWORD = Read-Host "Elasticsearch password" -MaskInput

$required = @(
    "PROMETHEUS_URL",
    "ELASTICSEARCH_URL",
    "ELASTICSEARCH_USERNAME",
    "ELASTICSEARCH_PASSWORD"
)
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
        name = "holmes-observability-env"
        namespace = "holmes-sample"
    }
    type = "Opaque"
    stringData = @{
        PROMETHEUS_URL = $env:PROMETHEUS_URL
        ELASTICSEARCH_URL = $env:ELASTICSEARCH_URL
        ELASTICSEARCH_USERNAME = $env:ELASTICSEARCH_USERNAME
        ELASTICSEARCH_PASSWORD = $env:ELASTICSEARCH_PASSWORD
    }
} | ConvertTo-Json -Depth 4 -Compress

$secret | kubectl apply -f -
Remove-Variable secret
Remove-Item Env:ELASTICSEARCH_PASSWORD
```

For Bash:

```bash
export PROMETHEUS_URL='http://<prometheus-service>.<namespace>.svc.cluster.local:9090'
export ELASTICSEARCH_URL='http://<elasticsearch-service>.<namespace>.svc.cluster.local:9200'
export ELASTICSEARCH_USERNAME='<username>'
read -rsp 'Elasticsearch password: ' ELASTICSEARCH_PASSWORD
export ELASTICSEARCH_PASSWORD
echo

python3 -c '
import json
import os

required = (
    "PROMETHEUS_URL",
    "ELASTICSEARCH_URL",
    "ELASTICSEARCH_USERNAME",
    "ELASTICSEARCH_PASSWORD",
)
missing = [name for name in required if not os.environ.get(name)]
if missing:
    raise SystemExit(f"Missing environment variables: {missing}")

print(json.dumps({
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": "holmes-observability-env",
        "namespace": "holmes-sample",
    },
    "type": "Opaque",
    "stringData": {name: os.environ[name] for name in required},
}))
' | kubectl apply -f -
unset ELASTICSEARCH_PASSWORD
```

Apply the optional tool configuration and restart Holmes so it reloads the mounted configuration:

```console
kubectl apply -f deploy/observability-tools.yaml
kubectl rollout restart deployment/holmes-sample -n holmes-sample
kubectl rollout status deployment/holmes-sample -n holmes-sample --timeout=5m
```

Verify both data sources:

```console
kubectl exec -n holmes-sample deployment/holmes-sample -c holmes -- \
  holmes toolset refresh
kubectl exec -n holmes-sample deployment/holmes-sample -c holmes -- \
  holmes toolset list

kubectl exec -n holmes-sample deployment/holmes-sample -c holmes -- \
  holmes ask --model gpt-5.3-codex --refresh-toolsets \
  "Verify Prometheus and Elasticsearch connectivity, then report Prometheus target health and Elasticsearch cluster health without exposing credentials."
```

To return to the default configuration:

```console
kubectl delete -f deploy/observability-tools.yaml --ignore-not-found
kubectl delete secret holmes-observability-env -n holmes-sample --ignore-not-found
kubectl rollout restart deployment/holmes-sample -n holmes-sample
```

## Adding custom skills

If you want to add a custom Holmes skill, follow the steps below. A skill is a procedural troubleshooting guide stored in a file named `SKILL.md`. Holmes reads each skill's description at startup, matches relevant skills to user questions, and loads the full instructions with its `fetch_skill` tool when needed.

### 1. Write the skill

Every `SKILL.md` must begin with YAML frontmatter. The `description` field is required and should clearly state when Holmes should use the skill.

```markdown
---
name: payment-troubleshooting
description: Troubleshoot pods, Prometheus metrics, and Elasticsearch logs for the payment service
---

## Goal

Identify the root cause of failures affecting the payment service.

## Workflow

1. Inspect the payment namespace, pods, events, and resource usage.
2. Query Prometheus for error rate, latency, CPU, and memory trends.
3. Query Elasticsearch for application errors and relevant stack traces.
4. Correlate Kubernetes, metric, and log evidence.
5. Report the root cause, remediation, and verification steps.

## Safety

- Do not read or reveal Kubernetes Secrets.
- Prefer read-only diagnostic operations.
```

### 2. Store skills in a ConfigMap

Add a ConfigMap to `deploy/kubernetes.yaml`. Use one ConfigMap key per skill:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-skills
  namespace: holmes-sample
data:
  payment.md: |
    ---
    name: payment-troubleshooting
    description: Troubleshoot pods, Prometheus metrics, and Elasticsearch logs for the payment service
    ---

    ## Workflow

    1. Inspect Kubernetes state.
    2. Query Prometheus metrics.
    3. Query Elasticsearch logs.
    4. Correlate the evidence and recommend remediation.
```

### 3. Mount and register the skill directory

Add the skill search path to the Holmes container:

```yaml
env:
  - name: CUSTOM_SKILL_PATHS
    value: /etc/holmes/skills
```

Add the volume mount to the Holmes container:

```yaml
volumeMounts:
  - name: skills
    mountPath: /etc/holmes/skills
    readOnly: true
```

Add the volume to the Pod specification:

```yaml
volumes:
  - name: skills
    configMap:
      name: holmes-skills
      items:
        - key: payment.md
          path: payment-troubleshooting/SKILL.md
```

The mounted filename must be `SKILL.md`. For multiple skills, add another ConfigMap key and map it to a separate `<skill-name>/SKILL.md` path. Holmes scans custom skill directories up to two levels deep.

### 4. Apply and reload

Apply the updated manifest and restart the Deployment so Holmes rebuilds its skill catalog:

```console
kubectl apply -f deploy/kubernetes.yaml
kubectl rollout restart deployment/holmes-sample -n holmes-sample
kubectl rollout status deployment/holmes-sample -n holmes-sample --timeout=5m
```

### 5. Trigger the skill

Ask a question that clearly matches the skill description:

```console
kubectl exec -n holmes-sample deployment/holmes-sample -c holmes -- \
  holmes ask --model gpt-5.3-codex \
  "Troubleshoot the payment service using Kubernetes status, Prometheus metrics, and Elasticsearch logs."
```

The skill description controls when the skill is selected; the Markdown body controls the diagnostic procedure Holmes follows after selection. If skills share the same normalized name, Holmes applies this priority order: remote Robusta skill, custom skill, then built-in skill.
