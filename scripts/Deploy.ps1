#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SubscriptionId,
    [string] $ResourceGroup = 'rg-aks-static-egress-demo',
    [string] $ClusterName = 'aks-static-egress-demo',
    [string] $Location = 'swedencentral',
    [string] $NodeVmSize = 'Standard_D4s_v5',
    [string] $KubernetesVersion = '',
    [string] $GatewaySubnetPrefix = '10.225.0.0/24',
    [string[]] $ApiServerAuthorizedIPRanges = @(),
    [switch] $WhatIf
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$root = Split-Path $PSScriptRoot -Parent
$template = Join-Path $root 'infra\main.bicep'
$local = Join-Path $root '.local'
$kubeConfig = Join-Path $local 'kubeconfig'
foreach ($tool in @('az', 'kubectl')) { $null = Get-Command $tool -ErrorAction Stop }
$cliVersion = (Invoke-Native az @('version', '--output', 'json') | ConvertFrom-Json).'azure-cli'
if ([version]$cliVersion -lt [version]'2.75.0') { throw 'Azure CLI 2.75.0 or later is required.' }
$null = Invoke-Native az @('account', 'show', '--subscription', $SubscriptionId, '--output', 'none')
$null = Invoke-Native az @('bicep', 'build', '--file', $template, '--stdout')
$null = Invoke-Native az @('group', 'create', '--subscription', $SubscriptionId,
    '--name', $ResourceGroup, '--location', $Location, '--output', 'none')

# JSON avoids shell-dependent array quoting in ARM parameter overrides.
$null = New-Item -ItemType Directory -Force -Path $local
$parameterFile = Join-Path $local 'deployment.parameters.json'
@{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        clusterName = @{ value = $ClusterName }
        location = @{ value = $Location }
        nodeVmSize = @{ value = $NodeVmSize }
        kubernetesVersion = @{ value = $KubernetesVersion }
        gatewaySubnetPrefix = @{ value = $GatewaySubnetPrefix }
        apiServerAuthorizedIPRanges = @{ value = @($ApiServerAuthorizedIPRanges) }
    }
} | ConvertTo-Json -Depth 8 | Set-Content -Path $parameterFile
$deploymentArgs = @('deployment', 'group')
if ($WhatIf) { $deploymentArgs += 'what-if' } else { $deploymentArgs += 'create' }
$deploymentArgs += @('--subscription', $SubscriptionId, '--resource-group', $ResourceGroup,
    '--name', 'aks-static-egress', '--template-file', $template, '--parameters', "@$parameterFile",
    '--query', 'properties.provisioningState', '--output', 'tsv')
Invoke-Native az $deploymentArgs | Write-Host
if ($WhatIf) {
    Write-Host 'What-if complete. No cluster or workloads were created; the resource group may have been created.'
    return
}
$null = Invoke-Native az @('aks', 'get-credentials', '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroup, '--name', $ClusterName,
    '--file', $kubeConfig, '--context', $ClusterName, '--overwrite-existing')
$kubeArgs = @('--kubeconfig', $kubeConfig, '--context', $ClusterName)
$deadline = [DateTime]::UtcNow.AddMinutes(5)
do {
    $crd = Invoke-Native kubectl ($kubeArgs + @('get', 'crd',
        'staticgatewayconfigurations.egressgateway.kubernetes.azure.com', '--ignore-not-found', '-o', 'name'))
    if ($crd) { break }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'AKS has not installed the Static Egress Gateway CRD after five minutes.' }
    Start-Sleep -Seconds 5
} while ($true)
Invoke-Native kubectl ($kubeArgs + @('wait', '--for=condition=Established',
    'crd/staticgatewayconfigurations.egressgateway.kubernetes.azure.com', '--timeout=300s')) | Write-Host
Invoke-Native kubectl ($kubeArgs + @('apply', '-f', (Join-Path $root 'infra\kubernetes\namespace.yaml'))) | Write-Host
Invoke-Native kubectl ($kubeArgs + @('apply', '-f', (Join-Path $root 'infra\crds\static-gateway-configuration.yaml'))) | Write-Host
Invoke-Native kubectl ($kubeArgs + @('wait', '--namespace', 'egress-demo',
    '--for=jsonpath={.status.egressIpPrefix}', 'staticgatewayconfiguration/static-egress', '--timeout=600s')) | Write-Host
Invoke-Native kubectl ($kubeArgs + @('apply', '-f', (Join-Path $root 'infra\kubernetes\applications.yaml'))) | Write-Host
foreach ($app in @('application-1', 'application-2')) {
    Invoke-Native kubectl ($kubeArgs + @('rollout', 'status', "deployment/$app",
        '--namespace', 'egress-demo', '--timeout=300s')) | Write-Host
}
& (Join-Path $PSScriptRoot 'Test-Egress.ps1') -SubscriptionId $SubscriptionId `
    -ResourceGroup $ResourceGroup -ClusterName $ClusterName -KubeConfig $kubeConfig
