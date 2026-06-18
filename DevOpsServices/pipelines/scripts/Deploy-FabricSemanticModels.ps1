param(
    [Parameter(Mandatory=$false)]
    [string]$FolderHierarchy,
    [string]$SemanticModelsDetailJson,
    [string]$SemanticModelsParametersDetailJson
)


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
       
        # set folderPath to start after src/fabric
        if ($FolderPath -like "*src\fabric*") {
            $FolderPath = $FolderPath.Substring($FolderPath.IndexOf("src\fabric") + 11)
        }
       
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
            Write-Warning "No matching folder found for path: $FolderPath"
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

function Update-ParameterSourceSQLDatabase {
    param (
        [string]$fileContent,
        [string]$fileName
    )
   
    # get file name without extension
    $fileBaseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)

    # Pattern to match: source = "guid" meta [...]
    $sourcePattern = 'source\s*=\s*"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"'
   
    $matches = [regex]::Matches($fileContent, $sourcePattern)
   
    if ($matches.Count -gt 0) {
        Write-Host "`tFound $($matches.Count) source parameter(s) in file: $fileName"
       
        foreach ($match in $matches) {
            $currentGuid = $match.Groups[1].Value
            Write-Host "`t  Current source GUID: $currentGuid"
           
            # Look up the replacement value in SemanticModelsParametersDetail
            $replacement = $SemanticModelsParametersDetail | Where-Object { $_.name -eq $fileBaseName }
           
            if ($replacement) {
                $newGuid = $replacement.newValue
                Write-Host "`t  Replacing with new GUID: $newGuid"
               
                # Replace the old GUID with the new one
                $oldSourceLine = $match.Value
                $newSourceLine = $oldSourceLine -replace $currentGuid, $newGuid
               
                $fileContent = $fileContent.Replace($oldSourceLine, $newSourceLine)
                Write-Host "`t  Replacement successful"
            } else {
                Write-Host "`t  No replacement found in variable groups for GUID: $currentGuid" -ForegroundColor Yellow
            }
        }
    }
   
    return $fileContent
}

function Update-ParameterAzureStorage {
    param (
        [string]$fileContent,
        [string]$WorkspaceId,
        [string]$DisplayName
    )
   
    $azureStoragePattern =  'onelake\.dfs\.fabric\.microsoft\.com/([a-fA-F0-9-]{36})/([a-fA-F0-9-]{36})'
   
    Write-Host "`t[DEBUG] Searching for AzureStorage.DataLake patterns..."
    Write-Host "`t[DEBUG] File content length: $($fileContent.Length) characters"
   
    # Debug: Show first 500 characters
    $preview = $fileContent.Substring(0, [Math]::Min(500, $fileContent.Length))
    Write-Host "`t[DEBUG] File content preview:"
    Write-Host "`t$preview"
   
    $matches = [regex]::Matches($fileContent, $azureStoragePattern)
   
    if ($matches.Count -gt 0) {
        Write-Host "`tFound $($matches.Count) AzureStorage.DataLake parameter(s)"
       
        # Display all lakehouses for debugging
        Write-Host "`tAvailable lakehouses in workspace:"
        $global:WorkspaceLakehouses | ForEach-Object {
            Write-Host "`t  Lakehouse: '$($_.displayName)' - ID: '$($_.id)'"
        }
       
        foreach ($match in $matches) {
            $currentWorkspaceId = $match.Groups[1].Value
            $currentLakehouseId = $match.Groups[2].Value
           
            Write-Host "`t  Current Workspace ID: '$currentWorkspaceId'"
            Write-Host "`t  Current Lakehouse ID: '$currentLakehouseId'"
           
            # Determine the target lakehouse from variable group based on semantic model display name
            $targetLakehouse = $null
            $targetLakehouseName = $null
           
            # Look up the semantic model in the variable group to find the associated lakehouse
            foreach ($semanticModel in $SemanticModelsDetail) {
                if ($semanticModel.name -eq $DisplayName) {
                    $targetLakehouseName = $semanticModel.newValue
                    Write-Host "`t  Found semantic model mapping: '$DisplayName' -> Lakehouse: '$targetLakehouseName'"
                   
                    # Find the lakehouse by display name
                    $targetLakehouse = $global:WorkspaceLakehouses | Where-Object {
                        $_.displayName -eq $targetLakehouseName
                    }
                   
                    if ($targetLakehouse) {
                        Write-Host "`t  Found target lakehouse: '$($targetLakehouse.displayName)' (ID: '$($targetLakehouse.id)')"
                    } else {
                        Write-Host "`t  Warning: Could not find lakehouse with name '$targetLakehouseName'" -ForegroundColor Yellow
                    }
                    break
                }
            }
           
            if ($null -eq $targetLakehouse) {
                Write-Host "`t  No lakehouse mapping found for semantic model '$DisplayName', skipping replacement" -ForegroundColor Yellow
                continue
            }
           
            # Get the new lakehouse ID
            $newLakehouseId = $targetLakehouse.id
            $newWorkspaceId = $WorkspaceId
           
            Write-Host "`t  New Workspace ID: '$newWorkspaceId'"
            Write-Host "`t  New Lakehouse ID: '$newLakehouseId'"
           
            # Construct the new AzureStorage.DataLake URL
            $oldUrl = $match.Value
            $newUrl = $oldUrl -replace $currentWorkspaceId, $newWorkspaceId
            $newUrl = $newUrl -replace $currentLakehouseId, $newLakehouseId
           
            Write-Host "`t  Replacing:"
            Write-Host "`t    Old: $oldUrl"
            Write-Host "`t    New: $newUrl"
           
            # Replace in file content
            $fileContent = $fileContent.Replace($oldUrl, $newUrl)
            Write-Host "`t  Replacement successful" -ForegroundColor Green
        }
    } else {
        Write-Host "`tNo AzureStorage.DataLake patterns found in file"
    }
   
    return $fileContent
}

