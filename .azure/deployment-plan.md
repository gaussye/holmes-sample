# Holmes Sample Deployment Plan

**Status:** Deployed

## Scope and Constraints

- Repository: public GitHub repository `gaussye/holmes-sample`.
- Implementation: thin wrapper only; do not copy HolmesGPT source.
- Base image: `robustadev/holmes:0.39.0@sha256:035bb9f788c8a5df851b023d6b3be21384bff75b4496299a547fbf52b0fb67d8`.
- CLI wrapper: install `/usr/local/bin/holmes` as a POSIX shell script that runs `python3 /app/holmes_cli.py "$@"`.
- Read-only compatibility: if `HOME` is unset or not writable, set `HOME=/tmp` before execution.
- Preserve the base image entrypoint and default command. The Holmes Helm chart continues to override its command with `server.py`.
- Never store, print, or copy Azure OpenAI secret values.

## Azure Context

- Deployment recipe: Azure CLI + ACR Tasks + `kubectl apply`
- Subscription: `ME-MngEnvMCAP566860-pengyongye-1`
- Subscription ID: `3456866f-6478-471f-8d59-a29a335d797a`
- Region: `centralus`
- Resource group: `holmes-sample-rg`
- Azure Container Registry: `ypyholmespublic`
- ACR SKU: Standard
- ACR public network access: enabled
- ACR anonymous pull: enabled registry-wide; this registry is dedicated to this public sample.
- Existing AKS resource group: `test-aks_group`
- Existing AKS cluster: `test-aks`
- Existing Helm release/namespace: `holmes-default` / `holmes-default`
- Helm chart/version: `robusta/holmes` `0.39.0`

## Artifacts

- `Dockerfile`
- `bin/holmes`
- `deploy/kubernetes.yaml`
- `scripts/build-and-push.ps1`
- `.dockerignore`
- `.gitignore`
- `README.md`
- `.azure/deployment-plan.md`

## Build and Publish

1. Validate the wrapper and container build configuration.
2. Create or reconcile `holmes-sample-rg` in `centralus`.
3. Create or reconcile the dedicated Standard ACR `ypyholmespublic`.
4. Enable public network access and anonymous pull.
5. Build with ACR Tasks because local Docker is unavailable.
6. Publish `ypyholmespublic.azurecr.io/holmes-sample:0.39.0-cli.1`.
7. Publish the same image as `ypyholmespublic.azurecr.io/holmes-sample:latest`.
8. Record the resulting tags and digests.

## Reusable Kubernetes Deployment

1. Create the target namespace with `kubectl apply -f -`.
2. Build a Kubernetes Secret in memory from `AZURE_API_KEY`, `AZURE_API_BASE`, and `AZURE_API_VERSION`, then pipe it to `kubectl apply -f -`.
3. Apply `deploy/kubernetes.yaml` with `kubectl apply -f`.
4. Use the built-in read-only `view` ClusterRole and do not grant Secret read access.
5. Mount a non-sensitive model ConfigMap that resolves provider settings from environment variables.
6. Use a read-only root filesystem, writable `/tmp`, HTTP probes, a 2Gi Pod memory limit, and a 1500MiB tool subprocess limit.
7. Verify rollout and run the CLI with `kubectl exec`.

## Validation and Proof

- POSIX shell syntax passes for `bin/holmes`.
- PowerShell scripts parse successfully.
- Dockerfile uses the exact approved digest-pinned base image and preserves inherited entrypoint/default behavior.
- Rendered Helm manifests use the approved registry and image while retaining current model values and Secret references.
- Repository scan finds no committed secrets or secret values.
- ACR anonymous pull is enabled and the workload has no image pull secret or ACR pull attachment dependency.
- Pod reports the exact published image digest.
- HTTP health and readiness checks pass.
- `kubectl exec ... -- holmes ask --help` succeeds without manually setting `HOME`.
- A real non-interactive `holmes ask` Kubernetes query succeeds using model `gpt-5.3-codex`.
- Existing customized `holmes` and `holmes-ui` deployments remain unchanged.

## Delivery

1. Update this status to `Ready for Validation` after implementation and local/static verification.
2. Run the mandatory `azure-validate` workflow and record proof here.
3. Update this status to `Validated`.
4. Run the mandatory `azure-deploy` workflow.
5. Update this status to `Deployed` and record deployment proof.
6. Commit all repository files to `main` with the required co-author trailer and push to GitHub.
7. Report the repository URL, image pull command, tags/digests, ACR anonymous status, commit SHA, AKS rollout status, and CLI test result to the creator session.

