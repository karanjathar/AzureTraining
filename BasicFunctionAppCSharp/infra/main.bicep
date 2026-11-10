targetScope = 'subscription'

@description('Name of the training environment. Used to generate globally unique resource names.')
@minLength(3)
@maxLength(30)
param environmentName string = 'basicfunc'

@description('Azure region for the resource group and Function resources.')
@allowed([
  'centralindia'
  'southindia'
])
param location string = 'centralindia'

@description('Resource group that contains this sample.')
param resourceGroupName string = 'rg-basic-azure-func'

@description('Flex Consumption instance memory in MB.')
@allowed([
  512
  2048
  4096
])
param instanceMemoryMB int = 2048

@description('Maximum number of Flex Consumption instances.')
@minValue(1)
@maxValue(1000)
param maximumInstanceCount int = 10

var suffix = take(toLower(uniqueString(subscription().id, environmentName, location)), 10)
var storageAccountName = take('st${suffix}', 24)
var functionAppName = take('func-${environmentName}-${suffix}', 60)
var identityName = 'id-${environmentName}-${suffix}'
var planName = 'plan-${environmentName}-${suffix}'
var deploymentContainerName = 'app-package-${take(functionAppName, 32)}-${take(suffix, 7)}'
var tags = {
  workload: 'basic-azure-function'
  environment: environmentName
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module storageIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: 'storageIdentity'
  scope: resourceGroup
  params: {
    name: identityName
    location: location
    tags: tags
  }
}

module flexPlan 'br/public:avm/res/web/serverfarm:0.1.1' = {
  name: 'flexConsumptionPlan'
  scope: resourceGroup
  params: {
    name: planName
    location: location
    tags: tags
    reserved: true
    sku: {
      name: 'FC1'
      tier: 'FlexConsumption'
    }
  }
}

module sharedResources './app/shared-resources.bicep' = {
  name: 'sharedResources'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
    storageAccountName: storageAccountName
    deploymentContainerName: deploymentContainerName
    identityName: identityName
    identityPrincipalId: storageIdentity.outputs.principalId
    logAnalyticsName: 'log-${suffix}'
    applicationInsightsName: 'appi-${suffix}'
  }
}

module functionApp './app/function-app.bicep' = {
  name: 'functionApp'
  scope: resourceGroup
  params: {
    name: functionAppName
    location: location
    tags: tags
    planResourceId: flexPlan.outputs.resourceId
    storageAccountName: sharedResources.outputs.storageAccountName
    storageBlobEndpoint: sharedResources.outputs.storageBlobEndpoint
    deploymentContainerName: deploymentContainerName
    identityResourceId: storageIdentity.outputs.resourceId
    identityClientId: storageIdentity.outputs.clientId
    applicationInsightsConnectionString: sharedResources.outputs.applicationInsightsConnectionString
    instanceMemoryMB: instanceMemoryMB
    maximumInstanceCount: maximumInstanceCount
  }
}

output resourceGroupName string = resourceGroup.name
output functionAppName string = functionApp.outputs.name
output functionAppUrl string = functionApp.outputs.url
output storageAccountName string = sharedResources.outputs.storageAccountName
output planName string = flexPlan.outputs.name
output applicationInsightsName string = sharedResources.outputs.applicationInsightsName
