param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory=$true)]
    [string]$EndpointName,
   
    [Parameter(Mandatory=$true)]
    [string]$TargetResourceId,
   
    [Parameter(Mandatory=$true)]
    [string]$TargetSubresourceType,
   
    [Parameter(Mandatory=$true)]
    [string]$RequestMessage,
   
    [Parameter(Mandatory=$false)]
    [switch]$Delete = $false,
   
    [Parameter(Mandatory=$false)]
    [switch]$AutoApprove = $true,
   
    [Parameter(Mandatory=$false)]
    [switch]$DeleteAzureConnection = $true,
   
    [Parameter(Mandatory=$false)]
    [int]$MaxRetries = 10,
   
    [Parameter(Mandatory=$false)]
    [int]$RetryInterval = 30,
   
    [Parameter(Mandatory=$false)]
    [int]$ApprovalRetryInterval = 10
)

Write-Host "##[debug]Starting Fabric Managed Private Endpoint operation"
Write-Host "##[debug]WorkspaceId: $WorkspaceId"
Write-Host "##[debug]EndpointName: $EndpointName"
Write-Host "##[debug]TargetResourceId: $TargetResourceId"
Write-Host "##[debug]TargetSubresourceType: $TargetSubresourceType"
Write-Host "##[debug]RequestMessage: $RequestMessage"
Write-Host "##[debug]Operation: $(if ($Delete) { 'Delete' } else { 'Create' })"
Write-Host "##[debug]AutoApprove: $AutoApprove"
Write-Host "##[debug]DeleteAzureConnection: $DeleteAzureConnection"

function Get-AzureManagementToken {
    try {

        Write-Host "##[debug]Attempting to get Azure management token"

        # run Get-AzContext to ensure Azure CLI is logged in
        $azContext = Get-AzContext -ErrorAction Stop
        if ($azContext -eq $null) {
            Write-Warning "Azure CLI is not logged in. Please run 'az login' to authenticate."
            return $null
        }
        Write-Host "##[debug]Azure CLI is logged in as: $($azContext.Account)"
        #  display axContext in json
        Write-Host "##[debug]Azure context: $(ConvertTo-Json $azContext -Depth 3)" 

        $tokenResult = az account get-access-token --resource=https://management.azure.com/ --query accessToken --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $tokenResult) {
            return $tokenResult
        }
        return $null
    }
    catch {
        Write-Warning "Failed to get Azure management token: $($_.Exception.Message)"
        return $null
    }
}

# Function to parse Azure resource ID components
function Get-AzureResourceComponents {
    param([string]$ResourceId)
   
    # Parse Azure resource ID: /subscriptions/{sub}/resourceGroups/{rg}/providers/{provider}/{resourceType}/{name}
    if ($ResourceId -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/([^/]+)/([^/]+)/([^/]+)') {
        return @{
            SubscriptionId = $matches[1]
            ResourceGroupName = $matches[2]
            Provider = $matches[3]
            ResourceType = $matches[4]
            ResourceName = $matches[5]
        }
    }
    return $null
}

