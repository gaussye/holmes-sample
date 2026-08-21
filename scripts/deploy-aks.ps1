#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SubscriptionId = "3456866f-6478-471f-8d59-a29a335d797a",
    [string]$AksResourceGroup = "test-aks_group",
    [string]$AksCluster = "test-aks",
    [string]$Namespace = "holmes-default",
    [string]$Release = "holmes-default",
    [string]$ChartVersion = "0.39.0",
    [string]$RegistryName = "ypyholmespublic",
    [string]$Image = "ypyholmespublic.azurecr.io/holmes-sample:0.39.0-cli.1",
    [string]$Model = "gpt-5.3-codex",
    [switch]$ValidateOnly,
    [switch]$RunLiveQuery
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )

    $maxAttempts = if ($Command -eq "kubectl") { 3 } else { 1 }
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        & $Command @Arguments
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($attempt -lt $maxAttempts) {
            Write-Warning "kubectl failed; retrying in 10 seconds ($attempt/$maxAttempts)."
            Start-Sleep -Seconds 10
        }
    }

    throw "Command failed: $Command $($Arguments -join ' ')"
}

function Get-DeploymentTemplateHash {
    param([Parameter(Mandatory)][string]$Name)

    $json = & kubectl get deployment $Name --namespace $Namespace --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $template = ($json | ConvertFrom-Json).spec.template | ConvertTo-Json -Depth 100 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($template)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
}

foreach ($command in "az", "helm", "kubectl") {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "'$command' is required."
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$valuesPath = Join-Path $repoRoot "deploy\values.yaml"

Invoke-Native az account set --subscription $SubscriptionId
Invoke-Native az aks get-credentials `
    --resource-group $AksResourceGroup `
    --name $AksCluster `
    --subscription $SubscriptionId `
    --overwrite-existing `
    --output none

Invoke-Native helm repo add robusta https://robusta-charts.storage.googleapis.com --force-update
Invoke-Native helm repo update robusta

$releaseStatus = @(
    Invoke-Native helm list `
        --namespace $Namespace `
        --filter "^$([regex]::Escape($Release))$" `
        --output json | ConvertFrom-Json
)
if ($releaseStatus.Count -ne 1 -or $releaseStatus[0].chart -ne "holmes-$ChartVersion") {
    throw "Release '$Release' is not currently using Holmes chart 0.39.0."
}

$registry = Invoke-Native az acr show `
    --name $RegistryName `
    --subscription $SubscriptionId `
    --query "{id:id,anonymousPullEnabled:anonymousPullEnabled,publicNetworkAccess:publicNetworkAccess}" `
    --output json | ConvertFrom-Json
if (-not $registry.anonymousPullEnabled -or $registry.publicNetworkAccess -ne "Enabled") {
    throw "The dedicated registry is not configured for public anonymous pull."
}

$kubeletObjectId = Invoke-Native az aks show `
    --resource-group $AksResourceGroup `
    --name $AksCluster `
    --subscription $SubscriptionId `
    --query identityProfile.kubeletidentity.objectId `
    --output tsv
$acrPullCount = Invoke-Native az role assignment list `
    --assignee-object-id $kubeletObjectId `
    --scope $registry.id `
    --query "[?roleDefinitionName=='AcrPull'] | length(@)" `
    --output tsv
if ([int]$acrPullCount -ne 0) {
    throw "The AKS kubelet identity has AcrPull on this registry; anonymous-pull proof would be invalid."
}

$holmesHash = Get-DeploymentTemplateHash -Name "holmes"
$holmesUiHash = Get-DeploymentTemplateHash -Name "holmes-ui"

Write-Host "Validating the Helm upgrade against the existing release without displaying Secret manifests..."
Invoke-Native helm upgrade $Release robusta/holmes `
    --namespace $Namespace `
    --version $ChartVersion `
    --reuse-values `
    --values $valuesPath `
    --dry-run=server `
    --hide-secret | Out-Null

if ($ValidateOnly) {
    Write-Host "Helm server-side validation succeeded."
    return
}

Write-Host "Upgrading release '$Release'..."
Invoke-Native helm upgrade $Release robusta/holmes `
    --namespace $Namespace `
    --version $ChartVersion `
    --reuse-values `
    --values $valuesPath `
    --atomic `
    --wait `
    --timeout 10m