## Validation Proof

**Validated at:** 2026-08-21T11:15:00+08:00

### Validation Steps

- [x] Azure CLI installation and authentication.
- [x] Approved subscription, region, and existing AKS target verification.
- [x] POSIX shell and PowerShell parser checks.
- [x] Digest-pinned Docker build-context inspection; local Docker build is intentionally replaced by ACR Tasks.
- [x] Helm chart 0.39.0 client rendering.
- [x] Helm server-side dry-run against the current release with reused values and hidden Secret manifests.
- [x] ACR name availability and Azure policy preflight.
- [x] Static RBAC review: no role assignments are generated; anonymous pull intentionally avoids an AKS `AcrPull` assignment.
- [x] Repository secret and Git diff checks.

- Azure context confirmed: the approved subscription is enabled; `test-aks` is running in `centralus` on Kubernetes 1.35.5.
- Existing release confirmed: `holmes-default` in namespace `holmes-default`, chart/app version 0.39.0, status deployed.
- Current user values contain only `additionalEnvVars` and `modelList`; the deployment path uses `--reuse-values` and does not print those values.
- `bin/holmes` passes POSIX shell syntax validation.
- Both PowerShell deployment scripts pass parser validation.
- Dockerfile uses the exact approved digest-pinned base image and does not override `ENTRYPOINT` or `CMD`.
- Helm 0.39.0 renders `ypyholmespublic.azurecr.io/holmes-sample:0.39.0-cli.1`, an empty `imagePullSecrets` configuration, a read-only root filesystem, writable `/tmp`, and the chart's `["python3", "-u", "server.py"]` command override.
- Helm server-side dry-run passed against the deployed release using `--reuse-values`, with Secret manifests hidden and output discarded.
- ACR name `ypyholmespublic` is available, the `Microsoft.ContainerRegistry` provider is registered, and the three enforced subscription policies target unrelated Defender data services.
- Azure CLI 2.81.0 supports the required Standard SKU, public-network, anonymous-pull, and multi-tag ACR Tasks arguments.
- The pinned public base image digest resolves successfully.
- Local Docker is unavailable by design; build execution is validated for ACR Tasks and will run only after the dedicated registry is provisioned.
- ACR Tasks classic-builder compatibility was proven with portable `COPY`, CRLF normalization, and `chmod`; successful final build ID: `cj4`.
- Repository security scan found no high-confidence private keys, API keys, bearer tokens, passwords, or Azure OpenAI credentials.
- Git whitespace validation passes.

## Deployment Record

**Deployed at:** 2026-08-21T11:31:00+08:00

- Resource group `holmes-sample-rg` is provisioned in `centralus`.
- Dedicated registry `ypyholmespublic` is Standard SKU with public network access and registry-wide anonymous pull enabled.
- ACR Task `cj4` built from the exact approved base digest.
- Tags `0.39.0-cli.1` and `latest` both resolve to `sha256:d99004a82983b412640062a655c5510f9c78d88da26d090641d09812624db75d`.
- The anonymous OAuth registry flow issued a pull-scoped token without credentials and returned HTTP 200 for the manifest at the exact final digest.
- The AKS kubelet identity has zero `AcrPull` assignments on this registry.
- Helm release `holmes-default` is deployed in namespace `holmes-default` with chart `holmes-0.39.0`.
- Deployment `holmes-default-holmes` has one desired and one ready replica.
- The running pod uses `ypyholmespublic.azurecr.io/holmes-sample:0.39.0-cli.1` at image ID `sha256:d99004a82983b412640062a655c5510f9c78d88da26d090641d09812624db75d`.
- The pod has no named image pull Secret.
- In-pod `/healthz` and `/readyz` checks both returned HTTP 200.
- `holmes ask --help` passed without manually setting `HOME`; the wrapper detected the read-only home and used `/tmp`.
- A non-interactive `holmes ask --model gpt-5.3-codex` Kubernetes query completed successfully and reported deployment and cluster health.
- Customized workloads in namespaces `holmes` and `holmes-ui` remained separate from the namespace-scoped Helm release and ready.
- The complete `scripts/deploy-aks.ps1 -RunLiveQuery` workflow exited successfully.

