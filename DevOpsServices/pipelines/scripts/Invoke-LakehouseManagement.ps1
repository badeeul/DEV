param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("CreateOrUpdate", "Delete")]
    [string]$Action,
   
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory=$false)]
    [string]$DisplayName,
   
    [Parameter(Mandatory=$false)]
    [bool]$EnableSchemas = $true,
   
    [Parameter(Mandatory=$false)]
    [string]$FolderHierarchy,
   
    [Parameter(Mandatory=$false)]
    [string]$FolderPath
)

function Get-FabricAccessToken {
    param(
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 5
    )
   
    $attempt = 1
   
    while ($attempt -le $MaxRetries) {
        try {
            Write-Host "Retrieving Fabric access token using Azure CLI (Attempt $attempt of $MaxRetries)"
           
            # Login to Azure using service principal
            $clientId = $env:ARM_CLIENT_ID
            $clientSecret = $env:ARM_CLIENT_SECRET
            $tenantId = $env:ARM_TENANT_ID
           
            if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($clientSecret) -or [string]::IsNullOrEmpty($tenantId)) {
                Write-Error "ARM_CLIENT_ID, ARM_CLIENT_SECRET, and ARM_TENANT_ID environment variables must be set"
                throw "Missing Azure service principal credentials"
            }
           
            Write-Host "Logging in to Azure with service principal (Attempt $attempt)"
            $loginResult = az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId 2>&1
           
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Azure CLI login failed: $loginResult"
                throw "Azure CLI login failed"
            }
           
            Write-Host "Successfully logged in to Azure"
           
            # Get access token for PowerBI/Fabric API
            Write-Host "Retrieving access token for Fabric API (Attempt $attempt)"
            $tokenResult = az account get-access-token --resource https://api.fabric.microsoft.com/ --query accessToken --output tsv 2>&1
           
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to get Fabric access token: $tokenResult"
                throw "Failed to get Fabric access token"
            }
           
            if ([string]::IsNullOrEmpty($tokenResult)) {
                Write-Error "Received empty access token"
                throw "Received empty access token"
            }
           
            Write-Host "Successfully retrieved Fabric access token on attempt $attempt"
            return $tokenResult.Trim()
        }
        catch {
            Write-Warning "Attempt $attempt failed to get Fabric access token: $_"
           
            if ($attempt -eq $MaxRetries) {
                Write-Error "Failed to get Fabric access token after $MaxRetries attempts. Last error: $_"
                throw "Failed to get Fabric access token after $MaxRetries attempts: $_"
            }
           
            Write-Host "Waiting $RetryDelaySeconds seconds before retry..."
            Start-Sleep -Seconds $RetryDelaySeconds
            $attempt++
        }
    }
}

function Get-WorkspaceIdByName {
    param(
        [string]$Name,
        [string]$Token
    )
   
    try {
        Write-Host "Looking up workspace ID for workspace name: $Name"
       
        # Construct API URL to get all workspaces
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get all workspaces
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5
       
        # Iterate through workspaces to find matching display name
        $matchingWorkspace = $response.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingWorkspace) {
            Write-Error "No workspace found with name: $Name"
            exit 1
        }
       
        $workspaceId = $matchingWorkspace.id
        Write-Host "##[debug]Found workspace ID: $workspaceId for workspace name: $Name"
        return $workspaceId
    }
    catch {
        Write-Error "Failed to get workspace ID: $_"
        exit 1
    }
}

function Get-LakehouseIdByName {
    param(
        [string]$WorkspaceId,
        [string]$Name,
        [string]$Token
    )
   
    try {
        Write-Host "Looking up lakehouse ID for lakehouse name: $Name in workspace: $WorkspaceId"
       
        # Construct API URL for lakehouses in the workspace
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get lakehouses
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        # Iterate through lakehouses to find matching display name
        $matchingLakehouse = $response.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingLakehouse) {
            Write-Warning "No lakehouse found with name: $Name"
            return $null
        }

        $lakehouseId = $matchingLakehouse.id
        Write-Host "##[debug]Found lakehouse ID: $lakehouseId for lakehouse name: $Name"
        return $lakehouseId
    }
    catch {
        Write-Error "Failed to get lakehouse ID: $_"
        exit 1
    }
}

