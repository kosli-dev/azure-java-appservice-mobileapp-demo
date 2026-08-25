// Azure App Service (Linux, Java SE) for the orders-api demo component.
//
// One resource group per environment: `kosli snapshot azure` snapshots a whole resource
// group, so keeping staging and prod apart is what lets each be its own Kosli environment.
//
// Deploy with:
//   az group create -n rg-kosli-orders-api-demo -l westeurope
//   az deployment group create -g rg-kosli-orders-api-demo -f infra/main.bicep \
//      -p webAppName=kosli-orders-api-demo environment=prod
//
// Or just run infra/deploy.sh [prod|staging].

@description('Globally unique name of the web app. Becomes https://<name>.azurewebsites.net')
param webAppName string

@description('Azure region for the resource group resources.')
param location string = resourceGroup().location

@description('App Service plan SKU. B1 is the cheapest tier that supports always-on.')
@allowed([
  'B1'
  'B2'
  'S1'
  'P0v3'
  'P1v3'
])
param sku string = 'B1'

@description('Java runtime for the built-in Java SE container.')
param javaVersion string = '21'

@description('Which deployment environment these resources make up.')
@allowed([
  'prod'
  'staging'
])
param environment string = 'prod'

@description('Tags applied to every resource.')
param tags object = {
  purpose: 'kosli-demo'
  component: 'orders-api'
  environment: environment
  managedBy: 'bicep'
}

var planName = '${webAppName}-plan'

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: sku
  }
  kind: 'linux'
  properties: {
    reserved: true // required for Linux
  }
}

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'JAVA|${javaVersion}-java${javaVersion}'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      healthCheckPath: '/api/health'
      appSettings: [
        {
          // Spring Boot listens on 8080; App Service needs to be told which port to map.
          name: 'WEBSITES_PORT'
          value: '8080'
        }
        {
          name: 'JAVA_OPTS'
          value: '-Xms256m -Xmx512m'
        }
        {
          // Kosli's Azure environment reporting fingerprints the *extracted* wwwroot content.
          // Running from a mounted package would make that fingerprint unavailable, so keep
          // this at 0. See `kosli snapshot azure --help`.
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '0'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'false'
        }
      ]
    }
  }
}

resource logs 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: webApp
  name: 'logs'
  properties: {
    httpLogs: {
      fileSystem: {
        enabled: true
        retentionInDays: 3
        retentionInMb: 35
      }
    }
    applicationLogs: {
      fileSystem: {
        level: 'Information'
      }
    }
  }
}

output webAppName string = webApp.name
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output healthUrl string = 'https://${webApp.properties.defaultHostName}/api/health'
output resourceGroupName string = resourceGroup().name
output environment string = environment
