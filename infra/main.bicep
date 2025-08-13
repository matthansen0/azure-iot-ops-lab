
// main.bicep - Azure IoT Ops Lab deployment

param location string = resourceGroup().location
param vmName string
param adminUsername string = 'azureuser'
@secure()
param adminPassword string
param vnetName string = '${vmName}-vnet'
param subnetName string = 'subnet'
param nsgName string = '${vmName}-nsg'
param pipName string = '${vmName}-pip'
param nicName string = '${vmName}-nic'
param vmSize string = 'Standard_D4s_v5'
param cloudInitYaml string


// User-assigned managed identity for deployment script
resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'aio-deploy-script-identity'
  location: location
// VNet
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.10.0.0/16' ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.10.1.0/24'
        }
      }
    ]
  }
}

// NSG
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow_ssh_from_any'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

// Public IP
resource pip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: pipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// NIC
resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

// VM
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(cloudInitYaml)
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}


// Assign Contributor role to the VM's managed identity after VM creation (fully automated)
resource assignVmContributor 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: 'assignVmContributor'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.53.0'
    timeout: 'PT10M'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    environmentVariables: [
      {
        name: 'VM_PRINCIPAL_ID'
        value: vm.identity.principalId
      }
      {
        name: 'RG_ID'
        value: resourceGroup().id
      }
    ]
    scriptContent: '''
      az role assignment create --assignee $VM_PRINCIPAL_ID --role "Contributor" --scope $RG_ID
    '''
    forceUpdateTag: uniqueString(vm.name)
  }
}

// Grant Owner role to the deployment script's managed identity so it can assign roles
resource scriptIdentityRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, scriptIdentity.id, '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635') // Owner
    principalId: scriptIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
}