function Get-FolderIdByPath {
    param(
        [string]$FolderPath,
        [string]$FolderHierarchy
    )
   
    try {
        if ([string]::IsNullOrEmpty($FolderHierarchy) -or [string]::IsNullOrEmpty($FolderPath)) {
            return $null
        }
       
        # Parse the folder hierarchy JSON
        $folders = $FolderHierarchy | ConvertFrom-Json
       
        #  truncate folder path upto before the last backcslash
        if ($FolderPath -like "*\*") {
            $FolderPath = $FolderPath.Substring(0, $FolderPath.LastIndexOf('\'))
        }
        # replace folderPath backslashes with forward slashes
        $FolderPath = $FolderPath -replace '\\', '/'
        Write-Host "##[debug]Looking up folder ID for path: $FolderPath"

        # Find the folder with matching path
        $matchingFolder = $folders | Where-Object { $_.Path -eq $FolderPath }
       
        if ($null -eq $matchingFolder) {
            Write-Warning "No folder found with path: $FolderPath"
            return $null
        }

        Write-Host "##[debug]Found folder ID: $($matchingFolder.Id) for path: $FolderPath"
        return $matchingFolder.Id
    }
    catch {
        Write-Error "Failed to get folder ID: $_"
        return $null
    }
}

function Create-Lakehouse {
    param(
        [string]$WorkspaceId,
        [string]$DisplayName,
        [string]$Description,
        [bool]$EnableSchemas,
        [string]$FolderId,
        [string]$Token
    )
   
    try {
        Write-Host "Creating lakehouse '$DisplayName' in workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Prepare request body
        $body = @{
            displayName = $DisplayName
            creationPayload = @{
                enableSchemas = $EnableSchemas
            }
        }
       
        # Add folder ID if provided
        if (-not [string]::IsNullOrEmpty($FolderId)) {
            $body.folderId = $FolderId
            Write-Host "Creating lakehouse in folder: $FolderId"
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        Write-Host "##[debug]Request body: $jsonBody"
       
        # Send request to create lakehouse
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5
       
        Write-Host "##[debug]Successfully created lakehouse '$DisplayName' with ID: $($response.id)"      
        return $response 
    }
    catch {
        Write-Error "Failed to create lakehouse '$DisplayName': $_"
        exit 1
    }
}

function Delete-Lakehouse {
    param(
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$Token
    )
   
    try {
        Write-Host "Deleting lakehouse with ID: $LakehouseId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses/$LakehouseId"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to delete lakehouse
        Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method DELETE -MaxRetries 5
       
        Write-Host "##[debug]Successfully deleted lakehouse with ID: $LakehouseId"
       
    }
    catch {
        Write-Error "Failed to delete lakehouse with ID '$LakehouseId': $_"
        exit 1
    }
}

function Update-Lakehouse {
    param(
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$DisplayName,
        [string]$Token
    )
   
    try {
        Write-Host "Updating lakehouse with ID: $LakehouseId in workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses/$LakehouseId"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Prepare request body
        $body = @{}
       
        if (-not [string]::IsNullOrEmpty($DisplayName)) {
            $body.displayName = $DisplayName
        }
    
        if ($body.Count -eq 0) {
            Write-Warning "No properties to update"
            return
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        Write-Host "##[debug]Request body: $jsonBody"
       
        # Send request to update lakehouse
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method PATCH -Body $jsonBody -MaxRetries 5
       
        Write-Host "##[debug]Successfully updated lakehouse with ID: $LakehouseId"       
       
        return $response
    }
    catch {
        Write-Error "Failed to update lakehouse with ID '$LakehouseId': $_"
        exit 1
    }
}

function Get-Lakehouse {
    param(
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$Token
    )
   
    try {
        Write-Host "Getting lakehouse with ID: $LakehouseId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses/$LakehouseId"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get lakehouse
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        Write-Host "##[debug]Successfully retrieved lakehouse: $($response.displayName)"
        return $response
    }
    catch {
        Write-Error "Failed to get lakehouse with ID '$LakehouseId': $_"
        exit 1
    }
}

function Get-LakehouseList {
    param(
        [string]$WorkspaceId,
        [string]$Token
    )
   
    try {
        Write-Host "Getting list of lakehouses from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get lakehouses
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        Write-Host "##[debug]Successfully retrieved $($response.value.Count) lakehouse(s)"
        return $response.value
    }
    catch {
        Write-Error "Failed to get lakehouse list: $_"
        exit 1
    }
}

function Invoke-FabricApiWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method,
        [string]$Body = $null,
        [int]$MaxRetries = 3,
        [int]$BaseRetryDelaySeconds = 30
    )
   
    $attempt = 1
   
    while ($attempt -le $MaxRetries) {
        try {
            Write-Host "##[debug]API call attempt $attempt of $MaxRetries to: $Uri"
           
            $requestParams = @{
                Uri = $Uri
                Headers = $Headers
                Method = $Method
            }
           
            if (-not [string]::IsNullOrEmpty($Body)) {
                $requestParams.Body = $Body
            }
           
            $response = Invoke-RestMethod @requestParams
            Write-Host "##[debug]API call successful on attempt $attempt"
            return $response
        }
        catch {
            $errorResponse = $null
           
            # Try to get the response body if available
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $errorResponse = $reader.ReadToEnd()
                    $reader.Close()
                }
                catch {
                    Write-Host "##[debug]Could not read error response body"
                }
            }
           
            # Check if this is a RequestBlocked error
            if ($errorResponse -and $errorResponse.Contains('"errorCode":"RequestBlocked"')) {
                Write-Host "##[warning]Request blocked by upstream service. Error response: $errorResponse"
               
                if ($attempt -eq $MaxRetries) {
                    Write-Error "Max retries reached. Request still blocked. Last error: $errorResponse"
                    throw "Max retries reached for blocked request: $_"
                }
               
                # Use exponential backoff for blocked requests
                $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
                Write-Host "##[debug]Request blocked, using exponential backoff: $retryDelay seconds"
                Start-Sleep -Seconds $retryDelay
               
                $attempt++
                continue
            }
           
            # For non-RequestBlocked errors, use standard retry logic
            if ($attempt -eq $MaxRetries) {
                Write-Error "API call failed after $MaxRetries attempts. Last error: $_"
                if ($errorResponse) {
                    Write-Error "Response body: $errorResponse"
                }
                throw "API call failed after $MaxRetries attempts: $_"
            }
           
            # Exponential backoff for other errors
            $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Host "##[warning]API call failed (attempt $attempt), retrying in $retryDelay seconds. Error: $_"
            Start-Sleep -Seconds $retryDelay
            $attempt++
        }
    }
}

