targetScope = 'resourceGroup'

@description('Globally unique name for the Function App.')
param functionAppName string

@description('Globally unique, lowercase storage account name.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Optional Key Vault name. Leave empty to store the UniFi API key as a Function App setting.')
param keyVaultName string = ''

@description('Create the Function App and Consumption plan. Set false when adopting an existing app.')
param createFunctionApp bool = true

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${functionAppName}-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Flow_Type: 'Bluefield'
    Request_Source: 'rest'
  }
}

resource consumptionPlan 'Microsoft.Web/serverfarms@2023-12-01' = if (createFunctionApp) {
  name: '${functionAppName}-plan'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: false
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = if (createFunctionApp) {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: consumptionPlan.id
    httpsOnly: true
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      powerShellVersion: '7.6'
    }
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (!empty(keyVaultName)) {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'
  }
}

output storageAccountName string = storage.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString