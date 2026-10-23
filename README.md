# AKS Static Egress Gateway and NAT Gateway

Deploy AKS in **Sweden Central (`swedencentral`)**, with three node pools and two
demo applications that prove their public outbound IPs.

| Application | Pod configuration | Expected internet source address |
| --- | --- | --- |
| `application-1` | Static gateway annotation | An IP inside the Static Egress Gateway prefix |
| `application-2` | No gateway annotation | The subnet's Azure NAT Gateway public IP |

## Important: why userAssignedNATGateway, not managedNATGateway?

The original request used `managedNATGateway`. Live deployment exposed a conflict:
all pools shared the managed subnet, and **NAT Gateway took precedence over the
gateway nodes' public IPs**. Both apps used the NAT IP despite a healthy gateway
custom resource. Trying to add a separate gateway subnet failed with:

```text
Cannot use a custom subnet because agent pool system is using a managed subnet.
Please omit the vnetSubnetID parameter from the request.
```

The approved correction is a custom VNet with two subnets and
**`outboundType: userAssignedNATGateway`**. It uses the same Azure NAT Gateway
service, explicitly provisioned by Bicep instead of owned by AKS. Only the
system/apps subnet has NAT attached. The gateway subnet must have **no NAT**.
This is an intentional change from the initial request, not a claim that managed
NAT supports separate source IPs in the original shared-subnet configuration.

## Architecture

```text
Custom VNet: 10.224.0.0/12
|
+-- nodes subnet: 10.224.0.0/16, Azure NAT Gateway attached
|   +-- system: System mode, 2 nodes, CriticalAddonsOnly taint
|   +-- apps: User mode, 1 node
|       +-- application-1 -- WireGuard tunnel ---------------+
|       +-- application-2 -- NAT Gateway --> Internet        |
|                                                           |
+-- static-egress subnet: 10.225.0.0/24, NO NAT                |
    +-- staticegw: Gateway mode, 2 nodes <--------------------+
        +-- public IPs from a /30 prefix --> Internet
```

The conceptual `static-egress-gw` pool is named **`staticegw`** because Linux AKS
pool names must be lowercase alphanumeric, begin with a letter, and be 1-12
characters. Both applications run on **apps**, never on gateway nodes.

Day-0 decisions: AKS Standard for explicit pool control; Azure CNI Overlay;
IPv4-only; custom VNet; separate non-NAT gateway subnet; public API server.
Pod CIDR `10.244.0.0/16` and service CIDR `10.0.0.0/16` do not overlap the VNet.
The cluster uses a user-assigned identity with Network Contributor scoped to this
VNet. No credentials are stored in the templates.

Gateway nodes have explicit **node public IPs for bootstrap** because their subnet
has neither NAT nor implicit outbound access. These are separate from the
controller-managed `/30` prefix used by annotated applications. Application and
system nodes do not have instance public IPs.

This is a **demo, not a production baseline**: one apps node, one replica per app,
no availability-zone distribution, private API server, Entra integration, or
managed monitoring stack. Kubernetes RBAC is enabled; kubeconfig uses AKS local
certificate authentication and must be protected as a credential. Production
should use Entra/Azure RBAC, disable local accounts, restrict API access, and add
appropriate zonal/workload redundancy and observability.

## Files

```text
infra\
  main.bicep                          VNet, subnets, NAT/IP, NSG, identity/RBAC, AKS and pools
  main.bicepparam                     Example deployment parameters
  crds\
    static-gateway-configuration.yaml Gateway custom resource (AKS installs its CRD)
  kubernetes\
    namespace.yaml                    egress-demo
    applications.yaml                 Shared probe ConfigMap and two Deployments
scripts\
  Deploy.ps1                          Infrastructure, workloads, waits, live proof
  Test-Egress.ps1                      Independent proof and JSON evidence
  Common.ps1                          Checked native execution and IPv4 CIDR helper
tests\
  Test-Local.ps1                       Offline positive/negative proof tests
.local\                               Ignored kubeconfig, parameters, evidence
```

## Prerequisites

* PowerShell 7+, Azure CLI 2.75.0+, current Azure CLI-managed Bicep, and a compatible
  kubectl. Commands below use PowerShell, not Bash.
* An Azure subscription and permission to create AKS, networking, identities,
  compute, and **role assignments**. Contributor alone cannot grant the identity's
  VNet role. Use appropriately scoped permissions, such as Contributor plus Role
  Based Access Control Administrator; Owner is a broader lab option.