function Move-LakehouseToFolder {
    param(
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$TargetFolderId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Moving Lakehouse with ID: $LakehouseId to folder: $TargetFolderId"
       
        # Construct API URL for moving item
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$LakehouseId/move"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Prepare request body
        $body = @{
            targetFolderId = $TargetFolderId
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
       
        # Send request to move Lakehouse
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5

        Write-Host "##[debug]Successfully moved Lakehouse with ID: $LakehouseId to folder: $TargetFolderId"

        return $response
    }
    catch {
        Write-Error "Failed to move Lakehouse with ID '$LakehouseId' to folder '$TargetFolderId': $_"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

function Get-LakehouseCurrentFolder {
    param(
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting current folder for environment with ID: $LakehouseId"

        # Get LakehouseId details which should include folder information
        $lakehouse = Get-Lakehouse -WorkspaceId $WorkspaceId -LakehouseId $LakehouseId -Token $Token

        # The folderId property indicates the current folder
        $currentFolderId = $lakehouse.folderId

        if ([string]::IsNullOrEmpty($currentFolderId)) {
            Write-Host "##[debug]Lakehouse is currently in the workspace root (no folder)"
            return $null
        }

        Write-Host "##[debug]Lakehouse is currently in folder: $currentFolderId"
        return $currentFolderId
    }
    catch {
        Write-Error "Failed to get current folder for lakehouse with ID '$LakehouseId': $_"
        exit 1
    }
}


# Main execution
try {
    Write-Host "##[debug]Starting lakehouse management operation: $Action"
    Write-Host "##[debug] Parameters received:"
    Write-Host "##[debug] - WorkspaceId: $WorkspaceId"
    Write-Host "##[debug] - DisplayName: $DisplayName"
    Write-Host "##[debug] - FolderPath: $FolderPath"
    # Get Fabric token
    $token = Get-FabricAccessToken -DisplayName $DisplayName
    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "FABRIC_TOKEN environment variable is not set"
        exit 1
    }
   
    # Get folder ID if folder path is provided
    $folderId = $null
    if (-not [string]::IsNullOrEmpty($FolderPath)) {
        $folderId = Get-FolderIdByPath -FolderPath $FolderPath -FolderHierarchy $FolderHierarchy
    }
   
    switch ($Action.ToLower()) {
      
        "createorupdate" {
            if ([string]::IsNullOrEmpty($DisplayName)) {
                Write-Error "DisplayName is required for CreateOrUpdate action"
                exit 1
            }
           
            $existingLakehouse = $null
           
            # If not found by key, try to find by name
            if ($null -eq $existingLakehouse) {
                Write-Host "Looking for existing lakehouse by name: $DisplayName"
                $existingLakehouseId = Get-LakehouseIdByName -WorkspaceId $WorkspaceId -Name $DisplayName -Token $token
                if ($null -ne $existingLakehouseId) {
                    $existingLakehouse = Get-Lakehouse -WorkspaceId $WorkspaceId -LakehouseId $existingLakehouseId -Token $token
                }
            }
           
            if ($null -eq $existingLakehouse) {
                Write-Host "##[debug]Lakehouse does not exist, creating new lakehouse: $DisplayName"
                $result = Create-Lakehouse -WorkspaceId $WorkspaceId -DisplayName $DisplayName -Description $Description -EnableSchemas $EnableSchemas -FolderId $folderId -Token $token

                # Update data access roles for the lakehouse
                Write-Host "##[debug]Executing data access roles assignment for lakehouse '$DisplayName'"
                & "$PSScriptRoot\Update-OneLakeDataAccessRoles.ps1" `
                    -workspaceId $WorkspaceId `
                    -lakehouseName $DisplayName
                Write-Host "##[debug]Successfully completed data access roles assignment for lakehouse '$DisplayName' "

                Write-Host "##[debug]Create Lakehouse: $($result | ConvertTo-Json -Depth 10 -Compress)"
                $result = $($result | ConvertTo-Json -Depth 10 -Compress)
                return $result
            } else {
                Write-Host "##[debug]Lakehouse exists (Name: '$($existingLakehouse.displayName)', ID: $($existingLakehouse.id)), updating properties"

                $result = Update-Lakehouse -WorkspaceId $WorkspaceId -LakehouseId $existingLakehouse.id -DisplayName $DisplayName -Token $token
                # Move to target folder if specified and different from current
                if (-not [string]::IsNullOrEmpty($folderId)) {
                    # Get current folder of the lakehouse
                    $currentFolderId = Get-LakehouseCurrentFolder -WorkspaceId $WorkspaceId -LakehouseId $existingLakehouse.id -Token $token

                    # Check if the lakehouse needs to be moved
                    $needsMove = $false
                    if ([string]::IsNullOrEmpty($currentFolderId) -and -not [string]::IsNullOrEmpty($folderId)) {
                        # lakehouse is in root, but should be in a folder
                        $needsMove = $true
                        Write-Host "##[debug]lakehouse is currently in workspace root, needs to move to folder: $folderId"
                    } elseif (-not [string]::IsNullOrEmpty($currentFolderId) -and $currentFolderId -ne $folderId) {
                        # lakehouse is in different folder
                        $needsMove = $true
                        Write-Host "##[debug]lakehouse is currently in folder: $currentFolderId, needs to move to folder: $folderId"
                    } else {
                        Write-Host "##[debug]lakehouse is already in the correct folder: $folderId"
                    }
                   
                    if ($needsMove) {
                        Write-Host "##[debug]Moving lakehouse to target folder: $folderId"
                        Move-LakehouseToFolder -WorkspaceId $WorkspaceId -LakehouseId $existingLakehouse.id -TargetFolderId $folderId -Token $token
                        Write-Host "##[debug]Successfully moved lakehouse to folder: $folderId"
                    }
                }
                # Update data access roles for the lakehouse
                Write-Host "##[debug]Executing data access roles assignment for lakehouse '$DisplayName'"
                & "$PSScriptRoot\Update-OneLakeDataAccessRoles.ps1" `
                    -workspaceId $WorkspaceId `
                    -lakehouseName $DisplayName
                Write-Host "##[debug]Successfully completed data access roles assignment for lakehouse '$DisplayName' "

                Write-Host "##[debug]Update Lakehouse: $($result | ConvertTo-Json -Depth 10 -Compress)"
                $result = $($result | ConvertTo-Json -Depth 10 -Compress)
                return $result
            }
            
        }
       
        "delete" {
            if ([string]::IsNullOrEmpty($LakehouseId) -and [string]::IsNullOrEmpty($DisplayName)) {
                Write-Error "Either LakehouseId or DisplayName is required for Delete action"
                exit 1
            }
           
            $lakehouseIdToDelete = $LakehouseId
            if ([string]::IsNullOrEmpty($lakehouseIdToDelete)) {
                $lakehouseIdToDelete = Get-LakehouseIdByName -WorkspaceId $WorkspaceId -Name $DisplayName -Token $token
                if ($null -eq $lakehouseIdToDelete) {
                    Write-Warning "Lakehouse '$DisplayName' not found for deletion"
                    return
                }
            }
           
            Delete-Lakehouse -WorkspaceId $WorkspaceId -LakehouseId $lakehouseIdToDelete -Token $token
        }

        default {
            Write-Error "Invalid action: $Action. Valid actions are: Create, Delete, Update, Get, List, CreateOrUpdate"
            exit 1
        }
    }
   
    Write-Host "Lakehouse management operation completed successfully"
}
catch {
    Write-Error "Error in lakehouse management operation: $_"
    exit 1
}
