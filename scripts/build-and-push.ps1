#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SubscriptionId = "3456866f-6478-471f-8d59-a29a335d797a",
    [string]$Location = "centralus",
    [string]$ResourceGroup = "holmes-sample-rg",
    [string]$RegistryName = "ypyholmespublic",
    [string]$Repository = "holmes-sample",
    [string]$VersionTag = "0.39.0-cli.1"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

Invoke-Az account set --subscription $SubscriptionId
$account = Invoke-Az account show --query "{id:id,state:state}" --output json | ConvertFrom-Json
if ($account.id -ne $SubscriptionId -or $account.state -ne "Enabled") {
    throw "The approved Azure subscription is not active."
}

Write-Host "Reconciling resource group '$ResourceGroup' in '$Location'..."
Invoke-Az group create `
    --name $ResourceGroup `
    --location $Location `
    --subscription $SubscriptionId `
    --output none

$registry = & az acr show `
    --name $RegistryName `
    --subscription $SubscriptionId `
    --output json 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating dedicated Standard registry '$RegistryName'..."
    Invoke-Az acr create `
        --name $RegistryName `
        --resource-group $ResourceGroup `
        --location $Location `
        --sku Standard `
        --public-network-enabled true `
        --subscription $SubscriptionId `
        --output none
} else {
    $registryDetails = $registry | ConvertFrom-Json
    if ($registryDetails.resourceGroup -ne $ResourceGroup) {
        throw "Registry '$RegistryName' exists in resource group '$($registryDetails.resourceGroup)', not '$ResourceGroup'."
    }
    if ($registryDetails.sku.name -ne "Standard") {
        throw "Registry '$RegistryName' is not Standard SKU; refusing to change its SKU automatically."
    }
}

Write-Host "Enabling public networking and anonymous pull for the dedicated sample registry..."
Invoke-Az acr update `
    --name $RegistryName `
    --public-network-enabled true `
    --anonymous-pull-enabled true `
    --subscription $SubscriptionId `
    --output none

Write-Host "Building '$Repository' with ACR Tasks and publishing '$VersionTag' and 'latest'..."
Push-Location $repoRoot
try {
    Invoke-Az acr build `
        --registry $RegistryName `
        --image "${Repository}:${VersionTag}" `
        --image "${Repository}:latest" `
        --subscription $SubscriptionId `
        .
} finally {
    Pop-Location
}

$versionDigest = Invoke-Az acr manifest show-metadata `
    --registry $RegistryName `
    --name "${Repository}:${VersionTag}" `
    --subscription $SubscriptionId `
    --query digest `
    --output tsv
$latestDigest = Invoke-Az acr manifest show-metadata `
    --registry $RegistryName `
    --name "${Repository}:latest" `
    --subscription $SubscriptionId `
    --query digest `
    --output tsv

if ([string]::IsNullOrWhiteSpace($versionDigest) -or $versionDigest -ne $latestDigest) {
    throw "Published image tags are missing or do not resolve to the same digest."
}

Write-Host "Published ypyholmespublic.azurecr.io/${Repository}:${VersionTag}"
Write-Host "Published ypyholmespublic.azurecr.io/${Repository}:latest"
Write-Host "Digest: $versionDigest"