function Update-Connection {
    param (
        [string]$fileContent,
        [string]$WorkspaceId,
        [string]$DisplayName
    )
   
    # Use this pattern to match Sql.Database calls so we can capture both server and database ID
    $sqlDatabasePattern = 'Sql\.Database\("([^"]+)", "([^"]+)"\)'
   
    $matches = $fileContent | Select-String -pattern $sqlDatabasePattern -AllMatches
   
    if ($matches.Matches.Count -gt 0) {
        Write-Host "`tFound match for Sql.Database() call"

        # Display all lakehouses for debugging
        Write-Host "`tAvailable lakehouses in workspace:"
        $global:WorkspaceLakehouses | ForEach-Object {
            Write-Host "`t  Lakehouse: '$($_.displayName)' - ID: '$($_.id)'"
        }
       
        foreach ($match in $matches.Matches) {
            Write-Host "`tProcessing match: $($match.Value)"
           
            $currentServer = $match.Groups[1].Value
            # we expect database ID to be either lakehouse name so we can replace it with the actual database ID
            $currentDatabaseId = $match.Groups[2].Value
           
            Write-Host "`t  Current Server: '$currentServer'"
            Write-Host "`t  Current Database ID: '$currentDatabaseId'"
           
            # We are going to find lakehouse by display name first, then by ID
            $lakehouse = $global:WorkspaceLakehouses | Where-Object {
                $_.displayName -eq $currentDatabaseId -or $_.id -eq $currentDatabaseId
            }
           
            # check if lakehouse is null or empty
            if ([string]::IsNullOrEmpty($lakehouse)) {
                 # No matching lakehouse found, fetch semantic model lakehouse from variable group
                foreach ($semanticModel in $SemanticModelsDetail) {
                    if ($semanticModel.name -eq $DisplayName) {
                            $lakehouse = $global:WorkspaceLakehouses | Where-Object {
                                $_.displayName -eq $semanticModel.newValue
                            }
                            $currentDatabaseId = $semanticModel.newValue
                            break                        
                    }
                }                
            }

            if ($lakehouse) {
                Write-Host "`t  We've found lakehouse: '$($lakehouse.displayName)' (ID: '$($lakehouse.id)')"
               
                # Get the new connection string from lakehouse
                $newConnectionString = $lakehouse.properties.sqlEndpointProperties.connectionString
                Write-Host "`t  New connection string: '$newConnectionString'"
               
                # List SQL Endpoint properties
                $sqlEndpointUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/sqlEndpoints"
                $sqlEndpointsResponse = Invoke-FabricApiWithRetry -Uri $sqlEndpointUri -Headers $global:auth_header -Method Get -MaxRetries 5
                $newDatabaseId = $null

                foreach ($model in $sqlEndpointsResponse.value) {
                    if ($model.displayName -eq $currentDatabaseId) {
                        Write-Host "`t    Found SQL Endpoint: '$($model.displayName)' (ID: '$($model.id)')"
                        $newDatabaseId = $model.id
                        break
                    }
                }

                $newServer = $newConnectionString
               
                Write-Host "`t  Extracted new server: '$newServer'"
                Write-Host "`t  Extracted new database ID: '$newDatabaseId'"
               
                # Here we replace the entire Sql.Database()
                $oldSqlCall = $match.Value
                $newSqlCall = "Sql.Database(`"$newServer`", `"$newDatabaseId`")"
               
                Write-Host "`t  Replacing: '$oldSqlCall'"
                Write-Host "`t  With: '$newSqlCall'"
               
                $fileContent = $fileContent.Replace($oldSqlCall, $newSqlCall)
            }
        }
    }
   
    Write-Host "`tUpdated file content preview (first 500 chars):" -ForegroundColor Cyan
    Write-Host "`t$($fileContent.Substring(0, [Math]::Min(500, $fileContent.Length)))" -ForegroundColor Cyan
   
    return $fileContent
}