function Get-AzurePrivateEndpointConnections {
    param(
        [string]$TargetResourceId,
        [string]$EndpointName = $null
    )
   
    Write-Host "##[debug]Getting private endpoint connections from Azure resource"
   
    $azureToken = Get-AzureManagementToken
    if (-not $azureToken) {
        Write-Warning "Cannot get connections: Failed to get Azure management token"
        return @()
    }
   
    $resourceComponents = Get-AzureResourceComponents -ResourceId $TargetResourceId
    if (-not $resourceComponents) {
        Write-Warning "Cannot parse target resource ID: $TargetResourceId"
        return @()
    }
   
    $azureHeaders = @{
        'Authorization' = "Bearer $azureToken"
        'Content-Type' = 'application/json'
    }
   
    # Build API endpoint based on resource type
    $provider = $resourceComponents.Provider
    $resourceType = $resourceComponents.ResourceType
    $resourceName = $resourceComponents.ResourceName
    $subscriptionId = $resourceComponents.SubscriptionId
    $resourceGroupName = $resourceComponents.ResourceGroupName
   
    $apiEndpoint = ""
    $apiVersion = ""
   
    switch -Regex ("$provider/$resourceType") {
        "Microsoft\.Storage/storageAccounts" {
            $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$resourceName/privateEndpointConnections"
            $apiVersion = "2023-01-01"
        }
        "Microsoft\.KeyVault/vaults" {
            $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.KeyVault/vaults/$resourceName/privateEndpointConnections"
            $apiVersion = "2023-07-01"
        }
        default {
            Write-Warning "Unsupported resource type: $provider/$resourceType"
            return @()
        }
    }
   
    try {
        $listUrl = "$apiEndpoint`?api-version=$apiVersion"
        Write-Host "##[debug]Fetching connections from: $listUrl"
       
        $connectionsResponse = Invoke-RestMethod -Uri $listUrl -Headers $azureHeaders -Method Get -TimeoutSec 30
       
        if ($connectionsResponse.value) {
            $connections = $connectionsResponse.value
            Write-Host "##[debug]Found $($connections.Count) private endpoint connections"
           
            # Filter by endpoint name if specified
            if ($EndpointName) {
                $connections = $connections | Where-Object {
                    $_.name -like "*$EndpointName*" -or
                    $_.properties.privateEndpoint.id -like "*$EndpointName*"
                }
                Write-Host "##[debug]Filtered to $($connections.Count) connections matching '$EndpointName'"
            }
           
            return $connections
        }
       
        return @()
    }
    catch {
        Write-Warning "Error getting private endpoint connections: $($_.Exception.Message)"
        return @()
    }
}

function Remove-AzurePrivateEndpointConnection {
    param(
        [string]$TargetResourceId,
        [string]$ConnectionName,
        [int]$MaxRetries = 3
    )
   
    Write-Host "##[debug]Deleting Azure private endpoint connection: $ConnectionName"
   
    $azureToken = Get-AzureManagementToken
    if (-not $azureToken) {
        Write-Warning "Cannot delete connection: Failed to get Azure management token"
        return $false
    }
   
    $resourceComponents = Get-AzureResourceComponents -ResourceId $TargetResourceId
    if (-not $resourceComponents) {
        Write-Warning "Cannot parse target resource ID: $TargetResourceId"
        return $false
    }
   
    $azureHeaders = @{
        'Authorization' = "Bearer $azureToken"
        'Content-Type' = 'application/json'
    }
   
    # Build API endpoint
    $provider = $resourceComponents.Provider
    $resourceType = $resourceComponents.ResourceType
    $resourceName = $resourceComponents.ResourceName
    $subscriptionId = $resourceComponents.SubscriptionId
    $resourceGroupName = $resourceComponents.ResourceGroupName
   
    $apiEndpoint = ""
    $apiVersion = ""
   
    switch -Regex ("$provider/$resourceType") {
        "Microsoft\.Storage/storageAccounts" {
            $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$resourceName/privateEndpointConnections"
            $apiVersion = "2023-01-01"
        }
        "Microsoft\.KeyVault/vaults" {
            $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.KeyVault/vaults/$resourceName/privateEndpointConnections"
            $apiVersion = "2022-07-01"
        }
        default {
            Write-Warning "Unsupported resource type for deletion: $provider/$resourceType"
            return $false
        }
    }
   
    $retryCount = 0
    while ($retryCount -lt $MaxRetries) {
        try {
            $deleteUrl = "$apiEndpoint/$ConnectionName`?api-version=$apiVersion"
            Write-Host "##[debug]Sending DELETE request to: $deleteUrl"
           
            $response = Invoke-RestMethod -Uri $deleteUrl -Headers $azureHeaders -Method Delete -TimeoutSec 30
           
            Write-Host "##[section]Successfully deleted Azure private endpoint connection: $ConnectionName"
            return $true
        }
        catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
           
            if ($_.Exception.Response) {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errorDetails = $reader.ReadToEnd()
                $reader.Close()
                Write-Host "##[debug]Delete error details: $errorDetails"
               
                # Check if it's a "not found" error (already deleted)
                if ($errorDetails -like "*NotFound*" -or $errorDetails -like "*404*") {
                    Write-Host "##[debug]Connection not found (may already be deleted): $ConnectionName"
                    return $true
                }
            }
           
            if ($retryCount -lt $MaxRetries) {
                Write-Warning "Delete attempt $retryCount failed, retrying in 10 seconds: $errorMessage"
                Start-Sleep -Seconds 10
            } else {
                Write-Error "Failed to delete Azure private endpoint connection after $MaxRetries attempts: $errorMessage"
                return $false
            }
        }
    }
   
    return $false
}