* Sweden Central capacity/quota for five `Standard_D4s_v5` nodes (20 vCPUs), plus
  maintenance capacity, public IP prefix and NAT quota. Availability is
  subscription-specific; use `-NodeVmSize` to change the SKU.
* Workstation access to Azure and the AKS API; pod access to the container registry
  and `https://api.ipify.org`. The external IP echo service sees the public source
  IP. Use only where organizational egress/data policy allows it.

```powershell
# Windows installation if needed; reopen PowerShell afterward:
winget install --id Microsoft.PowerShell --exact
winget install --id Microsoft.AzureCLI --exact

az login
az aks install-cli
az bicep install
# If already installed but outdated:
az bicep upgrade
az version
az bicep version
kubectl version --client
```

Choose a subscription explicitly. Scripts pass it on each Azure operation and do
not change your global CLI default:

```powershell
$SubscriptionId = '<your-subscription-id>'
$ResourceGroup = 'rg-aks-static-egress-demo'
$ClusterName = 'aks-static-egress-demo'
$Location = 'swedencentral'

az account show --subscription $SubscriptionId -o table
foreach ($Provider in @('Microsoft.ContainerService', 'Microsoft.Network',
  'Microsoft.Compute', 'Microsoft.ManagedIdentity')) {
  az provider register --namespace $Provider --subscription $SubscriptionId --wait
}
az aks get-versions --location $Location --subscription $SubscriptionId -o table
az vm list-usage --location $Location --subscription $SubscriptionId -o table
```

The template leaves Kubernetes version unset to use AKS's regional supported
default. Pass `-KubernetesVersion` to pin an available version.

## Automated deployment

Run from the repository root. Deployment is **billable**.

```powershell
# Local checks, no Azure deployment:
az bicep build --file .\infra\main.bicep --stdout
az bicep build-params --file .\infra\main.bicepparam --stdout
.\tests\Test-Local.ps1

# What-if creates/updates the resource group, but not the cluster:
.\scripts\Deploy.ps1 -SubscriptionId $SubscriptionId -WhatIf

# Creates infrastructure, starts both apps, and asserts live egress:
.\scripts\Deploy.ps1 -SubscriptionId $SubscriptionId `
  -ResourceGroup $ResourceGroup -ClusterName $ClusterName -Location $Location
```

Optional parameters include `-NodeVmSize`, `-KubernetesVersion`,
`-GatewaySubnetPrefix` (inside the VNet and non-overlapping with the nodes subnet),
and `-ApiServerAuthorizedIPRanges @('<workstation-public-ip>/32')`.

The script uses template defaults and command-line overrides, **not**
`main.bicepparam`. To use edited pool counts in that file:

```powershell
az group create --subscription $SubscriptionId -n $ResourceGroup -l $Location
az deployment group validate --subscription $SubscriptionId -g $ResourceGroup `
  --parameters .\infra\main.bicepparam
az deployment group create --subscription $SubscriptionId -g $ResourceGroup `
  --name aks-static-egress --parameters .\infra\main.bicepparam
# Then follow manual steps 5-8 below.
```

Pool mutations are serialized. `Deploy.ps1` writes isolated credentials to
`.local\kubeconfig`, waits for the AKS-installed CRD, applies namespace and custom
resource, waits for its assigned egress prefix, then applies both applications.
Native failures, readiness timeouts, rollouts, and egress mismatches terminate the
script. Failed resources are retained for diagnosis, not silently deleted.

## Manual deployment: every step

This is an **alternative** to automation. Do not create both paths against the
same existing cluster. Check `$LASTEXITCODE` after each manual native command and
stop on errors. Use the variables from Prerequisites.

### 1. Create the network and NAT Gateway

```powershell
$VnetName = "$ClusterName-vnet"
$NsgName = "$ClusterName-nodes-nsg"
$NatName = "$ClusterName-nat"
$NatIpName = "$ClusterName-nat-ip"
$IdentityName = "$ClusterName-identity"

az group create --subscription $SubscriptionId -n $ResourceGroup -l $Location
az network public-ip create --subscription $SubscriptionId -g $ResourceGroup `
  -n $NatIpName -l $Location --sku Standard --allocation-method Static
az network nat gateway create --subscription $SubscriptionId -g $ResourceGroup `
  -n $NatName -l $Location --public-ip-addresses $NatIpName --idle-timeout 4