function Get-ContentPayload {
    param (
        [string]$filePath,
        [string]$fileName,
        [string]$WorkspaceId,
        [string]$DisplayName
    )

    $fileContent = Get-Content -Path $filePath -Raw -Encoding UTF8
    $fileExtension = [System.IO.Path]::GetExtension($fileName).ToLower()

   
    # Check if this is a .tmdl file and apply parameter replacement
    if ($fileExtension -eq ".tmdl") {
        Write-Host "`tProcessing TMDL file: $fileName"
        $fileContent = Update-ParameterSourceSQLDatabase -fileContent $fileContent -fileName $fileName

        # Update AzureStorage.DataLake parameters (workspace ID and lakehouse ID)
        $fileContent = Update-ParameterAzureStorage -fileContent $fileContent -WorkspaceId $WorkspaceId -DisplayName $DisplayName        
    }

    # Replace the search string with the update string
    if ($fileName -eq "expressions.tmdl") {

        # Replace SQLDatabase lakehouse connection string, and database Id, either given database id or lakehouse name
        $fileContent = Update-Connection -fileContent $fileContent -WorkspaceId $WorkspaceId -DisplayName $DisplayName

    } elseif ((Split-Path $filePath -Parent | Get-Item).Name -eq 'tables') {
        # Replace SQLDatabase lakehouse connection string, and database Id, either given database id or lakehouse name
        $fileContent = Update-Connection -fileContent $fileContent -WorkspaceId $WorkspaceId -DisplayName $DisplayName
    }
   
    $fileBytes = [System.Text.Encoding]::UTF8.GetBytes($fileContent)
    $contentPayload = [Convert]::ToBase64String($fileBytes)

    return $contentPayload
}

