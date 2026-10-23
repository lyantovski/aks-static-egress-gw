#Requires -Version 7.0
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')
$root = Split-Path $PSScriptRoot -Parent

foreach ($file in Get-ChildItem (Join-Path $root 'scripts\*.ps1')) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell syntax errors in $($file.Name): $errors" }
}
foreach ($case in @(
    @('203.0.113.0', '203.0.113.0/30', $true),
    @('203.0.113.3', '203.0.113.0/30', $true),
    @('203.0.113.4', '203.0.113.0/30', $false),
    @('202.0.113.1', '203.0.113.0/30', $false),
    @('255.255.255.255', '0.0.0.0/0', $true),
    @('203.0.113.1', '203.0.113.1/32', $true),
    @('203.0.113.2', '203.0.113.1/32', $false),
    @('10.255.1.1', '10.128.0.0/9', $true),
    @('10.127.1.1', '10.128.0.0/9', $false)
)) {
    if ((Test-IPv4InCidr $case[0] $case[1]) -ne $case[2]) { throw "CIDR assertion failed: $case" }
}
foreach ($invalid in @('203.0.113.0/33', '203.0.113.0/-1', '203.0.113.0/x', '203.0.113.0', '::/0')) {
    $threw = $false
    try { $null = Test-IPv4InCidr '203.0.113.1' $invalid } catch { $threw = $true }
    if (-not $threw) { throw "Invalid CIDR was accepted: $invalid" }
}

# Native-command stubs exercise the entire proof script without Azure credentials.
$global:aksEgressTestScenario = 'pass'
function az {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    if ($command -like 'aks show *') {
        return '{"id":"/subscriptions/test/resourceGroups/test/providers/Microsoft.ContainerService/managedClusters/test","nodeResourceGroup":"MC_test","networkProfile":{"outboundType":"userAssignedNATGateway"},"agentPoolProfiles":[{"name":"system","mode":"System"},{"name":"apps","mode":"User"},{"name":"staticegw","mode":"Gateway","vnetSubnetId":"/subnets/gateway"}]}'
    }
    if ($command -like 'network nat gateway list *') {
        $subnet = if ($global:aksEgressTestScenario -eq 'wrong-subnet') { '/subnets/other' } else { '/subnets/apps' }
        return "[{`"id`":`"/nat/demo`",`"subnets`":[{`"id`":`"$subnet`"}],`"publicIpAddresses`":[{`"id`":`"/publicIps/nat`"}]}]"
    }
    if ($command -like 'network public-ip show *') { return '{"ipAddress":"198.51.100.10"}' }
    if ($command -like 'network vnet subnet show *') {
        if ($global:aksEgressTestScenario -eq 'gateway-nat') { return '{"natGateway":{"id":"/nat/demo"}}' }
        return '{"id":"/subnets/gateway"}'
    }
    if ($command -like 'vmss show *') {
        if ($command -notlike '*--resource-group MC_test --name apps*' -or $command -like '*--ids*') {
            throw 'VMSS lookup must use the CLI-supported resource-group/name arguments.'
        }
        return '{"virtualMachineProfile":{"networkProfile":{"networkInterfaceConfigurations":[{"ipConfigurations":[{"subnet":{"id":"/subnets/apps"}}]}]}}}'
    }
    throw "Unexpected Azure CLI call: $command"
}
function kubectl {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    if ($command -like '* get staticgatewayconfiguration *') {
        return '{"spec":{"gatewayNodepoolName":"staticegw"},"status":{"egressIpPrefix":"203.0.113.0/30"}}'
    }
    if ($command -like '* get pods *') {
        $app = if ($command -like '*app=application-1*') { 'application-1' } else { 'application-2' }
        $annotation = if ($app -eq 'application-1') {
            ',"annotations":{"kubernetes.azure.com/static-gateway-configuration":"static-egress"}'
        } else { '' }
        return "{`"items`":[{`"metadata`":{`"name`":`"$app-pod`"$annotation},`"spec`":{`"nodeName`":`"apps-node`"}}]}"
    }
    if ($command -like '* get node *') {
        return '{"metadata":{"labels":{"kubernetes.azure.com/agentpool":"apps"}},"spec":{"providerID":"azure:///subscriptions/test/resourceGroups/MC_test/providers/Microsoft.Compute/virtualMachineScaleSets/apps/virtualMachines/0"}}'
    }
    if ($command -like '* exec application-1-pod *') {
        if ($global:aksEgressTestScenario -eq 'curl-failure') { $global:LASTEXITCODE = 7; return '' }
        if ($global:aksEgressTestScenario -eq 'wrong-gateway') { return '198.51.100.10' }
        return '203.0.113.2'
    }
    if ($command -like '* exec application-2-pod *') {
        if ($global:aksEgressTestScenario -eq 'wrong-nat') { return '192.0.2.5' }
        return '198.51.100.10'
    }
    throw "Unexpected kubectl call: $command"
}
$evidencePath = Join-Path ([System.IO.Path]::GetTempPath()) "aks-egress-test-$([guid]::NewGuid()).json"
try {
    & (Join-Path $root 'scripts\Test-Egress.ps1') -SubscriptionId test -ClusterName test -EvidencePath $evidencePath
    $evidence = Get-Content $evidencePath -Raw | ConvertFrom-Json
    if ($evidence.observations.Count -ne 6 -or @($evidence.observations | Where-Object { -not $_.passed }).Count) {
        throw 'Expected six passing observations.'
    }
    foreach ($failure in @(
        @('wrong-gateway', 'application-1 sample 1 failed:*'),
        @('wrong-nat', 'application-2 sample 1 failed:*'),
        @('wrong-subnet', 'The NAT gateway is not attached to the apps subnet:*'),
        @('gateway-nat', 'The gateway subnet must not have a NAT gateway attached.'),
        @('curl-failure', 'kubectl failed (exit 7):*')
    )) {
        $global:aksEgressTestScenario = $failure[0]
        $caught = $false
        try {
            & (Join-Path $root 'scripts\Test-Egress.ps1') -SubscriptionId test -ClusterName test -EvidencePath $evidencePath
        } catch {
            if ($_.Exception.Message -notlike $failure[1]) { throw }
            $caught = $true
        }
        if (-not $caught) { throw "Proof did not reject scenario: $global:aksEgressTestScenario" }
    }
} finally {
    if (Test-Path $evidencePath) { Remove-Item -LiteralPath $evidencePath }
    Remove-Item Function:\az, Function:\kubectl
    Remove-Variable aksEgressTestScenario -Scope Global
}
$global:LASTEXITCODE = 0
Write-Host 'PASS: syntax, IPv4 CIDR boundaries, complete proof flow, wrong routes, subnet attachment, and native failure handling.'
