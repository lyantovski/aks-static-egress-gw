targetScope = 'resourceGroup'

@description('AKS cluster name.')
param clusterName string = 'aks-static-egress-demo'

param location string = 'swedencentral'

@description('Leave empty to use the regional AKS default supported Kubernetes version.')
param kubernetesVersion string = ''

param nodeVmSize string = 'Standard_D4s_v5'

@minValue(2)
param systemNodeCount int = 2

@minValue(1)
param appsNodeCount int = 1

@minValue(2)
@maxValue(3)
param gatewayNodeCount int = 2

param gatewaySubnetPrefix string = '10.225.0.0/24'

@description('Optional API server allowlist, for example your workstation public IPv4 /32.')
param apiServerAuthorizedIPRanges array = []

resource natIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${clusterName}-nat-ip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: '${clusterName}-nat'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natIp.id
      }
    ]
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${clusterName}-nodes-nsg'
  location: location
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${clusterName}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.224.0.0/12'
      ]
    }
    subnets: [
      {
        name: 'nodes'
        properties: {
          addressPrefix: '10.224.0.0/16'
          natGateway: {
            id: nat.id
          }
          networkSecurityGroup: {
            id: nsg.id
          }
          defaultOutboundAccess: false
        }
      }
      {
        name: 'static-egress'
        properties: {
          addressPrefix: gatewaySubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${clusterName}-identity'
  location: location
}

resource networkRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vnet.id, identity.id, 'network-contributor')
  scope: vnet
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
  }
}

var nodeSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'nodes')
var gatewaySubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'static-egress')

resource aks 'Microsoft.ContainerService/managedClusters@2025-05-01' = {
  name: clusterName
  location: location
  tags: {
    purpose: 'static-egress-demo'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  sku: {
    name: 'Base'
    tier: 'Standard'
  }
  properties: {
    dnsPrefix: '${clusterName}-${uniqueString(resourceGroup().id)}'
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    apiServerAccessProfile: {
      authorizedIPRanges: apiServerAuthorizedIPRanges
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: systemNodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        type: 'VirtualMachineScaleSets'
        osDiskType: 'Managed'
        vnetSubnetID: nodeSubnetId
        nodeTaints: [
          'CriticalAddonsOnly=true:NoSchedule'
        ]
        upgradeSettings: {
          maxSurge: '1'
        }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      ipFamilies: [
        'IPv4'
      ]
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'userAssignedNATGateway'
      staticEgressGatewayProfile: {
        enabled: true
      }
    }
  }
  dependsOn: [
    networkRole
  ]
}

resource apps 'Microsoft.ContainerService/managedClusters/agentPools@2025-05-01' = {
  parent: aks
  name: 'apps'
  properties: {
    mode: 'User'
    count: appsNodeCount
    vmSize: nodeVmSize
    osType: 'Linux'
    osSKU: 'AzureLinux'
    type: 'VirtualMachineScaleSets'
    osDiskType: 'Managed'
    vnetSubnetID: nodeSubnetId
    upgradeSettings: {
      maxSurge: '1'
    }
  }
}

resource gateway 'Microsoft.ContainerService/managedClusters/agentPools@2025-05-01' = {
  parent: aks
  name: 'staticegw'
  properties: {
    mode: 'Gateway'
    count: gatewayNodeCount
    vmSize: nodeVmSize
    osType: 'Linux'
    osSKU: 'AzureLinux'
    type: 'VirtualMachineScaleSets'
    osDiskType: 'Managed'
    vnetSubnetID: gatewaySubnetId
    // Explicit bootstrap egress is required before the gateway CR allocates its prefix.
    enableNodePublicIP: true
    enableAutoScaling: false
    gatewayProfile: {
      publicIPPrefixSize: 30
    }
  }
  dependsOn: [
    apps
  ]
}

output clusterName string = aks.name
output clusterId string = aks.id
output nodeResourceGroup string = aks.properties.nodeResourceGroup
output gatewayPoolName string = gateway.name
output natPublicIp string = natIp.properties.ipAddress