$deployment = "${Release}-holmes"
Invoke-Native kubectl rollout status "deployment/$deployment" --namespace $Namespace --timeout 5m

if ($holmesHash -ne (Get-DeploymentTemplateHash -Name "holmes")) {
    throw "Customized deployment 'holmes' changed during the release upgrade."
}
if ($holmesUiHash -ne (Get-DeploymentTemplateHash -Name "holmes-ui")) {
    throw "Customized deployment 'holmes-ui' changed during the release upgrade."
}

$podName = Invoke-Native kubectl get pods `
    --namespace $Namespace `
    --selector "app=holmes" `
    --field-selector status.phase=Running `
    --output "jsonpath={.items[0].metadata.name}"
if ([string]::IsNullOrWhiteSpace($podName)) {
    throw "No running pod was found for release '$Release'."
}

$pod = Invoke-Native kubectl get pod $podName --namespace $Namespace --output json | ConvertFrom-Json
$container = $pod.spec.containers | Where-Object { $_.image -eq $Image } | Select-Object -First 1
if (-not $container) {
    throw "Pod '$podName' is not running the exact expected image '$Image'."
}
$pullSecretNames = @(
    $pod.spec.imagePullSecrets |
        Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_.name) } |
        ForEach-Object { $_.name }
)
if ($pullSecretNames.Count -gt 0) {
    throw "Pod '$podName' has imagePullSecrets; anonymous-pull proof failed."
}

$containerStatus = $pod.status.containerStatuses | Where-Object { $_.name -eq $container.name }
if (-not $containerStatus.ready) {
    throw "Container '$($container.name)' is not ready."
}

foreach ($probeName in "livenessProbe", "readinessProbe") {
    $probe = $container.$probeName.httpGet
    if (-not $probe) {
        throw "Container '$($container.name)' has no HTTP $probeName."
    }

    $port = $probe.port
    if ($port -is [string]) {
        $port = ($container.ports | Where-Object { $_.name -eq $port }).containerPort
    }
    $scheme = if ($probe.scheme) { $probe.scheme.ToLowerInvariant() } else { "http" }
    $url = "${scheme}://127.0.0.1:${port}$($probe.path)"
    $python = "import urllib.request; r=urllib.request.urlopen('$url', timeout=10); print(r.status); assert 200 <= r.status < 400"
    $probeArgs = @(
        "exec", $podName,
        "--namespace", $Namespace,
        "--container", $container.name,
        "--", "python3", "-c", $python
    )
    Invoke-Native -Command kubectl -Arguments $probeArgs
}

$helpArgs = @(
    "exec", $podName,
    "--namespace", $Namespace,
    "--container", $container.name,
    "--", "holmes", "ask", "--help"
)
Invoke-Native -Command kubectl -Arguments $helpArgs | Out-Null
Write-Host "CLI help check succeeded without overriding HOME."

if ($RunLiveQuery) {
    $query = "List the Kubernetes namespaces and summarize unhealthy pods. Do not inspect or reveal Kubernetes Secrets."
    $queryArgs = @(
        "exec", $podName,
        "--namespace", $Namespace,
        "--container", $container.name,
        "--", "holmes", "ask", "--model", $Model, $query
    )
    Invoke-Native -Command kubectl -Arguments $queryArgs
    Write-Host "Live Holmes Kubernetes query succeeded with model '$Model'."
}

$imageId = $containerStatus.imageID
Write-Host "Rollout succeeded: $podName"
Write-Host "Image: $Image"
Write-Host "Image ID: $imageId"
Write-Host "Anonymous pull: enabled; imagePullSecrets: none; AKS AcrPull assignment: none"
