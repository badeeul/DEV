param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("CreateOrUpdate", "Delete")]
    [string]$Action,
   
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory=$false)]
    [string]$DisplayName,
   
    [Parameter(Mandatory=$false)]
    [string]$Description,
   
    [Parameter(Mandatory=$false)]
    [string]$FolderHierarchy,
   
    [Parameter(Mandatory=$false)]
    [string]$FolderPath,
   
    [Parameter(Mandatory=$false)]
    [string]$ContentFile,
   
    [Parameter(Mandatory=$false)]
    [string]$PlatformFile
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

function Get-KQLDashboardIdByName {
    param(
        [string]$WorkspaceId,
        [string]$Name,
        [string]$Token
    )
   
    try {
        Write-Host "Looking up KQL dashboard ID for dashboard name: $Name in workspace: $WorkspaceId"
       
        # Construct API URL for KQL dashboards in the workspace
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/kqlDashboards"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get KQL dashboards
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        # Iterate through dashboards to find matching display name
        $matchingDashboard = $response.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingDashboard) {
            Write-Warning "No KQL dashboard found with name: $Name"
            return $null
        }

        $dashboardId = $matchingDashboard.id
        Write-Host "##[debug]Found KQL dashboard ID: $dashboardId for dashboard name: $Name"
        return $dashboardId
    }
    catch {
        Write-Error "Failed to get KQL dashboard ID: $_"
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

function Create-KQLDashboard {
    param(
        [string]$WorkspaceId,
        [string]$DisplayName,
        [string]$Description,
        [string]$FolderId,
        [string]$ContentFile,
        [string]$PlatformFile,
        [string]$Token
    )
   
    try {
        Write-Host "Creating KQL dashboard '$DisplayName' in workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/kqlDashboards"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Prepare request body
        $body = @{
            displayName = $DisplayName
        }
       
        # Add description if provided
        if (-not [string]::IsNullOrEmpty($Description)) {
            $body.description = $Description
        }
       
        # Add folder ID if provided
        if (-not [string]::IsNullOrEmpty($FolderId)) {
            $body.folderId = $FolderId
            Write-Host "Creating KQL dashboard in folder: $FolderId"
        }
       
        # Add definition if content file exists
        if (-not [string]::IsNullOrEmpty($ContentFile) -and (Test-Path $ContentFile)) {
            $contentBase64 = ConvertTo-Base64 -FilePath $ContentFile
            if (-not [string]::IsNullOrEmpty($contentBase64)) {
                $body.definition = @{
                    format = $null
                    parts = @(
                        @{
                            path = "RealTimeDashboard.json"
                            payload = $contentBase64
                            payloadType = "InlineBase64"
                        }
                    )
                }
            }
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10

        Write-Host "##[debug]API URL for KQL dashboard creation: $apiUrl"    
        Write-Host "##[debug]Request body for KQL dashboard creation: $jsonBody"    

        Write-Host "##[debug]Request body structure prepared for KQL dashboard creation"
       
        # Send request to create KQL dashboard
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5

        Write-Host "##[debug]Successfully created KQL dashboard '$DisplayName' with ID: $($response.id)"

        return $response
    }
    catch {
        Write-Error "Failed to create KQL dashboard '$DisplayName': $_"
        Write-Error "Response: $($_.Exception.Response)"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

function Delete-KQLDashboard {
    param(
        [string]$WorkspaceId,
        [string]$DashboardId,
        [string]$Token
    )
   
    try {
        Write-Host "Deleting KQL dashboard with ID: $DashboardId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/kqlDashboards/$DashboardId"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to delete KQL dashboard
        Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method DELETE -MaxRetries 5
       
        Write-Host "##[debug]Successfully deleted KQL dashboard with ID: $DashboardId"
       
    }
    catch {
        Write-Error "Failed to delete KQL dashboard with ID '$DashboardId': $_"
        exit 1
    }
}

function Update-KQLDashboard {
    param(
        [string]$WorkspaceId,
        [string]$DashboardId,
        [string]$DisplayName,
        [string]$Description,
        [string]$ContentFile,
        [string]$Token
    )
   
    try {
        Write-Host "Updating KQL dashboard with ID: $DashboardId in workspace: $WorkspaceId"
       
        # Update dashboard properties if needed
        if (-not [string]::IsNullOrEmpty($DisplayName) -or -not [string]::IsNullOrEmpty($Description)) {
            $propertiesUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/kqlDashboards/$DashboardId"
           
            $headers = @{
                "Authorization" = "Bearer $Token"
                "Content-Type" = "application/json"
            }
           
            $propertiesBody = @{}
            if (-not [string]::IsNullOrEmpty($DisplayName)) {
                $propertiesBody.displayName = $DisplayName
            }
            if (-not [string]::IsNullOrEmpty($Description)) {
                $propertiesBody.description = $Description
            }
           
            if ($propertiesBody.Count -gt 0) {
                $jsonPropertiesBody = $propertiesBody | ConvertTo-Json -Depth 10
                $propertiesResponse = Invoke-FabricApiWithRetry -Uri $propertiesUrl -Headers $headers -Method PATCH -Body $jsonPropertiesBody -MaxRetries 5
                Write-Host "##[debug]Successfully updated KQL dashboard properties for ID: $DashboardId"
            }
        }
       
        # Update dashboard definition if content file exists
        if (-not [string]::IsNullOrEmpty($ContentFile) -and (Test-Path $ContentFile)) {
            $definitionUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/kqlDashboards/$DashboardId/updateDefinition"
           
            $contentBase64 = ConvertTo-Base64 -FilePath $ContentFile
            if (-not [string]::IsNullOrEmpty($contentBase64)) {
                $definitionBody = @{
                    definition = @{
                        format = "Default"
                        parts = @(
                            @{
                                path = "RealTimeDashboard.json"
                                payload = $contentBase64
                                payloadType = "InlineBase64"
                            }
                        )
                    }
                }
               
                $jsonDefinitionBody = $definitionBody | ConvertTo-Json -Depth 10
                $definitionResponse = Invoke-FabricApiWithRetry -Uri $definitionUrl -Headers $headers -Method POST -Body $jsonDefinitionBody -MaxRetries 5
            }
        }
       
        Write-Host "##[debug]Successfully updated KQL dashboard with ID: $DashboardId"      
       
        return $propertiesResponse
    }
    catch {
        Write-Error "Failed to update KQL dashboard with ID '$DashboardId': $_"
        exit 1
    }
}

function Get-KQLDashboard {
    param(
        [string]$WorkspaceId,
        [string]$DashboardId,
        [string]$Token
    )
   
    try {
        Write-Host "Getting KQL dashboard with ID: $DashboardId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/kqlDashboards/$DashboardId"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get KQL dashboard
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5
       
        Write-Host "##[debug]Successfully retrieved KQL dashboard: $($response.displayName)"
        return $response
    }
    catch {
        Write-Error "Failed to get KQL dashboard with ID '$DashboardId': $_"
        exit 1
    }
}

function Get-KQLDashboardList {
    param(
        [string]$WorkspaceId,
        [string]$Token
    )
   
    try {
        Write-Host "Getting list of KQL dashboards from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/kqlDashboards"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get KQL dashboards
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        Write-Host "##[debug]Successfully retrieved $($response.value.Count) KQL dashboard(s)"
        return $response.value
    }
    catch {
        Write-Error "Failed to get KQL dashboard list: $_"
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

function Move-KQLDashboardToFolder {
    param(
        [string]$WorkspaceId,
        [string]$DashboardId,
        [string]$TargetFolderId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Moving KQLDashboard with ID: $DashboardId to folder: $TargetFolderId"
       
        # Construct API URL for moving item
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$DashboardId/move"
       
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
       
        # Send request to move Dashboard
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5

        Write-Host "##[debug]Successfully moved Dashboard with ID: $DashboardId to folder: $TargetFolderId"
       
        return $response
    }
    catch {
        Write-Error "Failed to move DashboardId with ID '$DashboardId' to folder '$TargetFolderId': $_"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

function Get-KQLDashboardCurrentFolder {
    param(
        [string]$WorkspaceId,
        [string]$DashboardId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting current folder for environment with ID: $DashboardId"
       
        # Get DashboardId details which should include folder information
        $dashboard = Get-KQLDashboard -WorkspaceId $WorkspaceId -DashboardId $DashboardId -Token $Token
       
        # The folderId property indicates the current folder
        $currentFolderId = $dashboard.folderId
       
        if ([string]::IsNullOrEmpty($currentFolderId)) {
            Write-Host "##[debug]Dashboard is currently in the workspace root (no folder)"
            return $null
        }
       
        Write-Host "##[debug]Dashboard is currently in folder: $currentFolderId"
        return $currentFolderId
    }
    catch {
        Write-Error "Failed to get current folder for dashboard with ID '$DashboardId': $_"
        exit 1
    }
}


# Main execution
try {
    Write-Host "##[debug]Starting KQL dashboard management operation: $Action"
    Write-Host "##[debug] Parameters received:"
    Write-Host "##[debug] - WorkspaceId: $WorkspaceId"
    Write-Host "##[debug] - DisplayName: $DisplayName"
    Write-Host "##[debug] - FolderPath: $FolderPath"
    Write-Host "##[debug] - ContentFile: $ContentFile"
    Write-Host "##[debug] - PlatformFile: $PlatformFile"
   
    # Get Fabric token
    $token = Get-FabricAccessToken
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
           
            $existingDashboard = $null
           
            # Try to find by name
            Write-Host "Looking for existing KQL dashboard by name: $DisplayName"
            $existingDashboardId = Get-KQLDashboardIdByName -WorkspaceId $WorkspaceId -Name $DisplayName -Token $token
            if ($null -ne $existingDashboardId) {
                $existingDashboard = Get-KQLDashboard -WorkspaceId $WorkspaceId -DashboardId $existingDashboardId -Token $token
            }
            $resultJson = $null
            if ($null -eq $existingDashboard) {
                Write-Host "KQL dashboard does not exist, creating new dashboard: $DisplayName"
                $result = Create-KQLDashboard -WorkspaceId $WorkspaceId -DisplayName $DisplayName -Description $Description -FolderId $folderId -ContentFile $ContentFile -PlatformFile $PlatformFile -Token $token
                $resultJson = $result | ConvertTo-Json -Depth 10 -Compress
                Write-Output $resultJson
            } else {
                Write-Host "KQL dashboard exists (Name: '$($existingDashboard.displayName)', ID: $($existingDashboard.id)), updating definition and properties"
                $result = Update-KQLDashboard -WorkspaceId $WorkspaceId -DashboardId $existingDashboard.id -DisplayName $DisplayName -Description $Description -ContentFile $ContentFile -Token $token

                     # Move dashboard to specified folder if folderId is provided and different from current
                if (-not [string]::IsNullOrEmpty($folderId)) {
                    # Get current folder of the dashboard
                    $currentFolderId = Get-KQLDashboardCurrentFolder -WorkspaceId $WorkspaceId -DashboardId $existingDashboard.id -Token $token
                   
                    # Check if the dashboard needs to be moved
                    $needsMove = $false
                    if ([string]::IsNullOrEmpty($currentFolderId) -and -not [string]::IsNullOrEmpty($folderId)) {
                        # dashboard is in root, but should be in a folder
                        $needsMove = $true
                        Write-Host "##[debug]dashboard is currently in workspace root, needs to move to folder: $folderId"
                    } elseif (-not [string]::IsNullOrEmpty($currentFolderId) -and $currentFolderId -ne $folderId) {
                        # dashboard is in different folder
                        $needsMove = $true
                        Write-Host "##[debug]dashboard is currently in folder: $currentFolderId, needs to move to folder: $folderId"
                    } else {
                        Write-Host "##[debug]dashboard is already in the correct folder: $folderId"
                    }
                   
                    if ($needsMove) {
                        Write-Host "##[debug]Moving dashboard to target folder: $folderId"
                        Move-EnvironmentToFolder -WorkspaceId $WorkspaceId -DashboardId $existingDashboard.id -TargetFolderId $folderId -Token $token
                        Write-Host "##[debug]Successfully moved dashboard to folder: $folderId"
                    }
                }
                $resultJson = $result | ConvertTo-Json -Depth 10 -Compress
                Write-Output $resultJson

            }
            return $resultJson
        }
       
        "delete" {
            if ([string]::IsNullOrEmpty($DashboardId) -and [string]::IsNullOrEmpty($DisplayName)) {
                Write-Error "Either DashboardId or DisplayName is required for Delete action"
                exit 1
            }
           
            $dashboardIdToDelete = $DashboardId
            if ([string]::IsNullOrEmpty($dashboardIdToDelete)) {
                $dashboardIdToDelete = Get-KQLDashboardIdByName -WorkspaceId $WorkspaceId -Name $DisplayName -Token $token
                if ($null -eq $dashboardIdToDelete) {
                    Write-Warning "KQL dashboard '$DisplayName' not found for deletion"
                    return
                }
            }
           
            Delete-KQLDashboard -WorkspaceId $WorkspaceId -DashboardId $dashboardIdToDelete -Token $token
        }
       
        default {
            Write-Error "Invalid action: $Action. Valid actions are:  Delete, CreateOrUpdate"
            exit 1
        }
    }
   
    Write-Host "KQL dashboard management operation completed successfully"
}
catch {
    Write-Error "Error in KQL dashboard management operation: $_"
    exit 1
}