### Reusable Manifest Update

- The public distribution deployment method now uses `kubectl apply -f` instead of Helm.
- Provider credentials are absent from the manifest and repository.
- Azure API key, base URL, and API version are injected from a Kubernetes Secret populated from the deployer's local environment variables.
- `kubectl apply --dry-run=client --validate=strict` accepted all five manifest resources.
- The environment-to-Secret pipeline passed strict client validation without writing values to disk.
- The built-in `view` ClusterRole was confirmed not to grant Secret access.
- The model ConfigMap resolves all provider settings from runtime environment variables.
- The original Helm deployment record above remains historical proof for the existing `holmes-default` environment.

## Prometheus and Elasticsearch Integration Update

- Discover the existing in-cluster Prometheus and Elasticsearch Services.
- Add explicit `prometheus/metrics`, `elasticsearch/data`, and `elasticsearch/cluster` toolset configuration to the reusable ConfigMap.
- Resolve URLs and Elasticsearch Basic Auth from environment variables.
- Reuse or copy existing Kubernetes Secret references without reading, printing, or committing credential values.
- Update the English deployment documentation with the additional environment variables.
- Validate the manifest, Secret references, RBAC, toolset connectivity, and a real query before deployment.
- Deploy the `holmes-sample` namespace with `kubectl apply -f`.

### Integration Preparation Proof

- Discovered Prometheus at `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`; readiness returned HTTP 200.
- Discovered Elasticsearch at `http://elasticsearch-master.logging.svc.cluster.local:9200`; the API returned HTTP 200.
- Confirmed existing Elasticsearch Basic Auth Secret `logging/elasticsearch-master-credentials` contains `username` and `password` keys without reading their values.
- Added runtime-only Prometheus URL and Elasticsearch URL/username/password placeholders.
- Added `prometheus/metrics`, `elasticsearch/data`, and `elasticsearch/cluster`.
- Strict client-side Kubernetes schema validation and nested toolset YAML parsing passed.
- The built-in `view` role does not grant Kubernetes Secret access.
- Repository diff and credential-pattern scans passed.

### Integration Validation Proof

**Validated at:** 2026-08-21T13:52:00+08:00

- `kubectl apply --dry-run=client --validate=strict` accepted the reusable manifest.
- `kubectl auth reconcile --dry-run=client` accepted the ClusterRoleBinding.
- Python/PyYAML parsed all three nested Holmes toolset configurations.
- The Azure OpenAI key source was identified as a Secret key reference without reading its value.
- The Azure OpenAI base URL and API version sources were identified as existing non-secret environment values.
- The Elasticsearch credential copy pipeline passed strict Secret validation using only base64 payload transfer and no value output.
- Prometheus and Elasticsearch endpoints returned HTTP 200 from inside the cluster.
- Static RBAC verification confirmed the `view` role does not permit Secret reads.

### Integration Deployment Proof

**Deployed at:** 2026-08-21T13:53:17+08:00

- Standalone deployment `holmes-sample/holmes-sample` completed its rollout with one updated, available, and ready replica and zero container restarts.
- The running Pod uses `ypyholmespublic.azurecr.io/holmes-sample:0.39.0-cli.1` at image ID `sha256:d99004a82983b412640062a655c5510f9c78d88da26d090641d09812624db75d`.
- The Pod has no named image pull Secret and uses the read-only `holmes-sample` ServiceAccount.
- In-Pod `/healthz` and `/readyz` checks both returned HTTP 200.
- All seven required Secret keys are present; no credential values were displayed.
- Direct in-Pod Prometheus readiness and authenticated Elasticsearch API checks both returned HTTP 200.
- Holmes enabled `prometheus/metrics`, `elasticsearch/data`, and `elasticsearch/cluster` from the mounted configuration.
- A real non-interactive `holmes ask --model gpt-5.3-codex` invocation called all three toolsets successfully: Prometheus returned 28 `up` series, Elasticsearch cluster health was `green`, and Elasticsearch mappings returned index names.
- Live RBAC verification allows cluster-wide Pod listing through the built-in `view` role and denies Secret reads.
- ACR remains Standard with public network access and anonymous pull enabled; tags `0.39.0-cli.1` and `latest` resolve to the deployed digest.
- Existing deployment `holmes-default/holmes-default-holmes` remains ready on the same approved image.