function Approve-PrivateEndpointConnection {
    param(
        [string]$TargetResourceId,
        [string]$PrivateEndpointId,
        [string]$MaxRetries = 5
    )
   
    Write-Host "##[debug]Starting auto-approval process for private endpoint"
   
    $azureToken = Get-AzureManagementToken
    if (-not $azureToken) {
        Write-Warning "Cannot auto-approve: Failed to get Azure management token"
        return $false
    }
   
    $resourceComponents = Get-AzureResourceComponents -ResourceId $TargetResourceId
    if (-not $resourceComponents) {
        Write-Warning "Cannot parse target resource ID: $TargetResourceId"
        return $false
    }
   
    $azureHeaders = @{
        'Authorization' = "Bearer $azureToken"
        'Content-Type' = 'application/json'
    }
   
    $provider = $resourceComponents.Provider
    $resourceType = $resourceComponents.ResourceType
    $resourceName = $resourceComponents.ResourceName
    $subscriptionId = $resourceComponents.SubscriptionId
    $resourceGroupName = $resourceComponents.ResourceGroupName
   
    Write-Host "##[debug]Target resource details:"
    Write-Host "##[debug]  Provider: $provider"
    Write-Host "##[debug]  Type: $resourceType"
    Write-Host "##[debug]  Name: $resourceName"
   
    # Build API endpoint based on resource type with correct API versions
    $apiEndpoint = ""
    $apiVersion = ""
    $id = ""
   
    Write-Host "##[debug]Looking for pending private endpoint connections..."

    # Poll for the private endpoint connection to appear
    $retryCount = 0
    $connectionFound = $false
    $connectionName = ""
    $connectionEtag = ""
   
    while (-not $connectionFound -and $retryCount -lt $MaxRetries) {
        try {

            switch -Regex ("$provider/$resourceType") {
                "Microsoft\.Storage/storageAccounts" {
                    $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$resourceName/privateEndpointConnections"
                    $apiVersion = "2023-01-01"
                }
                "Microsoft\.KeyVault/vaults" {
                    $apiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.KeyVault/vaults/$resourceName/privateEndpointConnections"
                    $apiVersion = "2024-11-01"
                }
                default {
                    Write-Warning "Unsupported resource type for auto-approval: $provider/$resourceType"
                    return $false
                }
            }     

            $listUrl = "$apiEndpoint`?api-version=$apiVersion"
            Write-Host "##[debug]Checking for connections (attempt $($retryCount + 1)/$MaxRetries): $listUrl"

            $connectionsResponse = Invoke-RestMethod -Uri $listUrl -Headers $azureHeaders -Method Get -TimeoutSec 30
           
            if ($connectionsResponse.value) {
                foreach ($connection in $connectionsResponse.value) {
                    $connState = $connection.properties.privateLinkServiceConnectionState.status
                    $connDescription = $connection.properties.privateLinkServiceConnectionState.description
                   
                    Write-Host "##[debug]  Connection: $($connection.name)"
                    Write-Host "##[debug]    Status: $connState"
                    Write-Host "##[debug]    Description: $connDescription"
                    Write-Host "##[debug]    ETag: $($connection.etag)"
                  
                    # Look for pending connections that were recently created
                    # This devops pipeline will create connections so a pending connection should be found and created by this script
                    # since connection name has not a standard format, we will just check if the connection is pending
                  
                    if ($connState -eq "Pending" -and $connection.name) {
                        $connectionFound = $true
                        $connectionName = $connection.name
                        $connectionEtag = $connection.etag  # Capture the ETag
                        $id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.KeyVault/vaults/$resourceName/privateEndpointConnections/$($connection.name)"
                        Write-Host "##[debug]Found pending connection to approve: $connectionName"
                        Write-Host "##[debug]Connection ETag: $connectionEtag"
                        break
                    }
                }
            }
           
            if (-not $connectionFound) {
                Write-Host "##[debug]No pending connections found yet, waiting $ApprovalRetryInterval seconds..."
                Start-Sleep -Seconds $ApprovalRetryInterval
                $retryCount++
            }
        }
        catch {
            Write-Warning "Error checking for private endpoint connections: $($_.Exception.Message)"
            Start-Sleep -Seconds $ApprovalRetryInterval
            $retryCount++
        }
    }
   
    if (-not $connectionFound) {
        Write-Warning "No pending private endpoint connection found after $MaxRetries attempts"
        return $false
    }
   
    # Approve the private endpoint connection with enhanced request body
    try {

        # sleep 10 seconds before approving the connection
        Write-Host "##[debug] Approving private endpoint connection: $connectionName"
        Start-Sleep -Seconds 10

        $approvalUrl = "$apiEndpoint/$connectionName`?api-version=$apiVersion"
       
        # Enhanced request body based on resource type
        $approvalBody = @{}
       
        switch -Regex ("$provider/$resourceType") {
            "Microsoft\.KeyVault/vaults" {
                # Key Vault specific format
                $approvalBody = @{
                    etag = ""
                    properties = @{
                        privateLinkServiceConnectionState = @{
                            status = "Approved"
                            description = "Auto-approved by Fabric deployment script"
                        }
                    }
                }
               
                # Include etag if we have it
                if ($connectionEtag -and $connectionEtag -ne "") {
                    $approvalBody.etag = $connectionEtag
                }
            }
            "Microsoft\.Storage/storageAccounts" {
                # Storage specific format (working format)
                $approvalBody = @{
                    etag = ""                    
                    properties = @{
                        privateLinkServiceConnectionState = @{
                            status = "Approved"
                            description = "Auto-approved by Fabric deployment script"
                        }
                    }
                }
            }
            default {
                # Generic format
                $approvalBody = @{
                    etag = ""
                    properties = @{
                        privateLinkServiceConnectionState = @{
                            status = "Approved"
                            description = "Auto-approved by Fabric deployment script"
                        }
                    }
                }
            }
        }
       
        $approvalBodyJson = $approvalBody | ConvertTo-Json -Depth 3 -Compress
       
        Write-Host "##[debug]Approving private endpoint connection..."
        Write-Host "##[debug]Approval URL: $approvalUrl"
        Write-Host "##[debug]Approval body: $approvalBodyJson"
    

        # display first 50 chars for token
        $first50chars = $azureHeaders['Authorization'].Substring(0, 50)
        Write-Host "##[debug]Using Authorization header: $first50chars..."

        Write-Host "##[debug]Approval headers: $($azureHeaders | Out-String)"

        $approvalResponse = Invoke-RestMethod -Uri $approvalUrl -Headers $azureHeaders -Method Put -Body $approvalBodyJson
       
        Write-Host "##[section]Successfully approved private endpoint connection: $connectionName"
        Write-Host "##[debug]Approval response status: $($approvalResponse.properties.privateLinkServiceConnectionState.status)"
       
        return $true
    }
    catch {
        Write-Host "##[error]Failed to approve private endpoint connection: $($_.Exception.Message)"
       
        # Enhanced error debugging
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode
            $statusDescription = $_.Exception.Response.StatusDescription
           
            Write-Host "##[debug]HTTP Status Code: $statusCode"
            Write-Host "##[debug]HTTP Status Description: $statusDescription"
           
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errorDetails = $reader.ReadToEnd()
                $reader.Close()
               
                Write-Host "##[debug]Error Response Body: $errorDetails"
               
                # Try to parse as JSON for better error details
                try {
                    $errorJson = $errorDetails | ConvertFrom-Json
                    if ($errorJson.error) {
                        Write-Host "##[debug]Error Code: $($errorJson.error.code)"
                        Write-Host "##[debug]Error Message: $($errorJson.error.message)"
                       
                        # Check for specific Key Vault errors
                        if ($errorJson.error.code -eq "InvalidRequestFormat") {
                            Write-Host "##[debug] Invalid request format - check API version and body structure"
                        }
                        if ($errorJson.error.code -eq "PreconditionFailed") {
                            Write-Host "##[debug] Precondition failed - ETag mismatch or resource changed"
                        }
                    }
                }
                catch {
                    Write-Host "##[debug]Could not parse error response as JSON"
                }
            }
            catch {
                Write-Host "##[debug]Could not read error response stream"
            }
        }
       
        return $false
    }
}