az network nsg create --subscription $SubscriptionId -g $ResourceGroup `
  -n $NsgName -l $Location
az network vnet create --subscription $SubscriptionId -g $ResourceGroup `
  -n $VnetName -l $Location --address-prefixes 10.224.0.0/12

az network vnet subnet create --subscription $SubscriptionId -g $ResourceGroup `
  --vnet-name $VnetName -n nodes --address-prefixes 10.224.0.0/16 `
  --nat-gateway $NatName --network-security-group $NsgName --default-outbound-access false
az network vnet subnet create --subscription $SubscriptionId -g $ResourceGroup `
  --vnet-name $VnetName -n static-egress --address-prefixes 10.225.0.0/24 `
  --network-security-group $NsgName --default-outbound-access false

$VnetId = az network vnet show --subscription $SubscriptionId -g $ResourceGroup `
  -n $VnetName --query id -o tsv
$NodeSubnetId = "$VnetId/subnets/nodes"
$GatewaySubnetId = "$VnetId/subnets/static-egress"
```

Do **not** attach NAT to `static-egress`. `defaultOutboundAccess: false` disables
implicit outbound access, not the explicit public IPs provisioned by the gateway
controller. Default NSG VNet rules permit internal node and tunnel communication.
The API endpoint is public; no inbound application Service is exposed.

### 2. Create the cluster identity and VNet permission

```powershell
$Identity = az identity create --subscription $SubscriptionId -g $ResourceGroup `
  -n $IdentityName -l $Location -o json | ConvertFrom-Json
az role assignment create --subscription $SubscriptionId `
  --assignee-object-id $Identity.principalId --assignee-principal-type ServicePrincipal `
  --role 'Network Contributor' --scope $VnetId
```

Allow role propagation before creating AKS. If AKS reports a network authorization
error immediately afterward, wait and retry; do not grant a broad role as a workaround.

### 3. Create AKS with the system pool

```powershell
az aks create --subscription $SubscriptionId -g $ResourceGroup -n $ClusterName `
  -l $Location --tier standard `
  --enable-managed-identity --assign-identity $Identity.id `
  --nodepool-name system --node-count 2 --node-vm-size Standard_D4s_v5 `
  --os-sku AzureLinux --vm-set-type VirtualMachineScaleSets `
  --nodepool-taints CriticalAddonsOnly=true:NoSchedule `
  --network-plugin azure --network-plugin-mode overlay --ip-families IPv4 `
  --pod-cidr 10.244.0.0/16 --service-cidr 10.0.0.0/16 --dns-service-ip 10.0.0.10 `
  --vnet-subnet-id $NodeSubnetId --outbound-type userAssignedNATGateway `
  --enable-static-egress-gateway --generate-ssh-keys
```

The manual CLI can generate SSH keys locally. Bicep does not require you to supply
SSH keys. Neither path enables instance public IPs on application nodes.

### 4. Add apps and the dedicated Gateway-mode pool

```powershell
az aks nodepool add --subscription $SubscriptionId -g $ResourceGroup `
  --cluster-name $ClusterName -n apps --mode User --node-count 1 `
  --node-vm-size Standard_D4s_v5 --os-sku AzureLinux `
  --vm-set-type VirtualMachineScaleSets --vnet-subnet-id $NodeSubnetId

az aks nodepool add --subscription $SubscriptionId -g $ResourceGroup `
  --cluster-name $ClusterName -n staticegw --mode Gateway --node-count 2 `
  --node-vm-size Standard_D4s_v5 --os-sku AzureLinux `
  --vm-set-type VirtualMachineScaleSets --vnet-subnet-id $GatewaySubnetId `
  --enable-node-public-ip `
  --gateway-prefix-size 30

az aks nodepool list --subscription $SubscriptionId -g $ResourceGroup `
  --cluster-name $ClusterName `
  --query "[].{name:name,mode:mode,count:count,subnet:vnetSubnetId,state:provisioningState}" -o table
```

Expected: `system` / System / 2, `apps` / User / 1, `staticegw` / Gateway / 2.
Gateway mode is not a normal User pool with a custom label. It is dedicated to
egress and does not support cluster autoscaler or explicit `upgradeSettings.maxSurge`.

### 5. Get credentials and wait for the AKS-managed CRD

