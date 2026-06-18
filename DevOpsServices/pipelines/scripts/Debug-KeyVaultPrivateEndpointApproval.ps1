param(
    [string]$ConnectionName,
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$KeyVaultName
)

function Get-AzureManagementToken {
    try {
        # Try to get token from Azure CLI

        $tokenResult = az account get-access-token --resource=https://management.azure.com/ --query accessToken --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $tokenResult) {
            return $tokenResult
        }
    }
    catch {
        Write-Warning "Failed to get Azure management token: $($_.Exception.Message)"
        return $null
    }
}

function Debug-KeyVaultPrivateEndpointApproval {
 
   Write-Host "##[section]DEEP DEBUGGING KEY VAULT 403 ERROR"
   Write-Host "============================================================"
   
   $azureToken = Get-AzureManagementToken
   $headers = @{
       'Authorization' = "Bearer $azureToken"
       'Content-Type' = 'application/json'
   }
   
   # Test 1: Verify token works for basic Key Vault operations
   Write-Host "##[debug]TEST 1: Basic Key Vault Access"
   Write-Host "##[debug]   connectionName: $ConnectionName"
   Write-Host "##[debug]   Subscription ID: $SubscriptionId"
   Write-Host "##[debug]   Resource Group: $ResourceGroupName"
    Write-Host "##[debug]   Key Vault Name: $KeyVaultName"

   try {
       $kvInfoUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$KeyVaultName`?api-version=2023-07-01"
         Write-Host "##[debug]Checking Key Vault info at: $kvInfoUrl"
       $kvInfo = Invoke-RestMethod -Uri $kvInfoUrl -Headers $headers -Method Get
       Write-Host "##[debug]Basic Key Vault access: SUCCESS"  
       Write-Host "##[debug]   Key Vault ID: $($kvInfo.id)"
       Write-Host "##[debug]   RBAC Enabled: $($kvInfo.properties.enableRbacAuthorization)"
       Write-Host "##[debug]   Soft Delete: $($kvInfo.properties.enableSoftDelete)"
       Write-Host "##[debug]   Public Network Access: $($kvInfo.properties.publicNetworkAccess)"
   }
   catch {
    #    Write-Host "##[debug]Basic Key Vault access: FAILED"
    #    Write-Host "##[debug]   Error: $($_.Exception.Message)"
   }
   
   # Test 2: List private endpoint connections
   Write-Host ""
   Write-Host "##[debug]TEST 2: List Private Endpoint Connections"
   try {
       $listUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$KeyVaultName/privateEndpointConnections?api-version=2023-07-01"
       $connections = Invoke-RestMethod -Uri $listUrl -Headers $headers -Method Get
       Write-Host "##[debug]List connections: SUCCESS"
       Write-Host "##[debug]   Found $($connections.value.Count) connections"
       
       foreach ($conn in $connections.value) {
           Write-Host "##[debug]   Connection: $($conn.name)"
           Write-Host "##[debug]     Status: $($conn.properties.privateLinkServiceConnectionState.status)"
           Write-Host "##[debug]     ETag: '$($conn.etag)'"
           Write-Host "##[debug]     ID: $($conn.id)"
       }
   }
   catch {
       Write-Host "##[debug]List connections: FAILED"
       Write-Host "##[debug]   Error: $($_.Exception.Message)"
       return $false
   }
   
   # Test 3: Try to GET the specific connection
   Write-Host ""
   Write-Host "##[debug]TEST 3: GET Specific Connection"
   try {
       $getConnUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$KeyVaultName/privateEndpointConnections/$ConnectionName`?api-version=2022-07-01"
       Write-Host "##[debug]GET specific connection URL: $getConnUrl"

       $specificConn = Invoke-RestMethod -Uri $getConnUrl -Headers $headers -Method Get
       Write-Host "##[debug]GET specific connection: SUCCESS"
       Write-Host "##[debug]   Name: $($specificConn.name)"
       Write-Host "##[debug]   Status: $($specificConn.properties.privateLinkServiceConnectionState.status)"
       Write-Host "##[debug]   ETag: '$($specificConn.etag)'"
       Write-Host "##[debug]   Resource ID: $($specificConn.id)"
       
       # Store for PUT test
       $currentConnection = $specificConn
   }
   catch {
       Write-Host "##[debug]GET specific connection: FAILED"
       Write-Host "##[debug]   Error: $($_.Exception.Message)"
       Write-Host "##[debug]   This might be why PUT fails - connection doesn't exist or wrong name"
       return $false
   }
   
   # Test 4: Test different API versions
   Write-Host ""
   Write-Host "##[debug]TEST 4: API Version Compatibility"
   $apiVersions = @("2023-07-01", "2022-07-01", "2024-11-01")

   foreach ($version in $apiVersions) {
       try {
           $testUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$KeyVaultName/privateEndpointConnections?api-version=$version"
           $testResponse = Invoke-RestMethod -Uri $testUrl -Headers $headers -Method Get -TimeoutSec 10
           Write-Host "##[debug]API Version $version SUCCESS ($($testResponse.value.Count) connections)"
       }
       catch {
           Write-Host "##[debug]API Version $version FAILED - $($_.Exception.Message)"
       }
   }
   
   # Test 5: Compare request body formats
   Write-Host ""
   Write-Host "##[debug]TEST 6: Different Request Body Formats"
   
   $requestBodies = @{
       "Standard" = @{
           properties = @{
               privateLinkServiceConnectionState = @{
                   status = "Approved"
                   description = "Auto-approved by script"
                   actionsRequired = "None"
               }
           }
       }
       "WithActions" = @{
           properties = @{
               privateLinkServiceConnectionState = @{
                   status = "Approved"
                   description = "Auto-approved by script"
                   actionsRequired = ""
               }
           }
       }
       "Minimal" = @{
           properties = @{
               privateLinkServiceConnectionState = @{
                   status = "Approved"
                   description = "Auto-approved by script"
               }
           }
       }
       "WithETag" = @{
           etag = $currentConnection.etag
           properties = @{
               privateLinkServiceConnectionState = @{
                   status = "Approved"
                   description = "Auto-approved by script"
                   actionsRequired = "None"
               }
           }
       }
       "WithETagBlank" = @{
           etag = ""
           properties = @{
               privateLinkServiceConnectionState = @{
                   status = "Approved"
                   description = "Auto-approved by script"
                   actionsRequired = "None"
               }
           }
       }
       "WithID" = @{
           id = $currentConnection.id
           properties = @{
               privateLinkServiceConnectionState = @{
                   status = "Approved"
                   description = "Auto-approved by script"
                   actionsRequired = "None"
               }
           }
       }         
   }
   
   foreach ($version in $apiVersions) {
    foreach ($bodyType in $requestBodies.Keys) {
        Write-Host "##[debug]Testing body format: $bodyType"
        $testBody = $requestBodies[$bodyType] | ConvertTo-Json -Depth 3
 
        try {
                $null = $testBody | ConvertFrom-Json
                $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.KeyVault/vaults/$resourceName/privateEndpointConnections"

                $approvalUrl = "$apiEndpoint/$connectionName`?api-version=$version"
                Write-Host "##[debug]   PUT URL: $approvalUrl"
                Write-Host "##[debug]   PUT Body: $testBody"
                $approvalResponse = Invoke-RestMethod -Uri $approvalUrl -Headers $headers -Method Put -Body $testBody -TimeoutSec 30
        
                Write-Host "##[section]Successfully approved private endpoint connection: $connectionName"
                Write-Host "##[debug]Approval response status: $($approvalResponse.properties.privateLinkServiceConnectionState.status)"

            Write-Host "##[debug]JSON format valid"
        }
        catch {
            Write-Host "##[debug]PUT Failed: $($_.Exception.Message)"
        }
    }
   }
}



 Debug-KeyVaultPrivateEndpointApproval