# Test function to compare working vs non-working API calls
function Test-ApiCallComparison {
    param(
        [string]$WorkingStorageResourceId,
        [string]$FailingKeyVaultResourceId
    )
   
    Write-Host "##[debug] Comparing API call structures..."
   
    # Test storage account structure (working)
    $storageComponents = Get-AzureResourceComponents -ResourceId $WorkingStorageResourceId
    $storageUrl = "https://management.azure.com/subscriptions/$($storageComponents.SubscriptionId)/resourceGroups/$($storageComponents.ResourceGroupName)/providers/Microsoft.Storage/storageAccounts/$($storageComponents.ResourceName)/privateEndpointConnections?api-version=2023-01-01"
   
    # Test key vault structure (failing)
    $kvComponents = Get-AzureResourceComponents -ResourceId $FailingKeyVaultResourceId
    $kvUrl = "https://management.azure.com/subscriptions/$($kvComponents.SubscriptionId)/resourceGroups/$($kvComponents.ResourceGroupName)/providers/Microsoft.KeyVault/vaults/$($kvComponents.ResourceName)/privateEndpointConnections?api-version=2023-07-01"
   
    Write-Host "##[debug]Storage URL: $storageUrl"
    Write-Host "##[debug]Key Vault URL: $kvUrl"
   
    # Test both endpoints
    $azureToken = Get-AzureManagementToken
    $headers = @{ 'Authorization' = "Bearer $azureToken"; 'Content-Type' = 'application/json' }
   
    try {
        Write-Host "##[debug]Testing Storage API access..."
        $storageConnections = Invoke-RestMethod -Uri $storageUrl -Headers $headers -Method Get
        Write-Host "##[debug] Storage API accessible, found $($storageConnections.value.Count) connections"
    }
    catch {
        Write-Host "##[debug] Storage API failed: $($_.Exception.Message)"
    }
   
    try {
        Write-Host "##[debug]Testing Key Vault API access..."
        $kvConnections = Invoke-RestMethod -Uri $kvUrl -Headers $headers -Method Get
        Write-Host "##[debug] Key Vault API accessible, found $($kvConnections.value.Count) connections"
    }
    catch {
        Write-Host "##[debug] Key Vault API failed: $($_.Exception.Message)"
    }
}

