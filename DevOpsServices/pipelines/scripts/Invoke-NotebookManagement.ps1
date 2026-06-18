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
    [string]$FolderPath,
   
    [Parameter(Mandatory=$false)]
    [string]$IpynbFile,
   
    [Parameter(Mandatory=$false)]
    [string]$PlatformFile,
   
    [Parameter(Mandatory=$false)]
    [string]$EnvironmentId,
   
    [Parameter(Mandatory=$false)]
    [string]$LakehouseName,
   
    [Parameter(Mandatory=$false)]
    [string]$LakehouseId
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

function Get-NotebookIdByName {
    param(
        [string]$WorkspaceId,
        [string]$Name,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Looking up notebook ID for notebook name: $Name in workspace: $WorkspaceId"
       
        # Construct API URL for notebooks in the workspace
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get notebooks
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        # Iterate through notebooks to find matching display name
        $matchingNotebook = $response.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingNotebook) {
            Write-Warning "No notebook found with name: $Name"
            return $null
        }

        $notebookId = $matchingNotebook.id
        Write-Host "##[debug]Found notebook ID: $notebookId for notebook name: $Name"
        return $notebookId
    }
    catch {
        Write-Error "Failed to get notebook ID: $_"
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

function ConvertTo-Base64 {
    param(
        [string]$FilePath
    )
   
    try {
        if (-not (Test-Path $FilePath)) {
            Write-Error "File not found: $FilePath"
            return $null
        }
   
        $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)      
        $base64String = [System.Convert]::ToBase64String($fileBytes)

        return $base64String
    }
    catch {
        Write-Error "Failed to convert file to Base64: $_"
        return $null
    }
}

