#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SubscriptionId,
    [string] $ResourceGroup = 'rg-aks-static-egress-demo',
    [string] $ClusterName = 'aks-static-egress-demo',
    [string] $KubeConfig = (Join-Path (Split-Path $PSScriptRoot -Parent) '.local\kubeconfig'),
    [ValidateRange(1, 20)][int] $Samples = 3,
    [string] $EvidencePath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.local\egress-proof.json')
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$kubeArgs = @('--kubeconfig', $KubeConfig, '--context', $ClusterName)
$cluster = Invoke-Native az @('aks', 'show', '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroup, '--name', $ClusterName, '--output', 'json') | ConvertFrom-Json
if ($cluster.networkProfile.outboundType -ne 'userAssignedNATGateway') {
    throw 'The cluster outbound type is not userAssignedNATGateway.'
}
$pools = @($cluster.agentPoolProfiles)
if ($pools.Count -ne 3 -or
    @($pools | Where-Object { $_.name -eq 'system' -and $_.mode -eq 'System' }).Count -ne 1 -or
    @($pools | Where-Object { $_.name -eq 'apps' -and $_.mode -eq 'User' }).Count -ne 1 -or
    @($pools | Where-Object { $_.name -eq 'staticegw' -and $_.mode -eq 'Gateway' }).Count -ne 1) {
    throw 'Expected exactly system (System), apps (User), and staticegw (Gateway) pools.'
}
$config = Invoke-Native kubectl ($kubeArgs + @('get', 'staticgatewayconfiguration', 'static-egress',
    '-n', 'egress-demo', '-o', 'json')) | ConvertFrom-Json
if ($config.spec.gatewayNodepoolName -ne 'staticegw') { throw 'Unexpected gateway pool in custom resource.' }
$prefix = [string]$config.status.egressIpPrefix
if ([string]::IsNullOrWhiteSpace($prefix)) { throw 'The gateway has not received an egress prefix.' }

$natGateways = @(Invoke-Native az @('network', 'nat', 'gateway', 'list',
    '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup,
    '--output', 'json') | ConvertFrom-Json)
if ($natGateways.Count -ne 1) { throw "Expected one demo NAT gateway, found $($natGateways.Count)." }
$nat = $natGateways[0]
if (@($nat.subnets).Count -eq 0) { throw 'The NAT gateway is not attached to any subnet.' }
$gatewayPool = @($pools | Where-Object name -eq 'staticegw')[0]
$gatewaySubnetId = [string]$gatewayPool.vnetSubnetId
if ([string]::IsNullOrWhiteSpace($gatewaySubnetId)) { throw 'The gateway must use an explicit dedicated subnet.' }
$gatewaySubnet = Invoke-Native az @('network', 'vnet', 'subnet', 'show', '--ids', $gatewaySubnetId,
    '--output', 'json') | ConvertFrom-Json
$gatewayNat = $gatewaySubnet.PSObject.Properties['natGateway']
if ($gatewayNat -and $null -ne $gatewayNat.Value) {
    throw 'The gateway subnet must not have a NAT gateway attached.'
}
$natIps = @(
    foreach ($reference in $nat.publicIpAddresses) {
        $publicIp = Invoke-Native az @('network', 'public-ip', 'show', '--subscription', $SubscriptionId,
            '--ids', $reference.id, '--output', 'json') | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($publicIp.ipAddress)) { throw 'NAT public IP is not allocated.' }
        [string]$publicIp.ipAddress
    }
)
if ($natIps.Count -ne 1) { throw 'Expected exactly one NAT outbound IPv4 address.' }
if (Test-IPv4InCidr $natIps[0] $prefix) { throw 'NAT public IP overlaps the static gateway prefix.' }
$observations = @(
    foreach ($app in @('application-1', 'application-2')) {
        $pods = Invoke-Native kubectl ($kubeArgs + @('get', 'pods', '-n', 'egress-demo',
            '-l', "app=$app", '-o', 'json')) | ConvertFrom-Json
        $activePods = @($pods.items | Where-Object { -not $_.metadata.PSObject.Properties['deletionTimestamp'] })
        if ($activePods.Count -ne 1) { throw "Expected one active pod for $app." }
        $pod = $activePods[0]
        $node = Invoke-Native kubectl ($kubeArgs + @('get', 'node', $pod.spec.nodeName, '-o', 'json')) | ConvertFrom-Json
        if ($node.metadata.labels.'kubernetes.azure.com/agentpool' -ne 'apps') {
            throw "$app is not running on the apps node pool."
        }
        if ($app -eq 'application-2') {
            $vmssId = ($node.spec.providerID -replace '^azure://', '') -replace '/virtualMachines/[^/]+$', ''
            $vmssMatch = [regex]::Match($vmssId,
                '(?i)^/subscriptions/[^/]+/resourceGroups/([^/]+)/providers/Microsoft\.Compute/virtualMachineScaleSets/([^/]+)$')
            if (-not $vmssMatch.Success) {
                throw "Unexpected VM scale set provider ID: $($node.spec.providerID)"
            }
            if ($vmssMatch.Groups[1].Value -ne $cluster.nodeResourceGroup) {
                throw 'The apps node is not in the cluster node resource group.'
            }
            $vmss = Invoke-Native az @('vmss', 'show', '--subscription', $SubscriptionId,
                '--resource-group', $vmssMatch.Groups[1].Value,
                '--name', $vmssMatch.Groups[2].Value, '--output', 'json') | ConvertFrom-Json
            $appsSubnetIds = @(
                foreach ($nic in $vmss.virtualMachineProfile.networkProfile.networkInterfaceConfigurations) {
                    foreach ($ipConfig in $nic.ipConfigurations) { [string]$ipConfig.subnet.id }
                }
            )
            if ($appsSubnetIds.Count -eq 0) { throw 'Cannot determine the apps node subnet.' }
            foreach ($subnetId in $appsSubnetIds) {
                if ($nat.subnets.id -notcontains $subnetId) {
                    throw "The NAT gateway is not attached to the apps subnet: $subnetId"
                }
            }
        }
        $annotation = $pod.metadata.PSObject.Properties['annotations']
        $gatewayAnnotation = if ($annotation) {
            $annotation.Value.PSObject.Properties['kubernetes.azure.com/static-gateway-configuration']
        } else { $null }
        if ($app -eq 'application-1' -and (-not $gatewayAnnotation -or $gatewayAnnotation.Value -ne 'static-egress')) {
            throw 'Application 1 does not have the expected pod gateway annotation.'
        }
        if ($app -eq 'application-2' -and $gatewayAnnotation) { throw 'Application 2 must not be gateway annotated.' }
        for ($sample = 1; $sample -le $Samples; $sample++) {
            $observed = (Invoke-Native kubectl ($kubeArgs + @('exec', $pod.metadata.name,
                '-n', 'egress-demo', '-c', 'probe', '--', 'curl', '--ipv4', '--fail', '--silent',
                '--show-error', '--noproxy', '*', '--connect-timeout', '10', '--max-time', '30',
                'https://api.ipify.org'))).Trim()
            $viaGateway = Test-IPv4InCidr $observed $prefix
            $viaNat = $natIps -contains $observed
            if (($app -eq 'application-1' -and (-not $viaGateway -or $viaNat)) -or
                ($app -eq 'application-2' -and (-not $viaNat -or $viaGateway))) {
                throw "$app sample $sample failed: observed $observed; gateway $prefix; NAT $($natIps -join ', ')."
            }
            [pscustomobject]@{
                application = $app
                pod = $pod.metadata.name
                node = $pod.spec.nodeName
                sample = $sample
                observedIp = $observed
                expectedPath = if ($viaGateway) { 'StaticEgressGateway' } else { 'userAssignedNATGateway' }
                passed = $true
                timestampUtc = [DateTime]::UtcNow.ToString('o')
            }
        }
    }
)
$evidence = [ordered]@{
    clusterId = $cluster.id
    gatewayPrefix = $prefix
    gatewaySubnetId = $gatewaySubnetId
    natGatewayId = $nat.id
    natSubnetIds = @($nat.subnets.id)
    appsSubnetIds = $appsSubnetIds
    natPublicIps = $natIps
    endpoint = 'https://api.ipify.org'
    observations = $observations
}
$parent = Split-Path $EvidencePath -Parent
if ($parent) { $null = New-Item -ItemType Directory -Force -Path $parent }
$evidence | ConvertTo-Json -Depth 8 | Set-Content -Path $EvidencePath
$observations | Format-Table application, sample, observedIp, expectedPath, passed
Write-Host "PASS: every sample matched its expected outbound path. Evidence: $EvidencePath"