try {
    $token = $env:FABRIC_TOKEN
    if (-not $token) {
        throw "FABRIC_TOKEN environment variable is not set"
    }
   
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    # List existing endpoints
    Write-Host "##[debug] Listing existing endpoints"
    $listUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/managedPrivateEndpoints"
    $endpointsList = Invoke-RestMethod -Uri $listUrl -Headers $headers -Method Get
    $existingEndpoint = $endpointsList.value | Where-Object { $_.name -eq $EndpointName }

    if ($Delete) {
        # Delete operation
        if ($null -ne $existingEndpoint) {
            $endpointId = $existingEndpoint.id
            Write-Host "##[debug]Found endpoint to delete: $endpointId"
           
            # STEP 1: Delete Azure private endpoint connections first (if enabled)
            if ($DeleteAzureConnection) {
                Write-Host "##[section]Deleting Azure private endpoint connections"
               
                # Get all connections related to this endpoint
                $connections = Get-AzurePrivateEndpointConnections -TargetResourceId $TargetResourceId -EndpointName $EndpointName
               
                if ($connections.Count -gt 0) {
                    Write-Host "##[debug]Found $($connections.Count) Azure connections to delete"
                   
                    foreach ($connection in $connections) {
                        $connectionName = $connection.name

                        $connectionStatus = $connection.properties.privateLinkServiceConnectionState.status
                       
                        Write-Host "##[debug]Deleting Azure connection: $connectionName (Status: $connectionStatus)"
                       
                        $deleteSuccess = Remove-AzurePrivateEndpointConnection -TargetResourceId $TargetResourceId -ConnectionName $connectionName
                       
                        if ($deleteSuccess) {
                            Write-Host "##[section]Successfully deleted Azure connection: $connectionName"
                        } else {
                            Write-Warning "Failed to delete Azure connection: $connectionName"
                        }
                    }
                   
                    # Wait for Azure deletions to complete
                    Write-Host "##[debug]Waiting for Azure deletions to complete..."
                    Start-Sleep -Seconds 15
                } else {
                    Write-Host "##[debug]No Azure private endpoint connections found for deletion"
                }
            }
           
            # STEP 2: Delete Fabric managed private endpoint
            Write-Host "##[section]Deleting Fabric managed private endpoint"
            $deleteUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/managedPrivateEndpoints/$endpointId"
           
            Write-Host "##[debug]Sending delete request"
            Invoke-RestMethod -Uri $deleteUrl -Headers $headers -Method Delete
            Write-Host "##[section]Successfully deleted managed private endpoint: $endpointId"
        } else {
            Write-Warning "Endpoint '$EndpointName' not found, nothing to delete"
           
            # Even if Fabric endpoint not found, check for orphaned Azure connections
            if ($DeleteAzureConnection) {
                Write-Host "##[debug]Checking for orphaned Azure connections..."
                $connections = Get-AzurePrivateEndpointConnections -TargetResourceId $TargetResourceId -EndpointName $EndpointName
               
                if ($connections.Count -gt 0) {
                    Write-Host "##[debug]Found $($connections.Count) orphaned Azure connections to clean up"
                   
                    foreach ($connection in $connections) {
                        $connectionName = $connection.name
                        Write-Host "##[debug]Cleaning up orphaned Azure connection: $connectionName"
                       
                        $deleteSuccess = Remove-AzurePrivateEndpointConnection -TargetResourceId $TargetResourceId -ConnectionName $connectionName
                       
                        if ($deleteSuccess) {
                            Write-Host "##[section]Successfully cleaned up orphaned connection: $connectionName"
                        }
                    }
                }
            }
        }
    } else {
        # Create operation (existing logic unchanged)
        if ($null -eq $existingEndpoint) {
            Write-Host "##[debug] Endpoint does not exist. Creating new endpoint"
            $body = @{
                name = $EndpointName
                targetPrivateLinkResourceId = $TargetResourceId
                targetSubresourceType = $TargetSubresourceType
                requestMessage = $RequestMessage
            } | ConvertTo-Json
           
            Write-Host "##[debug]Request body: $body"
            Write-Host "##[debug]Sending create request"
           
            try {
                $createUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/managedPrivateEndpoints"
                $response = Invoke-RestMethod -Uri $createUrl -Headers $headers -Method Post -Body $body
                $endpointId = $response.id
                Write-Host "##[debug] Successfully created managed private endpoint: $endpointId"
               
                # Wait for provisioning to complete
                Write-Host "##[debug] Monitoring provisioning state"
                $retryCount = 0
                $completed = $false
                $approvalAttempted = $false
               
                while (-not $completed -and $retryCount -lt $MaxRetries) {
                    Start-Sleep -Seconds $RetryInterval
                    $statusUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/managedPrivateEndpoints/$endpointId"
                    $statusResponse = Invoke-RestMethod -Uri $statusUrl -Headers $headers -Method Get
                   
                    $provState = $statusResponse.provisioningState
                    $connState = if ($statusResponse.connectionState) { $statusResponse.connectionState.status } else { "Unknown" }
                   
                    Write-Host "##[debug] Status check $($retryCount + 1)/$MaxRetries"
                    Write-Host "##[debug]   Provisioning: $provState"
                    Write-Host "##[debug]   Connection: $connState"
                   
                    # Auto-approve if enabled and connection is pending
                    if ($AutoApprove -and -not $approvalAttempted -and $connState -eq "Pending") {
                        Write-Host "##[debug] Connection is pending, attempting auto-approval..."
                        $approvalSuccess = Approve-PrivateEndpointConnection -TargetResourceId $TargetResourceId -PrivateEndpointId $endpointId -MaxRetries 3
                        $approvalAttempted = $true
                       
                        if ($approvalSuccess) {
                            Write-Host "##[section] Auto-approval completed successfully"
                        } else {
                            Write-Warning " Auto-approval failed, manual approval may be required"
                        }
                    }
                   
                    if ($provState -eq "Succeeded" -or $provState -eq "Failed") {
                        $completed = $true
                       
                        if ($provState -eq "Succeeded") {
                            Write-Host "##[section] Endpoint created successfully"
                            Write-Host "##[debug] Final connection state: $connState"
                            # Output the endpoint ID for Terraform to capture
                            Write-Output "ENDPOINT_ID=$endpointId"
                           
                            if ($connState -eq "Approved") {
                                Write-Host "##[section] Private endpoint is fully connected and approved!"
                            } elseif ($connState -eq "Pending") {
                                Write-Warning " Private endpoint created but still pending approval"
                            }
                        } else {
                            Write-Warning " Endpoint creation failed with state: $provState"
                            if ($statusResponse.connectionState) {
                                Write-Host "##[debug] Final connection state: $($statusResponse.connectionState.status) - $($statusResponse.connectionState.description)"
                            }
                        }
                    }
                   
                    $retryCount++
                }
               
                if (-not $completed) {
                    Write-Warning " Timeout waiting for endpoint provisioning. Last state: $provState"
                }
            } catch {
                $errorDetails = $_.Exception.Message
                if ($_.Exception.Response) {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $errorDetails = $reader.ReadToEnd()
                    $reader.Close()
                }
                Write-Error " Error creating managed private endpoint: $errorDetails"
                Write-Output "ERROR=$errorDetails"
            }
        } else {
            $endpointId = $existingEndpoint.id
            Write-Host "##[debug] Endpoint '$EndpointName' already exists with ID: $endpointId"
            Write-Output "ENDPOINT_ID=$endpointId"
           
            # Check if we need to update the endpoint
            $needsUpdate = $false
            if ($existingEndpoint.targetPrivateLinkResourceId -ne $TargetResourceId) {
                Write-Warning " Target resource ID differs - current: $($existingEndpoint.targetPrivateLinkResourceId), new: $TargetResourceId"
                $needsUpdate = $true
            }
            if ($existingEndpoint.targetSubresourceType -ne $TargetSubresourceType) {
                Write-Warning " Target subresource type differs - current: $($existingEndpoint.targetSubresourceType), new: $TargetSubresourceType"
                $needsUpdate = $true
            }
           
            if ($needsUpdate) {
                Write-Warning " Endpoint properties have changed. Delete and recreate is required."
                Write-Output "NEEDS_UPDATE=true"
             
                # Delete Azure connections first if enabled
                if ($DeleteAzureConnection) {
                    Write-Host "##[debug]Deleting Azure connections before update..."
                    $connections = Get-AzurePrivateEndpointConnections -TargetResourceId $TargetResourceId -EndpointName $EndpointName
                   
                    foreach ($connection in $connections) {
                        Remove-AzurePrivateEndpointConnection -TargetResourceId $TargetResourceId -ConnectionName $connection.name
                    }
                    Start-Sleep -Seconds 10
                }
               
                # Proceed with deletion and recreation automatically
                Write-Host "##[debug] Deleting existing endpoint to update properties"
                $deleteUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/managedPrivateEndpoints/$endpointId"
                Invoke-RestMethod -Uri $deleteUrl -Headers $headers -Method Delete
                Write-Host "##[debug] Successfully deleted endpoint for update"
             
                # Wait briefly for deletion to process      
                Start-Sleep -Seconds 15
             
                # Create new endpoint with updated properties
                Write-Host "##[debug] Creating new endpoint with updated properties"
                $body = @{
                    name = $EndpointName
                    targetPrivateLinkResourceId = $TargetResourceId
                    targetSubresourceType = $TargetSubresourceType
                    requestMessage = $RequestMessage
                } | ConvertTo-Json
             
                $createUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/managedPrivateEndpoints"
                $response = Invoke-RestMethod -Uri $createUrl -Headers $headers -Method Post -Body $body
                $newEndpointId = $response.id
                Write-Host "##[section] Successfully updated managed private endpoint: $newEndpointId"
                Write-Output "ENDPOINT_ID=$newEndpointId"
               
                # Auto-approve the new endpoint if enabled
                if ($AutoApprove) {
                    Write-Host "##[debug] Attempting auto-approval for updated endpoint..."
                    $approvalSuccess = Approve-PrivateEndpointConnection -TargetResourceId $TargetResourceId -PrivateEndpointId $newEndpointId -MaxRetries 3
                   
                    if ($approvalSuccess) {
                        Write-Host "##[section] Auto-approval completed for updated endpoint"
                    } else {
                        Write-Warning " Auto-approval failed for updated endpoint"
                    }
                }
            }
        }
    }
} catch {
    $errorDetails = $_.Exception.Message
    if ($_.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $errorDetails = $reader.ReadToEnd()
        $reader.Close()
    }
   
    Write-Error " Error during API operations: $errorDetails"
    Write-Output "ERROR=$errorDetails"
}

Write-Host "##[debug] Finished Fabric Managed Private Endpoint operation"