```powershell
New-Item -ItemType Directory -Force .\.local | Out-Null
$env:KUBECONFIG = Join-Path $PWD '.local\kubeconfig'
az aks get-credentials --subscription $SubscriptionId -g $ResourceGroup -n $ClusterName `
  --file $env:KUBECONFIG --context $ClusterName --overwrite-existing
kubectl --context $ClusterName get nodes -L kubernetes.azure.com/agentpool
kubectl --context $ClusterName get crd staticgatewayconfigurations.egressgateway.kubernetes.azure.com
kubectl --context $ClusterName wait --for=condition=Established `
  crd/staticgatewayconfigurations.egressgateway.kubernetes.azure.com --timeout=300s
```

If the CRD is not yet present, wait for feature installation and repeat. Do not
download or overwrite the managed CRD/operator.

### 6. Apply the namespace and custom resource; wait for its prefix

```powershell
kubectl --context $ClusterName apply -f .\infra\kubernetes\namespace.yaml
kubectl --context $ClusterName apply -f .\infra\crds\static-gateway-configuration.yaml
kubectl --context $ClusterName wait -n egress-demo `
  '--for=jsonpath={.status.egressIpPrefix}' `
  staticgatewayconfiguration/static-egress --timeout=600s
kubectl --context $ClusterName get staticgatewayconfiguration static-egress -n egress-demo -o yaml
```

Do this **before** creating annotated pods.

### 7. Run the applications

```powershell
kubectl --context $ClusterName apply -f .\infra\kubernetes\applications.yaml
kubectl --context $ClusterName rollout status deployment/application-1 -n egress-demo --timeout=300s
kubectl --context $ClusterName rollout status deployment/application-2 -n egress-demo --timeout=300s
kubectl --context $ClusterName get pods -n egress-demo -o wide
kubectl --context $ClusterName logs deployment/application-1 -n egress-demo --tail=5
kubectl --context $ClusterName logs deployment/application-2 -n egress-demo --tail=5
```

These are long-running curl-based demo applications. Each requests the echo endpoint
every 30 seconds and logs the observed IP. Failed requests log an error and exit,
causing a restart rather than success-shaped output. The first successful request
enables readiness. Pods are non-root, have read-only root filesystems, dropped
capabilities, resource requests/limits, and no service-account token. Both select
`kubernetes.azure.com/agentpool: apps`.

Only application 1's **pod template** has this annotation:

```yaml
annotations:
  kubernetes.azure.com/static-gateway-configuration: static-egress
```

Putting it only on Deployment metadata is insufficient.

### 8. Prove both outbound IPs

Manual inspection and assertions:

```powershell
$GatewayPrefix = kubectl --context $ClusterName get staticgatewayconfiguration static-egress `
  -n egress-demo -o 'jsonpath={.status.egressIpPrefix}'
$NatIp = az network public-ip show --subscription $SubscriptionId -g $ResourceGroup `
  -n "$ClusterName-nat-ip" --query ipAddress -o tsv
$App1Ip = kubectl --context $ClusterName exec deployment/application-1 -n egress-demo -- `
  curl --ipv4 --fail --silent --show-error --noproxy '*' --connect-timeout 10 --max-time 30 https://api.ipify.org
$App2Ip = kubectl --context $ClusterName exec deployment/application-2 -n egress-demo -- `
  curl --ipv4 --fail --silent --show-error --noproxy '*' --connect-timeout 10 --max-time 30 https://api.ipify.org

[pscustomobject]@{
  GatewayPrefix = $GatewayPrefix; Application1 = $App1Ip
  NatIp = $NatIp; Application2 = $App2Ip
} | Format-List
. .\scripts\Common.ps1
if (-not (Test-IPv4InCidr $App1Ip.Trim() $GatewayPrefix.Trim())) {
  throw 'Application 1 did not use the static gateway prefix.'
}
if ($App2Ip.Trim() -ne $NatIp.Trim()) { throw 'Application 2 did not use NAT.' }
if ($App1Ip.Trim() -eq $App2Ip.Trim()) { throw 'The outbound IPs must differ.' }
```

Full independent proof with three fresh requests per app and persisted evidence:

```powershell
.\scripts\Test-Egress.ps1 -SubscriptionId $SubscriptionId `
  -ResourceGroup $ResourceGroup -ClusterName $ClusterName -Samples 3