##################################
# Function to Gather Source Content Information from Microsoft Fabric
##################################
function Read-PlatformFiles {
    param (
        [string]$BaseFolderPath,
        [string]$FabricItemType = "SemanticModel",
        [string]$WorkspaceId
    )
    $results = @()
   
    # Get all subfolders in the base folder
    $folders = Get-ChildItem -Path $BaseFolderPath -Directory -Recurse -Include "*.$($FabricItemType)"  
   
    foreach ($folder in $folders) {
        $platformFilePath = Join-Path -Path $folder.FullName -ChildPath ".platform"
        $itemSourceFiles = Get-ChildItem -Path $folder.FullName -File -Recurse
       
        if (Test-Path -Path $platformFilePath) {
            $platformContent = Get-Content -Path $platformFilePath -Raw | ConvertFrom-Json            
            Write-Host "`tSemantic Model: $($platformContent.metadata.displayName)"
            $result = [pscustomobject]@{
                logicalId   = $platformContent.config.logicalId
                type        = $platformContent.metadata.type
                displayName = $platformContent.metadata.displayName
                description = $platformContent.metadata.description
                folderPath  = $folder.FullName
                relativeFolderPath = $folder.FullName.Replace($BaseFolderPath, "").TrimStart('\', '/')
                definitionParts = @()
            }

            $itemSourceFiles | ForEach-Object {
                if ($_.Name -ne ".platform") {
                   
                    $itemPath = $_.FullName.Substring($folder.FullName.Length + 1) -replace '\\', '/'
                    Write-Host "`t Semantic Model Relative Path: $($itemPath)"
                    $contentPayload = Get-ContentPayload -filePath $_.FullName -fileName $_.Name -WorkspaceId $WorkspaceId -DisplayName $platformContent.metadata.displayName
                   
                    $result.definitionParts += @{ $itemPath = $contentPayload }
                }
            }
            $results += $result
        }
    }
    return $results
}

function Get-WorkspaceItem (
    [string]$workspaceId,
    [string]$itemType
) {
    $itemUrl = "https://api.fabric.microsoft.com/v1/workspaces/{0}/items?type={1}" -f $workspaceId, $itemType
    try {
        $response = Invoke-FabricApiWithRetry -Uri $itemUrl -Headers $global:auth_header -Method GET -MaxRetries 5

        return $response.value
    }
    catch {Write-Output "`tError Message: $($_.Exception.Message)"}
    return @()
}

function Get-WorkspaceLakehouse (
    [string]$workspaceId
) {
    $itemUrl = "https://api.fabric.microsoft.com/v1/workspaces/{0}/lakehouses" -f $workspaceId
    try {
        $response = Invoke-FabricApiWithRetry -Uri $itemUrl -Headers $global:auth_header -Method GET -MaxRetries 5

        return $response.value
    }
    catch {Write-Output "`tError Message: $($_.Exception.Message)"}
    return @()
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

function Move-SemanticModelToFolder {
    param(
        [string]$WorkspaceId,
        [string]$SemanticModelId,
        [string]$TargetFolderId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Moving semantic model with ID: $SemanticModelId to folder: $TargetFolderId"

        # Construct API URL for moving item
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$SemanticModelId/move"

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
       
        # Send request to move semantic model
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5

        Write-Host "##[debug]Successfully moved semantic model with ID: $SemanticModelId to folder: $TargetFolderId"

        return $response
    }
    catch {
        Write-Error "Failed to move semantic model with ID '$SemanticModelId' to folder '$TargetFolderId': $_"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

function Get-SemanticModel {
    param(
        [string]$WorkspaceId,
        [string]$SemanticModelId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting semantic model with ID: $SemanticModelId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/semanticModels/$SemanticModelId"

        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }

        # Send request to get semantic model
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        Write-Host "##[debug]Successfully retrieved semantic model: $($response.displayName)"
        return $response
    }
    catch {
        Write-Error "Failed to get semantic model with ID '$SemanticModelId': $_"
        exit 1
    }
}

function Get-SemanticModelCurrentFolder {
    param(
        [string]$WorkspaceId,
        [string]$SemanticModelId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting current folder for semantic model with ID: $SemanticModelId"

        # Get semantic model details which should include folder information
        $semanticModel = Get-SemanticModel -WorkspaceId $WorkspaceId -SemanticModelId $SemanticModelId -Token $Token

        # The folderId property indicates the current folder
        $currentFolderId = $semanticModel.folderId

        if ([string]::IsNullOrEmpty($currentFolderId)) {
            Write-Host "##[debug]Semantic model is currently in the workspace root (no folder)"
            return $null
        }

        Write-Host "##[debug]Semantic model is currently in folder: $currentFolderId"
        return $currentFolderId
    }
    catch {
        Write-Error "Failed to get current folder for semantic model with ID '$SemanticModelId': $_"
        exit 1
    }
}

function Get-LakehouseSQLEndpointConnection {
    param(
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting SQL Endpoint connection for Lakehouse ID: $LakehouseId" -ForegroundColor Cyan
       
        # Get lakehouse details
        $lakehouse = $global:WorkspaceLakehouses | Where-Object { $_.id -eq $LakehouseId }
       
        if ($null -eq $lakehouse) {
            Write-Warning "Lakehouse not found with ID: $LakehouseId"
            return $null
        }
       
        # Get SQL Endpoint ID for the lakehouse
        $sqlEndpointUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/sqlEndpoints"
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        $sqlEndpointsResponse = Invoke-FabricApiWithRetry -Uri $sqlEndpointUri -Headers $headers -Method GET -MaxRetries 5
       
        # Find the SQL endpoint that matches the lakehouse
        $sqlEndpoint = $sqlEndpointsResponse.value | Where-Object {
            $_.displayName -eq $lakehouse.displayName
        }
       
        if ($null -eq $sqlEndpoint) {
            Write-Warning "SQL Endpoint not found for Lakehouse: $($lakehouse.displayName)"
            return $null
        }
       
        Write-Host "##[debug]Found SQL Endpoint: $($sqlEndpoint.displayName) (ID: $($sqlEndpoint.id))" -ForegroundColor Green
       
        # Get connection details from the lakehouse
        $connectionString = $lakehouse.properties.sqlEndpointProperties.connectionString
       
        # Parse connection string to get server and database
        # Format: "server.database.windows.net"
        if ($connectionString -match '^([^;]+)$') {
            $serverPath = $connectionString
           
            # Construct connection details
            $connectionDetails = @{
                lakehouseId = $LakehouseId
                sqlEndpointId = $sqlEndpoint.id
                connectionString = $connectionString
                serverPath = $serverPath
                databaseId = $sqlEndpoint.id
            }
           
            Write-Host "##[debug]Connection String: $connectionString" -ForegroundColor Gray
            Write-Host "##[debug]SQL Endpoint ID (Database ID): $($sqlEndpoint.id)" -ForegroundColor Gray
           
            return $connectionDetails
        }
        else {
            Write-Warning "Could not parse connection string: $connectionString"
            return $null
        }
    }
    catch {
        Write-Error "Failed to get SQL Endpoint connection for Lakehouse '$LakehouseId': $_"
        return $null
    }
}

function Bind-SemanticModelConnection {
    param(
        [string]$WorkspaceId,
        [string]$SemanticModelId,
        [string]$DisplayName,
        [string]$Token
    )
   
    try {
        Write-Host "##[section]========================================" -ForegroundColor Cyan
        Write-Host "##[section]Binding Semantic Model Connection" -ForegroundColor Cyan
        Write-Host "##[section]========================================" -ForegroundColor Cyan
        Write-Host "##[debug]Semantic Model: $DisplayName (ID: $SemanticModelId)" -ForegroundColor Cyan
       
        # Step 1: Determine target lakehouse from variable group
        $targetLakehouseName = $null
        $targetLakehouse = $null
       
        foreach ($semanticModel in $SemanticModelsDetail) {
            if ($semanticModel.name -eq $DisplayName) {
                $targetLakehouseName = $semanticModel.newValue
                Write-Host "##[debug]Found semantic model mapping: '$DisplayName' -> Lakehouse: '$targetLakehouseName'" -ForegroundColor Cyan
                break
            }
        }
       
        if ([string]::IsNullOrEmpty($targetLakehouseName)) {
            Write-Warning "No lakehouse mapping found for semantic model '$DisplayName' in variable group. Skipping connection binding."
            return $false
        }
       
        # Step 2: Find target lakehouse
        $targetLakehouse = $global:WorkspaceLakehouses | Where-Object {
            $_.displayName -eq $targetLakehouseName
        }
       
        if ($null -eq $targetLakehouse) {
            Write-Warning "Target lakehouse '$targetLakehouseName' not found in workspace. Skipping connection binding."
            return $false
        }
       
        Write-Host "##[debug]Target Lakehouse: $($targetLakehouse.displayName) (ID: $($targetLakehouse.id))" -ForegroundColor Green
       
        # Step 3: Get SQL Endpoint connection details
        $connectionDetails = Get-LakehouseSQLEndpointConnection `
            -WorkspaceId $WorkspaceId `
            -LakehouseId $targetLakehouse.id `
            -Token $Token
       
        if ($null -eq $connectionDetails) {
            Write-Warning "Could not get SQL Endpoint connection details for lakehouse '$targetLakehouseName'. Skipping connection binding."
            return $false
        }
       
               
        foreach ($semanticModel in $SemanticModelsDetail) {
            if ($semanticModel.name -eq $DisplayName) {
                $existingConnections = $fabricConnections | Where-Object {
                    $_.displayName -eq $semanticModel.connectionName  
                }
                break
            }
        }
       
        if ($existingConnections.Count -eq 0) {
            Write-Warning "No existing connections found for semantic model '$DisplayName'. Skipping connection binding."
            return $false
        }
       
        # Step 5: Bind each connection to the target lakehouse
        $bindingSuccessCount = 0
        $bindingErrorCount = 0
       
        foreach ($connection in $existingConnections) {
            Write-Host "##[debug]----------------------------------------" -ForegroundColor Gray
            Write-Host "##[debug]Processing Connection ID: $($connection.id)" -ForegroundColor Cyan
            Write-Host "##[debug]  Type: $($connection.connectionDetails.type)" -ForegroundColor Gray
            Write-Host "##[debug]  Original Path: $($connection.connectionDetails.path)" -ForegroundColor Gray
           
            # Only bind SQL connections (lakehouse connections)
            if ($connection.connectionDetails.type -ne "SQL") {
                Write-Host "##[debug]  Skipping non-SQL connection type: $($connection.connectionDetails.type)" -ForegroundColor Yellow
                continue
            }
           
            # Construct new connection path
            # Format: "server;databaseId"
            $newPath = "$($connectionDetails.connectionString);$($connectionDetails.databaseId)"
           
            Write-Host "##[debug]  New Path: $newPath" -ForegroundColor Green
           
            # Construct binding request body
            $bindingBody = @{
                connectionBinding = @{
                    id = $connection.id
                    connectivityType = "ShareableCloud"  # For lakehouse connections
                    connectionDetails = @{
                        type = "SQL"
                        path = $newPath
                    }
                }
            } | ConvertTo-Json -Depth 10
           
            Write-Host "##[debug]  Binding Request Body:" -ForegroundColor Gray
            Write-Host "##[debug]  $bindingBody" -ForegroundColor Gray
           
            # Call bind connection API
            $bindUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/semanticModels/$SemanticModelId/bindConnection"
            $headers = @{
                "Authorization" = "Bearer $Token"
                "Content-Type" = "application/json"
            }
           
            try {
                Write-Host "##[debug]  Sending bind request..." -ForegroundColor Cyan
                # display uri
                Write-Host "##[debug]  Bind URI: $bindUri" -ForegroundColor Gray
               
                $bindResponse = Invoke-RestMethod `
                    -Uri $bindUri `
                    -Headers $headers `
                    -Method POST `
                    -Body $bindingBody 
               
                Write-Host "##[debug]  Successfully bound connection ID: $($connection.id)" -ForegroundColor Green
                $bindingSuccessCount++
            }
            catch {
                Write-Host "##[error]  Failed to bind connection ID: $($connection.id)" -ForegroundColor Red
                Write-Host "##[error]  Error: $_" -ForegroundColor Red
               
                # Try to get error details
                if ($_.Exception.Response) {
                    try {
                        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                        $errorBody = $reader.ReadToEnd()
                        $reader.Close()
                        Write-Host "##[error]  Response Body: $errorBody" -ForegroundColor Red
                    }
                    catch {
                        Write-Host "##[error]  Could not read error response" -ForegroundColor Red
                    }
                }
               
                $bindingErrorCount++
            }
        }
       
        # Summary
        Write-Host "##[section]========================================" -ForegroundColor Cyan
        Write-Host "##[section]Connection Binding Summary:" -ForegroundColor Cyan
        Write-Host "##[section]  Successful: $bindingSuccessCount" -ForegroundColor Green
        Write-Host "##[section]  Failed: $bindingErrorCount" -ForegroundColor $(if ($bindingErrorCount -gt 0) { "Red" } else { "Gray" })
        Write-Host "##[section]========================================" -ForegroundColor Cyan
       
        return ($bindingSuccessCount -gt 0)
    }
    catch {
        Write-Error "Failed to bind connections for Semantic Model '$DisplayName': $_"
        return $false
    }
}

function Invoke-SemanticModelTakeOver {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$true)]
        [string]$SemanticModelId,
       
        [Parameter(Mandatory=$true)]
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Taking over ownership of Semantic Model: $SemanticModelId"
       
        # Construct API URL (Power BI API, not Fabric API)
        $apiUrl = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets/$SemanticModelId/Default.TakeOver"
       
        Write-Host "##[debug]API URL: $apiUrl"
       
        # Set up headers
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Execute take over (POST with empty body)
        $response = Invoke-FabricApiWithRetry `
            -Uri $apiUrl `
            -Headers $headers `
            -Method POST `
            -Body "{}" `
            -MaxRetries 5
       
        Write-Host "##[section] Successfully took over ownership of semantic model" -ForegroundColor Green
       
        return $response
       
    }
    catch {
        Write-Error "Failed to take over semantic model ownership: $_"
       
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
       
        throw
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$FabricToken = $env:FABRIC_TOKEN
$WorkspaceIds = ConvertFrom-Json -InputObject $env:WORKSPACE_IDS
$WorkspaceId = $WorkspaceIds.PSObject.Properties.Value
$WorkspaceName = $WorkspaceIds.PSObject.Properties.Name
$fabricConnections = ConvertFrom-Json -InputObject $env:FABRIC_CONNECTIONS
 Write-Host ("##[debug]Fabric Connections: " + (ConvertTo-Json -InputObject $fabricConnections))

$SemanticModelsDetail = $SemanticModelsDetailJson | ConvertFrom-Json

$SemanticModelsParametersDetail = $SemanticModelsParametersDetailJson | ConvertFrom-Json

$SourceCodePath = "../../../src/fabric"

$FabricItemType = "SemanticModel"
$global:auth_header = @{
    'Content-Type' = "application/json"
    'Authorization' = "Bearer {0}" -f $FabricToken
}

$WorkspaceItemsLookup = Get-WorkspaceItem -WorkspaceId $WorkspaceId -itemType $FabricItemType
$global:WorkspaceLakehouses = Get-WorkspaceLakehouse -WorkspaceId $WorkspaceId

$itemPlatformFiles = Read-PlatformFiles -BaseFolderPath $SourceCodePath -FabricItemType $FabricItemType -WorkspaceId $WorkspaceId

$DeploymentCreatedCount = 0
$DeploymentModifiedCount = 0
$DeploymentErrorCount = 0

Write-Output "===================================================================================================="
Write-Output "Start Deployment for Fabric Item Type | $($FabricItemType)"

$itemPlatformFiles | ForEach-Object {
    $ItemDefinitionPart = @()
    $_.definitionParts | ForEach-Object {
        $ItemDefinitionPart += @{
            "path" = ($_.Keys -join "")
            "payload" = ($_.Values -join "")
            "payloadType" = "InlineBase64"
        }
    }
    $displayName = $_.displayName
   
    $folderPath = $_.relativeFolderPath

    # display folder path and folder hierarchy for debugging
    Write-Host "##[debug] Folder Path: $folderPath"
    Write-Host "##[debug] Folder Hierarchy: $FolderHierarchy"

    $folderId = $null
    if (-not [string]::IsNullOrEmpty($folderPath)) {
        $folderId = Get-FolderIdByPath -FolderPath $folderPath -FolderHierarchy $FolderHierarchy
    }

    $ItemBody = @{
        "displayName" = $displayName
        "description" = $_.description
        "type" = $FabricItemType
        "definition" = @{ "parts" = @($ItemDefinitionPart) }
        "folderId" = $folderId
    } | ConvertTo-Json -Compress -Depth 100

    #  display ItemBody for debugging
    Write-Host "##[debug] ItemBody for $($displayName): $ItemBody"

    $itemLookup = $WorkspaceItemsLookup | Where-Object { $_.displayName -eq $displayName }
    $operation_url = $null
    $semanticModelId = $null
   
    Write-Output "`tDeploying: $($displayName)  (ID: $($itemLookup.id))"
    try {

        if ($null -eq $itemLookup.id) {
            # Create the item definition if item does not exist, based off of displayName for an Item.
            $itemUrl = "https://api.fabric.Microsoft.com/v1/workspaces/$($WorkspaceId)/items"

            $webResponse = Invoke-WebRequest -Uri $itemUrl -Headers $global:auth_header -Body $ItemBody -Method POST -UseBasicParsing

            $crud_response = $webResponse.Content | ConvertFrom-Json
            $locationHeader = $webResponse.Headers["Location"]
       
            Write-Output "`t`tItem Created Successfully"
            $DeploymentCreatedCount++

            Start-Sleep -Seconds 20
            
            $WorkspaceItemsLookup = Get-WorkspaceItem -WorkspaceId $WorkspaceId -itemType $FabricItemType
            $itemLookup = $WorkspaceItemsLookup | Where-Object { $_.displayName -eq $displayName }
            $semanticModelId = $itemLookup.id
           
           
        } else {

            Invoke-SemanticModelTakeOver `
                -WorkspaceId $workspaceId `
                -SemanticModelId $itemLookup.id `
                -Token $FabricToken

            # Update the item definition
            $itemUrl = "https://api.fabric.microsoft.com/v1/workspaces/{0}/items/{1}/updateDefinition" -f $WorkspaceId, $itemLookup.id

            $webResponse = Invoke-WebRequest -Uri $itemUrl -Headers $global:auth_header -Body $ItemBody -Method POST -UseBasicParsing
            $crud_response = $webResponse.Content | ConvertFrom-Json
            $locationHeader = $webResponse.Headers["Location"]

            if (-not [string]::IsNullOrEmpty($folderId)) {
                # Get current folder of the semantic model
                $currentFolderId = Get-SemanticModelCurrentFolder -WorkspaceId $WorkspaceId -SemanticModelId $itemLookup.id -Token $FabricToken

                # Check if the semantic model needs to be moved
                $needsMove = $false
                if ([string]::IsNullOrEmpty($currentFolderId) -and -not [string]::IsNullOrEmpty($folderId)) {
                    # Semantic model is in root, but should be in a folder
                    $needsMove = $true
                    Write-Host "##[debug]Semantic model is currently in workspace root, needs to move to folder: $folderId"
                } elseif (-not [string]::IsNullOrEmpty($currentFolderId) -and $currentFolderId -ne $folderId) {
                    # Semantic model is in different folder
                    $needsMove = $true
                    Write-Host "##[debug]Semantic model is currently in folder: $currentFolderId, needs to move to folder: $folderId"
                } else {
                    Write-Host "##[debug]Semantic model is already in the correct folder: $folderId"
                }
               
                if ($needsMove) {
                    Write-Host "##[debug]Moving semantic model to target folder: $folderId"
                    Move-SemanticModelToFolder -WorkspaceId $WorkspaceId -SemanticModelId $itemLookup.id -TargetFolderId $folderId -Token $FabricToken
                    Write-Host "##[debug]Successfully moved semantic model to folder: $folderId"
                }
            }

            Write-Output "`t`tItem Updated Successfully"
            $DeploymentModifiedCount++
           
            # Store the existing item ID for connection binding
            $semanticModelId = $itemLookup.id
        }

        # ========================================================================
        # Bind semantic model connections after creation or update
        # ========================================================================
       
        # Wait for the operation to stabilize before binding
        Start-Sleep -Seconds 5
       
        Write-Host "`t----------------------------------------" -ForegroundColor Cyan
        Write-Host "`tBinding semantic model connections..." -ForegroundColor Cyan
       
        if (-not [string]::IsNullOrEmpty($semanticModelId)) {
            $bindingResult = Bind-SemanticModelConnection `
                -WorkspaceId $WorkspaceId `
                -SemanticModelId $semanticModelId `
                -DisplayName $displayName `
                -Token $FabricToken
           
            if ($bindingResult) {
                Write-Host "`t Connection binding completed successfully" -ForegroundColor Green
            } else {
                Write-Host "`t Connection binding completed with warnings or was skipped" -ForegroundColor Yellow
            }
        } else {
            Write-Host "`t Could not determine semantic model ID for connection binding" -ForegroundColor Yellow
        }
       
        Write-Host "`t----------------------------------------" -ForegroundColor Cyan


    }
    catch {
        Write-Host "`t`tError during Fabric Item CRUD request: $_" -ForegroundColor Red
   
        # Enhanced error reporting
        if ($_.Exception.Response) {
            Write-Host "`t`tHTTP Status: $($_.Exception.Response.StatusCode)" -ForegroundColor Red
            Write-Host "`t`tStatus Description: $($_.Exception.Response.StatusDescription)" -ForegroundColor Red
        }
   
        # Try to get response content for more details
        if ($_.Exception.Response.GetResponseStream) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Host "`t`tResponse Body: $responseBody" -ForegroundColor Red
        }
   
        $DeploymentErrorCount++
    }

}

Write-Output "Deployment Completed for Fabric Item Type | $($FabricItemType) - Created: $($DeploymentCreatedCount), Modified: $($DeploymentModifiedCount), Errors: $($DeploymentErrorCount)"
Write-Output "===================================================================================================="
