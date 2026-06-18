param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("CreateOrUpdate", "Delete")]
    [string]$Action,
   
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory=$false)]
    [string]$DisplayName,

    [Parameter(Mandatory=$false)]
    [string]$FolderHierarchy,
   
    [Parameter(Mandatory=$false)]
    [string]$FolderPath
)

function Get-FabricAccessToken {
    param(
        [string]$DisplayName
    )
    try {
        Write-Host "Retrieving Fabric access token using Azure CLI"
       
        # Login to Azure using service principal
        $clientId = $env:ARM_CLIENT_ID
        $clientSecret = $env:ARM_CLIENT_SECRET
        $tenantId = $env:ARM_TENANT_ID
       
        if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($clientSecret) -or [string]::IsNullOrEmpty($tenantId)) {
            Write-Error "ARM_CLIENT_ID, ARM_CLIENT_SECRET, and ARM_TENANT_ID environment variables must be set"
            throw "Missing Azure service principal credentials"
        }
       
        Write-Host "Logging in to Azure with service principal"
        $loginResult = az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId 2>&1
       
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Azure CLI login failed: $loginResult"
            throw "Azure CLI login failed"
        }
       
        Write-Host "Successfully logged in to Azure for $DisplayName"
       
        # Get access token for PowerBI/Fabric API
        Write-Host "Retrieving access token for Fabric API"
        $tokenResult = az account get-access-token --resource https://api.fabric.microsoft.com/ --query accessToken --output tsv 2>&1
       
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to get Fabric access token: $tokenResult"
            throw "Failed to get Fabric access token"
        }
       
        if ([string]::IsNullOrEmpty($tokenResult)) {
            Write-Error "Received empty access token"
            throw "Received empty access token"
        }
       
        Write-Host "Successfully retrieved Fabric access token"
        return $tokenResult.Trim()
    }
    catch {
        Write-Error "Failed to get Fabric access token: $_"
        throw
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

function Get-EnvironmentIdByName {
    param(
        [string]$WorkspaceId,
        [string]$Name,
        [string]$Token
    )
   
    try {
        Write-Host "Looking up environment ID for environment name: $Name in workspace: $WorkspaceId"
       
        # Construct API URL for environments in the workspace
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get environments
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        # Iterate through environments to find matching display name
        $matchingEnvironment = $response.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingEnvironment) {
            Write-Warning "No environment found with name: $Name"
            return $null
        }

        $environmentId = $matchingEnvironment.id
        Write-Host "##[debug]Found environment ID: $environmentId for environment name: $Name"
        return $environmentId
    }
    catch {
        Write-Error "Failed to get environment ID: $_"
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
       
        # Truncate folder path up to before the last backslash
        if ($FolderPath -like "*\*") {
            $FolderPath = $FolderPath.Substring(0, $FolderPath.LastIndexOf('\'))
        }
        # Replace folderPath backslashes with forward slashes
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

function Create-Environment {
    param(
        [string]$WorkspaceId,
        [string]$DisplayName,
        [string]$FolderId,
        [string]$Token
    )
   
    try {
        Write-Host "Creating environment '$DisplayName' in workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Prepare request body
        $body = @{
            displayName = $DisplayName
        }
       
        # Add folder ID if provided
        if (-not [string]::IsNullOrEmpty($FolderId)) {
            $body.folderId = $FolderId
            Write-Host "Creating environment in folder: $FolderId"
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        Write-Host "##[debug]Request body: $jsonBody"
       
        # Send request to create environment
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5

        Write-Host "##[debug]Successfully created environment '$DisplayName' with ID: $($response.id)"

        return $response
    }
    catch {
        Write-Error "Failed to create environment '$DisplayName': $_"
        exit 1
    }
}

function Delete-Environment {
    param(
        [string]$WorkspaceId,
        [string]$EnvironmentId,
        [string]$Token
    )
   
    try {
        Write-Host "Deleting environment with ID: $EnvironmentId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments/$EnvironmentId"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to delete environment
        Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method DELETE -MaxRetries 5

        Write-Host "##[debug]Successfully deleted environment with ID: $EnvironmentId"
       
    }
    catch {
        Write-Error "Failed to delete environment with ID '$EnvironmentId': $_"
        exit 1
    }
}

function Update-Environment {
    param(
        [string]$WorkspaceId,
        [string]$EnvironmentId,
        [string]$DisplayName,
        [string]$Token
    )
   
    try {
        Write-Host "Updating environment with ID: $EnvironmentId in workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments/$EnvironmentId"
       
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
       
        # Send request to update environment
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method PATCH -Body $jsonBody -MaxRetries 5

        Write-Host "##[debug]Successfully updated environment with ID: $EnvironmentId"

        return $response
    }
    catch {
        Write-Error "Failed to update environment with ID '$EnvironmentId': $_"
        exit 1
    }
}

function Get-Environment {
    param(
        [string]$WorkspaceId,
        [string]$EnvironmentId,
        [string]$Token
    )
   
    try {
        Write-Host "Getting environment with ID: $EnvironmentId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments/$EnvironmentId"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get environment
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        Write-Host "##[debug]Successfully retrieved environment: $($response.displayName)"
        return $response
    }
    catch {
        Write-Error "Failed to get environment with ID '$EnvironmentId': $_"
        exit 1
    }
}

function Get-EnvironmentList {
    param(
        [string]$WorkspaceId,
        [string]$Token
    )
   
    try {
        Write-Host "Getting list of environments from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get environments
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5
       
        Write-Host "##[debug]Successfully retrieved $($response.value.Count) environment(s)"
        return $response.value
    }
    catch {
        Write-Error "Failed to get environment list: $_"
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

function Move-EnvironmentToFolder {
    param(
        [string]$WorkspaceId,
        [string]$EnvironmentId,
        [string]$TargetFolderId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Moving environment with ID: $EnvironmentId to folder: $TargetFolderId"
       
        # Construct API URL for moving item
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$EnvironmentId/move"
       
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
       
        # Send request to move environment
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5
       
        Write-Host "##[debug]Successfully moved environment with ID: $EnvironmentId to folder: $TargetFolderId"
       
        return $response
    }
    catch {
        Write-Error "Failed to move environment with ID '$EnvironmentId' to folder '$TargetFolderId': $_"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

function Get-EnvironmentCurrentFolder {
    param(
        [string]$WorkspaceId,
        [string]$EnvironmentId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting current folder for environment with ID: $EnvironmentId"
       
        # Get environment details which should include folder information
        $environment = Get-Environment -WorkspaceId $WorkspaceId -EnvironmentId $EnvironmentId -Token $Token
       
        # The folderId property indicates the current folder
        $currentFolderId = $environment.folderId
       
        if ([string]::IsNullOrEmpty($currentFolderId)) {
            Write-Host "##[debug]Environment is currently in the workspace root (no folder)"
            return $null
        }
       
        Write-Host "##[debug]Environment is currently in folder: $currentFolderId"
        return $currentFolderId
    }
    catch {
        Write-Error "Failed to get current folder for environment with ID '$EnvironmentId': $_"
        exit 1
    }
}

# Main execution
try {
    Write-Host "##[debug]Starting environment management operation: $Action"
    Write-Host "##[debug] Parameters received:"
    Write-Host "##[debug] - WorkspaceId: $WorkspaceId"
    Write-Host "##[debug] - DisplayName: $DisplayName"
    Write-Host "##[debug] - FolderPath: $FolderPath"
    Write-Host "##[debug] - FolderHierarchy: $FolderHierarchy"

    # Get Fabric token
    $token = Get-FabricAccessToken -DisplayName $DisplayName
    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "Failed to retrieve Fabric access token"
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
           
            $existingEnvironment = $null
           
            # Try to find by name
            Write-Host "##[debug]Looking for existing environment by name: $DisplayName"
            $existingEnvironmentId = Get-EnvironmentIdByName -WorkspaceId $WorkspaceId -Name $DisplayName -Token $token
            if ($null -ne $existingEnvironmentId) {
                $existingEnvironment = Get-Environment -WorkspaceId $WorkspaceId -EnvironmentId $existingEnvironmentId -Token $token
            }

            if ($null -eq $existingEnvironment) {
                Write-Host "##[debug]Environment does not exist, creating new environment: $DisplayName"
                $result = Create-Environment -WorkspaceId $WorkspaceId -DisplayName $DisplayName -FolderId $folderId -Token $token
                Write-Host "##[debug]Create environment json: $($result | ConvertTo-Json -Depth 10 -Compress)"
                $result = $($result | ConvertTo-Json -Depth 10 -Compress)
                $existingEnvironmentId = Get-EnvironmentIdByName -WorkspaceId $WorkspaceId -Name $DisplayName -Token $token
                return $result
            } else {
                Write-Host "##[debug]Environment exists (Name: '$($existingEnvironment.displayName)', ID: $($existingEnvironment.id)), updating properties"
                $result = Update-Environment -WorkspaceId $WorkspaceId -EnvironmentId $existingEnvironment.id -DisplayName $DisplayName -Token $token

                 # Move environment to specified folder if folderId is provided and different from current
                if (-not [string]::IsNullOrEmpty($folderId)) {
                    # Get current folder of the environment
                    $currentFolderId = Get-EnvironmentCurrentFolder -WorkspaceId $WorkspaceId -EnvironmentId $existingEnvironment.id -Token $token
                   
                    # Check if the environment needs to be moved
                    $needsMove = $false
                    if ([string]::IsNullOrEmpty($currentFolderId) -and -not [string]::IsNullOrEmpty($folderId)) {
                        # environment is in root, but should be in a folder
                        $needsMove = $true
                        Write-Host "##[debug]environment is currently in workspace root, needs to move to folder: $folderId"
                    } elseif (-not [string]::IsNullOrEmpty($currentFolderId) -and $currentFolderId -ne $folderId) {
                        # environment is in different folder
                        $needsMove = $true
                        Write-Host "##[debug]environment is currently in folder: $currentFolderId, needs to move to folder: $folderId"
                    } else {
                        Write-Host "##[debug]environment is already in the correct folder: $folderId"
                    }
                   
                    if ($needsMove) {
                        Write-Host "##[debug]Moving environment to target folder: $folderId"
                        Move-EnvironmentToFolder -WorkspaceId $WorkspaceId -EnvironmentId $existingEnvironment.id -TargetFolderId $folderId -Token $token
                        Write-Host "##[debug]Successfully moved environment to folder: $folderId"
                    }
                    Write-Host "##[debug]Update environment json: $($result | ConvertTo-Json -Depth 10 -Compress)"
                    $result = $($result | ConvertTo-Json -Depth 10 -Compress)
                    return  $result
                }
            }
        }
       
        "delete" {
            if ([string]::IsNullOrEmpty($EnvironmentId) -and [string]::IsNullOrEmpty($DisplayName)) {
                Write-Error "Either EnvironmentId or DisplayName is required for Delete action"
                exit 1
            }
           
            $environmentIdToDelete = $EnvironmentId
            if ([string]::IsNullOrEmpty($environmentIdToDelete)) {
                $environmentIdToDelete = Get-EnvironmentIdByName -WorkspaceId $WorkspaceId -Name $DisplayName -Token $token
                if ($null -eq $environmentIdToDelete) {
                    Write-Warning "Environment '$DisplayName' not found for deletion"
                    return
                }
            }
           
            Delete-Environment -WorkspaceId $WorkspaceId -EnvironmentId $environmentIdToDelete -Token $token
        }
       
        default {
            Write-Error "Invalid action: $Action. Valid actions are: Create, Delete, Update, Get, List, CreateOrUpdate"
            exit 1
        }
    }
   
    Write-Host "Environment management operation completed successfully"
}
catch {
    Write-Error "Error in environment management operation: $_"
    exit 1
}