Get-Content .\.local\egress-proof.json
```

The verifier checks the outbound type, exact pool names/modes, gateway resource,
actual pod annotations, placement on apps, no NAT attachment on the gateway subnet,
and that application 2's node VM scale set subnet is attached to the NAT gateway.
Application 1 must return an IPv4 in the
gateway CIDR, never the NAT IP; application 2 must match the NAT IP, outside that
CIDR. NAT and gateway prefixes must not overlap. Any failed request/assertion throws.

Only a fully successful run writes evidence: UTC timestamps, pod/node names,
prefix, NAT/subnet resource IDs, observed IPs, and per-sample results. Failed reruns
do not overwrite an older successful proof; inspect its timestamps.

Gateway pods can use different addresses **within the prefix** after recreation
or failover. Allowlist the assigned prefix, not a single observed per-pod address.
The proof covers tested public IPv4 connections, not every protocol/destination
or uninterrupted connection survival during failover.

## CRDs: what is applied, and when?

**A CRD defines an API type; a custom resource is an instance.** Enabling Static
Egress Gateway installs the AKS-managed operator/CNI and the
`staticgatewayconfigurations.egressgateway.kubernetes.azure.com` CRD.

The requested dedicated **`infra\crds`** directory contains the namespaced
**`StaticGatewayConfiguration` custom resource**, not a copy of the
`CustomResourceDefinition`. AKS owns and versions the actual definition.

| Field | Meaning |
| --- | --- |
| `apiVersion` | `egressgateway.kubernetes.azure.com/v1alpha1` |
| `metadata.name` | `static-egress`, referenced by the pod annotation |
| `metadata.namespace` | `egress-demo`; annotated pods must share this namespace |
| `spec.gatewayNodepoolName` | Existing Gateway-mode pool `staticegw` |
| `spec.excludeCidrs` | Private ranges and IMDS bypass the tunnel using the pod's primary interface |
| `spec.publicIpPrefixId` | Omitted: the controller creates/manages the public prefix |
| `status.egressIpPrefix` | Assigned prefix; wait for it before creating/restarting annotated pods |
| `status.gatewayServerProfile` | Tunnel endpoint IP/port and WireGuard public key |

Order: enable feature -> create Gateway pool -> wait for CRD -> create namespace ->
apply custom resource -> wait for assigned prefix -> create annotated pods.
The CNI configures the gateway when a pod is **created**. Changing an annotation
or gateway configuration does not retrofit an existing pod; wait for readiness
and recreate the workload:

```powershell
kubectl --context $ClusterName rollout restart deployment/application-1 -n egress-demo
kubectl --context $ClusterName rollout status deployment/application-1 -n egress-demo --timeout=300s
```

Application 2 must remain unannotated. `excludeCidrs` intentionally keeps private
destinations off the gateway, so the demo proves a **public** destination.
To supply an existing public prefix instead, set `publicIpPrefixId` to its ARM ID,
ensure compatible region/size, and grant the cluster identity Network Contributor
at that prefix's scope; that alternative is not provisioned here.

## Limitations and troubleshooting

* No Azure CNI Pod Subnet, dual stack, Windows gateway nodes, or annotated
  `hostNetwork` pods.
* Kubernetes network policies **do not apply to gateway-routed traffic**. Do not
  rely on NetworkPolicy to enforce this egress path.
* Gateway pool autoscaler is unsupported. Prefix sizes `/31`, `/30`, `/29`, `/28`
  support 2, 4, 8, 16 addresses/nodes respectively. Reserve maintenance headroom.
* Two gateway nodes do not make the one-replica demo apps highly available.
  Connections can be interrupted by changes/failover.
* Public IP mode is used. Private mode has additional version/node/routing requirements.
* Deleting/recreating IP resources can change their addresses; recollect proof.

| Symptom | Check / correction |
| --- | --- |
| Both apps use NAT | Ensure gateway subnet has **no NAT**; NAT takes precedence over instance public IPs |
| Gateway pool rejects maxSurge | Remove `upgradeSettings.maxSurge`; AKS manages Gateway-mode upgrades |
| Custom subnet rejected for managed system pool | Recreate with the documented custom VNet and `userAssignedNATGateway`; do not mix managed/custom subnets |
| Bicep BCP081 / unknown CLI flags | Upgrade Azure CLI-managed Bicep/CLI; check whether `aks-preview` shadows the built-in commands |
| Quota/capacity error | Check Sweden Central quotas, public IP quota, and VM SKU capacity |
| Role/policy denial | Review deployment error and RBAC/policies; do not bypass organizational restrictions |
| Missing CRD | Check feature enablement and kubeconfig/context; wait for installation |
| Empty prefix / readiness timeout | Describe the CR, inspect events, gateway pool health and IP quota; do not create annotated pods early |
| App 1 bypasses gateway | Check actual pod annotation/namespace/reference, then restart after prefix readiness |
| App 2 uses gateway | Remove its pod-template gateway annotation and recreate its pods |
| Pod Pending | Check apps selector, pool readiness/resources; do not schedule app pods on gateway nodes |
| Probe CrashLoopBackOff | Inspect logs, DNS, outbound 443, registry and echo endpoint availability |
| kubectl timeout with allowlisting | Correct workstation/VPN egress allowlist using Azure management access |

```powershell
az aks show --subscription $SubscriptionId -g $ResourceGroup -n $ClusterName `
  --query "{state:provisioningState,network:networkProfile}" -o json
kubectl --context $ClusterName describe staticgatewayconfiguration static-egress -n egress-demo
kubectl --context $ClusterName get events -n egress-demo --sort-by=.lastTimestamp
kubectl --context $ClusterName describe pods -n egress-demo
kubectl --context $ClusterName get pods -n kube-system -o wide
```

