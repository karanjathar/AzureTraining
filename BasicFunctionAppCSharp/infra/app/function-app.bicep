param name string
param location string
param tags object
param planResourceId string
param storageAccountName string
param storageBlobEndpoint string
param deploymentContainerName string
param identityResourceId string
param identityClientId string
param applicationInsightsConnectionString string
param instanceMemoryMB int
param maximumInstanceCount int

var appSettings = {
  FUNCTIONS_EXTENSION_VERSION: '~4'
  FUNCTIONS_WORKER_RUNTIME: 'dotnet-isolated'
  AzureWebJobsStorage__accountName: storageAccountName
  AzureWebJobsStorage__blobServiceUri: storageBlobEndpoint
  AzureWebJobsStorage__credential: 'managedidentity'
  AzureWebJobsStorage__clientId: identityClientId
  APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsightsConnectionString
}

module functionApp 'br/public:avm/res/web/site:0.15.1' = {
  name: 'functionApp'
  params: {
    name: name
    location: location
    kind: 'functionapp,linux'
    tags: tags
    serverFarmResourceId: planResourceId
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [
        identityResourceId
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageBlobEndpoint}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identityResourceId
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: instanceMemoryMB
        maximumInstanceCount: maximumInstanceCount
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10'
      }
    }
    siteConfig: {
      alwaysOn: false
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
    }
    appSettingsKeyValuePairs: appSettings
  }
}

output name string = functionApp.outputs.name
output url string = 'https://${functionApp.outputs.defaultHostname}'