function Create-Notebook {
    param(
        [string]$WorkspaceId,
        [string]$DisplayName,
        [string]$FolderId,
        [string]$IpynbFile,
        [string]$PlatformFile,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Creating notebook '$DisplayName' in workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Convert files to Base64
        $ipynbBase64 = ConvertTo-Base64 -FilePath $IpynbFile
        if ([string]::IsNullOrEmpty($ipynbBase64)) {
            Write-Error "Failed to convert notebook content file to Base64"
            exit 1
        }
       
        # Prepare notebook definition parts
        $parts = @(
            @{
                path = "notebook-content.ipynb"
                payload = $ipynbBase64
                payloadType = "InlineBase64"
            }
        )
       
        # Prepare request body
        $body = @{
            displayName = $DisplayName
            definition = @{
                format = "ipynb"
                parts = $parts
            }
        }
       
        # Add folder ID if provided
        if (-not [string]::IsNullOrEmpty($FolderId)) {
            $body.folderId = $FolderId
            Write-Host "##[debug]Creating notebook in folder: $FolderId"
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        Write-Host "##[debug]Request body structure prepared for notebook creation"
       
        # Send request to create notebook
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5

        Write-Host "##[debug]Successfully created notebook '$DisplayName' with ID: $($response.id)"

        return $response
    }
    catch {
        Write-Error "Failed to create notebook '$DisplayName': $_"
        Write-Error "Response: $($_.Exception.Response)"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

function Delete-Notebook {
    param(
        [string]$WorkspaceId,
        [string]$NotebookId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Deleting notebook with ID: $NotebookId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks/$NotebookId"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to delete notebook
        Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method DELETE -MaxRetries 5

        Write-Host "##[debug]Successfully deleted notebook with ID: $NotebookId"
       
    }
    catch {
        Write-Error "Failed to delete notebook with ID '$NotebookId': $_"
        exit 1
    }
}

function Update-Notebook {
    param(
        [string]$WorkspaceId,
        [string]$NotebookId,
        [string]$DisplayName,
        [string]$IpynbFile,
        [string]$PlatformFile,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Updating notebook with ID: $NotebookId in workspace: $WorkspaceId"
       
        # For notebook updates, we need to update the definition
        $definitionUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks/$NotebookId/updateDefinition"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Convert files to Base64
        $ipynbBase64 = ConvertTo-Base64 -FilePath $IpynbFile

        # Prepare notebook definition parts
        $parts = @(
            @{
                path = "notebook-content.ipynb"
                payload = $ipynbBase64
                payloadType = "InlineBase64"
            }
        )
       
        # Prepare request body for definition update
        $definitionBody = @{
            definition = @{
                format = "ipynb"
                parts = $parts
            }
        }
       
        $jsonDefinitionBody = $definitionBody | ConvertTo-Json -Depth 10
       
        # Send request to update notebook definition
        $definitionResponse = Invoke-RestMethod -Uri $definitionUrl -Headers $headers -Method POST -Body $jsonDefinitionBody
       
        # Update notebook properties if needed
        if (-not [string]::IsNullOrEmpty($DisplayName)) {
            $propertiesUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks/$NotebookId"
           
            $propertiesBody = @{}
            if (-not [string]::IsNullOrEmpty($DisplayName)) {
                $propertiesBody.displayName = $DisplayName
            }

            if ($propertiesBody.Count -gt 0) {
                $jsonPropertiesBody = $propertiesBody | ConvertTo-Json -Depth 10
                $propertiesResponse = Invoke-FabricApiWithRetry -Uri $propertiesUrl -Headers $headers -Method PATCH -Body $jsonPropertiesBody -MaxRetries 5
            }
        }
       
        Write-Host "##[debug]Successfully updated notebook with ID: $NotebookId"      
       
        return $definitionResponse
    }
    catch {
        Write-Error "Failed to update notebook with ID '$NotebookId': $_"
        exit 1
    }
}

function Get-Notebook {
    param(
        [string]$WorkspaceId,
        [string]$NotebookId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting notebook with ID: $NotebookId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks/$NotebookId"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get notebook
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        Write-Host "##[debug]Successfully retrieved notebook: $($response.displayName)"
        return $response
    }
    catch {
        Write-Error "Failed to get notebook with ID '$NotebookId': $_"
        exit 1
    }
}

function Get-NotebookList {
    param(
        [string]$WorkspaceId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting list of notebooks from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get notebooks
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5   
       
        Write-Host "##[debug]Successfully retrieved $($response.value.Count) notebook(s)"
        return $response.value
    }
    catch {
        Write-Error "Failed to get notebook list: $_"
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


function Move-NotebookToFolder {
    param(
        [string]$WorkspaceId,
        [string]$NotebookId,
        [string]$TargetFolderId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Moving notebook with ID: $NotebookId to folder: $TargetFolderId"
       
        # Construct API URL for moving item
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$NotebookId/move"
       
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
       
        # Send request to move notebook
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5        
       
        Write-Host "##[debug]Successfully moved notebook with ID: $NotebookId to folder: $TargetFolderId"
       
        return $response
    }
    catch {
        Write-Error "Failed to move notebook with ID '$NotebookId' to folder '$TargetFolderId': $_"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

function Get-NotebookCurrentFolder {
    param(
        [string]$WorkspaceId,
        [string]$NotebookId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting current folder for notebook with ID: $NotebookId"
       
        # Get notebook details which should include folder information
        $notebook = Get-Notebook -WorkspaceId $WorkspaceId -NotebookId $NotebookId -Token $Token
       
        # The folderId property indicates the current folder
        $currentFolderId = $notebook.folderId
       
        if ([string]::IsNullOrEmpty($currentFolderId)) {
            Write-Host "##[debug]Notebook is currently in the workspace root (no folder)"
            return $null
        }
       
        Write-Host "##[debug]Notebook is currently in folder: $currentFolderId"
        return $currentFolderId
    }
    catch {
        Write-Error "Failed to get current folder for notebook with ID '$NotebookId': $_"
        exit 1
    }
}

# Main execution
try {
    Write-Host "##[debug]Starting notebook management operation: $Action"
    Write-Host "##[debug] Parameters received:"
    Write-Host "##[debug] - WorkspaceId: $WorkspaceId"
    Write-Host "##[debug] - DisplayName: $DisplayName"
    Write-Host "##[debug] - FolderPath: $FolderPath"
    Write-Host "##[debug] - IpynbFile: $IpynbFile"
    Write-Host "##[debug] - PlatformFile: $PlatformFile"
    Write-Host "##[debug] - EnvironmentId: $EnvironmentId"
    Write-Host "##[debug] - LakehouseName: $LakehouseName"
    Write-Host "##[debug] - LakehouseId: $LakehouseId"

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
           
            if ([string]::IsNullOrEmpty($IpynbFile) -or -not (Test-Path $IpynbFile)) {
                Write-Error "Valid IpynbFile path is required for CreateOrUpdate action"
                exit 1
            }
           
            if ([string]::IsNullOrEmpty($PlatformFile) -or -not (Test-Path $PlatformFile)) {
                Write-Error "Valid PlatformFile path is required for CreateOrUpdate action"
                exit 1
            }
           
            $existingNotebook = $null
           
            # Try to find by name
            Write-Host "##[debug]Looking for existing notebook by name: $DisplayName"
            $existingNotebookId = Get-NotebookIdByName -WorkspaceId $WorkspaceId -Name $DisplayName -Token $token
            if ($null -ne $existingNotebookId) {
                $existingNotebook = Get-Notebook -WorkspaceId $WorkspaceId -NotebookId $existingNotebookId -Token $token
            }

            if ($null -eq $existingNotebook) {
                Write-Host "##[debug]Notebook does not exist, creating new notebook: $DisplayName"
                $result = Create-Notebook -WorkspaceId $WorkspaceId -DisplayName $DisplayName -FolderId $folderId -IpynbFile $IpynbFile -PlatformFile $PlatformFile -Token $token
                Write-Host "##[debug] - Create Notebook Result: $($result | ConvertTo-Json -Depth 10 -Compress)"
                return $result
            } else {
                Write-Host "##[debug]Notebook exists (Name: '$($existingNotebook.displayName)', ID: $($existingNotebook.id)), updating definition and properties"
                $result = Update-Notebook -WorkspaceId $WorkspaceId -NotebookId $existingNotebook.id -DisplayName $DisplayName -IpynbFile $IpynbFile -PlatformFile $PlatformFile -Token $token
               
                # Move notebook to specified folder if folderId is provided and different from current
                if (-not [string]::IsNullOrEmpty($folderId)) {
                    # Get current folder of the notebook
                    $currentFolderId = Get-NotebookCurrentFolder -WorkspaceId $WorkspaceId -NotebookId $existingNotebook.id -Token $token
                   
                    # Check if the notebook needs to be moved
                    $needsMove = $false
                    if ([string]::IsNullOrEmpty($currentFolderId) -and -not [string]::IsNullOrEmpty($folderId)) {
                        # Notebook is in root, but should be in a folder
                        $needsMove = $true
                        Write-Host "##[debug]Notebook is currently in workspace root, needs to move to folder: $folderId"
                    } elseif (-not [string]::IsNullOrEmpty($currentFolderId) -and $currentFolderId -ne $folderId) {
                        # Notebook is in different folder
                        $needsMove = $true
                        Write-Host "##[debug]Notebook is currently in folder: $currentFolderId, needs to move to folder: $folderId"
                    } else {
                        Write-Host "##[debug]Notebook is already in the correct folder: $folderId"
                    }
                   
                    if ($needsMove) {
                        Write-Host "##[debug]Moving notebook to target folder: $folderId"
                        Move-NotebookToFolder -WorkspaceId $WorkspaceId -NotebookId $existingNotebook.id -TargetFolderId $folderId -Token $token
                        Write-Host "##[debug]Successfully moved notebook to folder: $folderId"
                    }
                }
                Write-Host "##[debug] - Update Notebook Result: $($result | ConvertTo-Json -Depth 10 -Compress)"
                return $result
            }

        }
       
        "delete" {
            if ([string]::IsNullOrEmpty($NotebookId) -and [string]::IsNullOrEmpty($DisplayName)) {
                Write-Error "Either NotebookId or DisplayName is required for Delete action"
                exit 1
            }
           
            $notebookIdToDelete = $NotebookId
            if ([string]::IsNullOrEmpty($notebookIdToDelete)) {
                $notebookIdToDelete = Get-NotebookIdByName -WorkspaceId $WorkspaceId -Name $DisplayName -Token $token
                if ($null -eq $notebookIdToDelete) {
                    Write-Warning "Notebook '$DisplayName' not found for deletion"
                    return
                }
            }
           
            Delete-Notebook -WorkspaceId $WorkspaceId -NotebookId $notebookIdToDelete -Token $token
        }
       
        default {
            Write-Error "Invalid action: $Action. Valid actions are: Create, Delete, Update, Get, List, CreateOrUpdate"
            exit 1
        }
    }
   
    Write-Host "##[debug]Notebook management operation completed successfully"
}
catch {
    Write-Error "Error in notebook management operation: $_"
    exit 1
}