## Costs and cleanup

Charges include five VMs/disks, AKS Standard tier, NAT gateway hours/data, gateway
node public IPs, public prefix allocation, and transfer. A `/30` reserves four addresses with only two
gateway nodes. Check current Sweden Central pricing under your agreement.

Remove annotated workloads **before** their CR, wait for cleanup finalizers, then
delete the gateway pool. Do not delete the operator first or force-remove finalizers.

```powershell
# DESTRUCTIVE: both apps and shared probe ConfigMap.
kubectl --context $ClusterName delete -f .\infra\kubernetes\applications.yaml
kubectl --context $ClusterName delete staticgatewayconfiguration static-egress `
  -n egress-demo --wait=true --timeout=5m
az aks nodepool delete --subscription $SubscriptionId -g $ResourceGroup `
  --cluster-name $ClusterName -n staticegw
az aks update --subscription $SubscriptionId -g $ResourceGroup -n $ClusterName `
  --disable-static-egress-gateway
kubectl --context $ClusterName delete namespace egress-demo
```

The remaining cluster/NAT still costs money. To remove **everything**, first
delete workloads and CR as above, then delete the dedicated resource group.
Do not do this if it contains unrelated resources:

```powershell
# DESTRUCTIVE: Azure CLI asks for confirmation.
az group delete --subscription $SubscriptionId -n $ResourceGroup
```

AKS normally deletes its managed node resource group with the cluster. If locks
or policy block removal, inspect the error and remaining resources. Deleting AKS
alone does **not** delete this custom VNet, NAT gateway, public IP, identity or role
assignment, which live in the deployment resource group. Remove local credentials
when no longer needed:

```powershell
Remove-Item -LiteralPath .\.local\kubeconfig
Remove-Item Env:\KUBECONFIG -ErrorAction SilentlyContinue
```

## Local checks

```powershell
az bicep build --file .\infra\main.bicep --stdout
az bicep build-params --file .\infra\main.bicepparam --stdout
.\tests\Test-Local.ps1
```

Offline tests cover syntax, CIDR boundaries/errors, six-sample successful proof,
wrong gateway/NAT addresses, incorrect subnet attachment, and native failures.
They are not a substitute for ARM validation and live egress proof.

## References

* [Configure Static Egress Gateway in AKS](https://learn.microsoft.com/en-us/azure/aks/configure-static-egress-gateway)
* [Managed and user-assigned NAT Gateway in AKS](https://learn.microsoft.com/en-us/azure/aks/nat-gateway)
* [NAT Gateway outbound precedence](https://learn.microsoft.com/en-us/azure/nat-gateway/nat-overview)
* [Managed cluster Bicep schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.containerservice/2025-05-01/managedclusters)
* [Agent pool Bicep schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.containerservice/2025-05-01/managedclusters/agentpools)
* [Azure CNI Overlay](https://learn.microsoft.com/en-us/azure/aks/azure-cni-overlay)
