using './main.bicep'

param clusterName = 'aks-static-egress-demo'
param location = 'swedencentral'
param nodeVmSize = 'Standard_D4s_v5'
param systemNodeCount = 2
param appsNodeCount = 1
param gatewayNodeCount = 2
