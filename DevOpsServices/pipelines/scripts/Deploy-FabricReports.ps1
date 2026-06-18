param(
    [Parameter(Mandatory=$false)]
    [string]$FolderHierarchy
)

function Get-ContentPayload {
    param (
        [string]$filePath
    )
   
    $fileContent = Get-Content -Path $filePath -Raw -Encoding UTF8
    $fileBytes = [System.Text.Encoding]::UTF8.GetBytes($fileContent)
    $contentPayload = [Convert]::ToBase64String($fileBytes)
   
    return $contentPayload
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
        Write-Host "##[debug]##[debug]Looking up folder ID for path: $FolderPath"

        # Find the folder with matching path
        $matchingFolder = $folders | Where-Object { $_.Path -eq $FolderPath }
       
        if ($null -eq $matchingFolder) {
            Write-Warning " : $FolderPath"
            return $null
        }

        Write-Host "##[debug]##[debug]Found folder ID: $($matchingFolder.Id) for path: $FolderPath"
        return $matchingFolder.Id
    }
    catch {
        Write-Error "Failed to get folder ID: $_"
        return $null
    }
}

function Read-PlatformFiles {
    param (
        [string]$BaseFolderPath,
        [string]$WorkspaceId,
        [string]$WorkspaceName,
        [string]$FabricItemType = "Report"
    )

    $results = @()
   
    Write-Host "##[debug] Searching for $FabricItemType items in: $BaseFolderPath"

    # sleep 20 seconds to ensure semantic models are loaded
    Start-Sleep -Seconds 20
   
    $folders = Get-ChildItem -Path $BaseFolderPath -Directory -Recurse -Filter "*.$($FabricItemType)"
    $FabricSemanticModels = Get-WorkspaceItem -WorkspaceId $WorkspaceId -itemType "SemanticModel"
   
    # display folders
    Write-Host "##[debug] Folders found:"
    $folders | ForEach-Object { Write-Host "##[debug]   - $($_.FullName)" } 


    Write-Host "##[debug] Found $($folders.Count) $FabricItemType folders"
    Write-Host "##[debug] Found $($FabricSemanticModels.Count) semantic models in workspace"

    foreach ($folder in $folders) {
        Write-Host "##[debug] Processing folder: $($folder.FullName)"
       
        $platformFilePath = Join-Path -Path $folder.FullName -ChildPath ".platform"
       
        # Get ALL files recursively, including static resources
        $itemSourceFiles = Get-ChildItem -Path $folder.FullName -File -Recurse
        $definitionPBISMFilePath = Join-Path -Path $folder.FullName -ChildPath "definition.pbir"

        if (Test-Path -Path $platformFilePath) {
            Write-Host "##[debug] Found .platform file"
           
            $platformContent = Get-Content -Path $platformFilePath -Raw | ConvertFrom-Json            

            $result = [pscustomobject]@{
                logicalId   = $platformContent.config.logicalId
                type        = $platformContent.metadata.type
                displayName = $platformContent.metadata.displayName
                description = $platformContent.metadata.description
                folderPath  = $folder.FullName
                relativeFolderPath = $folder.FullName.Replace($BaseFolderPath, "").TrimStart('\', '/')
                definitionParts = @()
            }  
           
            Write-Host "##[debug] Report details:"
            Write-Host "##[debug]   Display Name: $($result.displayName)"
            Write-Host "##[debug]   Relative Path: $($result.relativeFolderPath)"

            # verify if itemSourceFiles contains a 'definition' folder and exclude 'definition.pbir'
            $pbir_v2 = $false
            $definitionFolder = $itemSourceFiles | Where-Object { $_.FullName -like "*definition*" -and $_.Name -ne "definition.pbir" }
            if ($definitionFolder) {
                $pbir_v2 = $true
                Write-Host "##[debug] Found 'definition' folder in itemSourceFiles"
            }

            if ($pbir_v2) {
                # Write-Host "##[debug] Adding .platform file as definition part"
                $platformPayload = Get-ContentPayload -filePath $platformFilePath
                $result.definitionParts += @{ ".platform" = $platformPayload }
            }

            # display itemSourceFiles for debugging
            Write-Host "##[debug] Files found in $($folder.FullName):"
            $itemSourceFiles | ForEach-Object { Write-Host "##[debug]   - $($_.FullName)" }

            # Process ALL files including static resources
            $itemSourceFiles | ForEach-Object {
                if ($_.Name -ne ".platform") {
                    # Calculate relative path from report folder root
                    $itemPath = $_.FullName.Substring($folder.FullName.Length + 1) -replace '\\', '/'
                    Write-Host "##[debug] Processing file: $itemPath"

                    # Handle different file types
                    if ($_.Name -eq "definition.pbir") {

                        Write-Host "##[debug] Processing definition.pbir file"
                       
                        # Your existing pbir processing code...
                        try {
                            $pbirContent = Get-Content -Path $definitionPBISMFilePath -Raw | ConvertFrom-Json
                            $originalPath = $pbirContent.datasetReference.byPath.path
                           
                            Write-Host "##[debug] Original semantic model path: $originalPath"                                                       

                            Write-Host "##[debug] Report full path: '$($folder.FullName)'"

                            # Resolve the relative path from the report's current location
                            if ($originalPath -match '^\.\.\/') {
                                # Path starts with ../ - need to resolve relative to current location
                               
                                # Convert to Windows path separators for Join-Path
                                $relativePath = $originalPath -replace '/', '\'
                               
                                # Start from the report's folder location
                                $reportFolderFullPath = $folder.FullName
                               
                                # Resolve the relative path
                                $resolvedPath = Resolve-Path -Path (Join-Path $reportFolderFullPath $relativePath) -ErrorAction SilentlyContinue
                               
                                if ($resolvedPath) {
                                    $smPath = $resolvedPath.Path
                                    Write-Host "##[debug] Resolved semantic model path: $smPath"
                                } else {

                                    Write-Host "##[debug] Missing resolved path: $($resolvedPath.Path)"
                                    continue
                                }
                            } else {
                                # Absolute path or path without ../
                                $cleanPath = $originalPath -replace '^\.\./+', ""
                                $smPath = Join-Path -Path $BaseFolderPath -ChildPath $cleanPath
                                Write-Host "##[debug] Using base path resolution: $smPath"
                            }
                           
                            # Verify the semantic model path exists
                            if (-not (Test-Path -Path $smPath)) {
                                Write-Host "##[warning] Semantic model path does not exist: $smPath"                               
                                continue
                            }
                                                     
                            $platformFilePath = Join-Path $smPath ".platform"
                            $pbirJson = $null
                            if (Test-Path -Path $platformFilePath) {
                                Write-Host "##[debug] Reading semantic model $platformFilePath"
                               
                                $referenceSemanticModel = Get-Content -Path $platformFilePath -Raw | ConvertFrom-Json
                                $semanticModelName = $referenceSemanticModel.metadata.displayName
                               
                                Write-Host "##[debug] Referenced semantic model: $semanticModelName"
                                Write-Host "##[debug] Target workspace: $WorkspaceName"
                                # Find the semantic model in the workspace
                                # refactor below to break if semantic model found using another loop method
                                $semanticModelId = $null
                                foreach ($model in $FabricSemanticModels) {
                                    Write-Host "##[debug] Checking semantic model: $($model.displayName) (Workspace ID: $($model.workspaceId))"
                                    if ($model.displayName -eq $semanticModelName -and $model.workspaceId -eq $WorkspaceId) {
                                        $semanticModelId = $model.id
                                        break
                                    }
                                }

                                if ($semanticModelId) {
                                    Write-Host "##[debug] Found semantic model ID: $semanticModelId"
                                    Write-Host "##[debug] pbir version v2: $pbir_v2"
                                    if ($pbir_v2 -eq $false) {                                    
                                        # Update the pbir content with workspace connection
                                        # replace $schema version 2.0.0 with 1.0.0
                                        $pbirContent.'$schema' = $pbirContent.'$schema' -replace '/2\.0\.0/', '/1.0.0/'

                                        $pbirContent.datasetReference.byPath = $null
                                        $pbirContent.datasetReference | Add-Member -MemberType NoteProperty -Name byConnection -Value @{}
                                        $pbirContent.datasetReference.byConnection = @{
                                            "connectionString" = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$WorkspaceName;Initial Catalog=$semanticModelName;"
                                            "pbiServiceModelId" = $null
                                            "pbiModelVirtualServerName" = "sobe_wowvirtualserver"
                                            "pbiModelDatabaseName" = $semanticModelId
                                            "name" = "EntityDataSource"
                                            "connectionType" = "pbiServiceXmlaStyleLive" # Per Microsoft Documentation, this property will be removed in the future. https://github.com/microsoft/powerbi-desktop-samples/blob/main/item-schemas/report/definition.pbir.md#connectiontype
                                        }
                                        $pbirJson = $pbirContent | ConvertTo-Json -Depth 10
                                        Write-Host "##[debug] pbir content for v1 with connection object"
                                        Write-Host "##[debug] $pbirJson"
                                    } else {
                                        $cleanPbirContent = @{
                                            '$schema' = $pbirContent.'$schema'
                                            "version" = "4.0"
                                            "datasetReference" = @{
                                                "byConnection" = @{
                                                    "connectionString" = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$WorkspaceName;Initial Catalog=$semanticModelName;semanticmodelid=$semanticModelId"
                                                }
                                            }
                                        }
                                        $pbirJson = $cleanPbirContent | ConvertTo-Json -Depth 10
                                        Write-Host "##[debug] pbir content for v2 with connection string"
                                        Write-Host "##[debug] $pbirJson"
                                    }
                                } else {
                                    Write-Host "##[error] Semantic model '$semanticModelName' not found in workspace '$WorkspaceName'"
                                    Write-Host "##[debug] Available semantic models in workspace:"
                                    $FabricSemanticModels | ForEach-Object {
                                        Write-Host "##[debug]   - $($_.displayName) (ID: $($_.id))"
                                    }
                                    continue
                                }
                            } else {
                                Write-Host "##[error] .platform file not found at: $platformFilePath"
                                continue
                            }
                           
                            # Convert updated pbir content to Base64
                            $pbirFileBytes = [System.Text.Encoding]::UTF8.GetBytes($pbirJson)
                            $pbirPayload = [Convert]::ToBase64String($pbirFileBytes)
                           
                            $result.definitionParts += @{ $itemPath = $pbirPayload }
                           
                        } catch {
                            Write-Host "##[error] Error processing definition.pbir: $($_.Exception.Message)" -ForegroundColor Red
                            Write-Host "##[error]Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
                           
                            # Fallback: Use original content
                            $contentPayload = Get-ContentPayload -filePath $_.FullName
                            $result.definitionParts += @{ $itemPath = $contentPayload }
                        }
                    }
                    elseif ($itemPath -like "staticResources/RegisteredResources/*") {
                        # Handle static resources (logos, themes, etc.)
                        Write-Host "##[debug] Processing static resource: $itemPath"
                       
                        # For binary files (images), read as binary and convert to base64
                        if ($_.Extension -in @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico')) {
                            Write-Host "##[debug] Processing image file: $($_.Name)"
                            $fileBytes = [System.IO.File]::ReadAllBytes($_.FullName)
                            $contentPayload = [Convert]::ToBase64String($fileBytes)
                        } else {
                            # For text files (JSON, etc.), read as text and convert to base64
                            Write-Host "##[debug] Processing text file: $($_.Name)"
                            $contentPayload = Get-ContentPayload -filePath $_.FullName
                        }
                       
                        $result.definitionParts += @{ $itemPath = $contentPayload }
                    }
                    else {
                        # Regular file processing (reports, etc.)
                        Write-Host "##[debug] Processing regular file: $itemPath"
                        $contentPayload = Get-ContentPayload -filePath $_.FullName
                        $result.definitionParts += @{ $itemPath = $contentPayload }
                    }
                }
            }
           
            # Debug: List all definition parts that will be included
            Write-Host "##[debug] Definition parts for $($result.displayName):"
            $result.definitionParts | ForEach-Object {
                $partPath = $_.Keys -join ""
                Write-Host "##[debug]   - $partPath"
            }
           
            $results += $result
            Write-Host "##[debug] Successfully processed report: $($result.displayName)"
        } else {
            Write-Host "##[debug] No .platform file found in: $($folder.FullName)"
        }
    }
   
    Write-Host "##[debug] Total reports processed: $($results.Count)"
    return $results
}

# Rest of your existing functions remain the same...
function Get-WorkspaceItem {
    param(
        [string]$workspaceId,
        [string]$itemType
    )
   
    $itemUrl = "https://api.fabric.microsoft.com/v1/workspaces/{0}/items?type={1}" -f $workspaceId, $itemType
   
    try {
        $response = Invoke-FabricApiWithRetry -Uri $itemUrl -Headers $global:auth_header -Method GET -MaxRetries 5

        Write-Host "##[debug] Found $($response.value.Count) $itemType items in workspace"
        # display response value content for debugging
        Write-Host "##[debug] Response content: $($response | ConvertTo-Json -Depth 5)"
        return $response.value
    }
    catch {
        Write-Output "##[error]  Error getting workspace items for type $($itemType): $($_.Exception.Message)"
        return @()
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

function Move-ReportToFolder {
    param(
        [string]$WorkspaceId,
        [string]$ReportId,
        [string]$TargetFolderId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Moving report with ID: $ReportId to folder: $TargetFolderId"

        # Construct API URL for moving item
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$ReportId/move"
        Write-Host "##[debug] Move API URL: $apiUrl"

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
        Write-Host "##[debug] Move request body: $jsonBody"

        # Send request to move report
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5

        Write-Host "##[debug]Successfully moved report with ID: $ReportId to folder: $TargetFolderId"
        Write-Host "##[debug] Move response: $($response | ConvertTo-Json -Depth 5)"

        return $response
    }
    catch {
        Write-Error "Failed to move report with ID '$ReportId' to folder '$TargetFolderId': $_"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

function Get-Report {
    param(
        [string]$WorkspaceId,
        [string]$ReportId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting report with ID: $ReportId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/reports/$ReportId"

        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }

        # Send request to get report
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        Write-Host "##[debug]Successfully retrieved report: $($response.displayName)"
        return $response
    }
    catch {
        Write-Error "Failed to get report with ID '$ReportId': $_"
        exit 1
    }
}

function Get-ReportCurrentFolder {
    param(
        [string]$WorkspaceId,
        [string]$ReportId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting current folder for report with ID: $ReportId"

        # Get report details which should include folder information
        $report = Get-Report -WorkspaceId $WorkspaceId -ReportId $ReportId -Token $Token

        # The folderId property indicates the current folder
        $currentFolderId = $report.folderId

        if ([string]::IsNullOrEmpty($currentFolderId)) {
            Write-Host "##[debug]Report is currently in the workspace root (no folder)"
            return $null
        }

        Write-Host "##[debug]Report is currently in folder: $currentFolderId"
        return $currentFolderId
    }
    catch {
        Write-Error "Failed to get current folder for report with ID '$ReportId': $_"
        exit 1
    }
}

# Example usage with debugging
Write-Host "##[section] STARTING FABRIC REPORT DEPLOYMENT WITH FOLDER SUPPORT"

# Your existing setup code...
$FabricToken = $env:FABRIC_TOKEN
$WorkspaceIds = ConvertFrom-Json -InputObject $env:WORKSPACE_IDS
$WorkspaceId = $WorkspaceIds.PSObject.Properties.Value
$WorkspaceName = $WorkspaceIds.PSObject.Properties.Name
$SourceCodePath = "../../../src/fabric"
$FabricItemType = "Report"

$global:auth_header = @{
    'Content-Type' = "application/json"
    'Authorization' = "Bearer {0}" -f $FabricToken
}

$WorkspaceItemsLookup = Get-WorkspaceItem -WorkspaceId $WorkspaceId -itemType $FabricItemType
$itemPlatformFiles = Read-PlatformFiles -BaseFolderPath $SourceCodePath -WorkspaceId $WorkspaceId -WorkspaceName $WorkspaceName -FabricItemType $FabricItemType

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
    
    # display ItemDefinitionPart for debugging
    Write-Host "##[debug] ItemDefinitionPart for $($_.displayName): $($ItemDefinitionPart | ConvertTo-Json -Compress -Depth 10)"    

    $folderPath = $_.relativeFolderPath
    $folderId = $null
    if (-not [string]::IsNullOrEmpty($folderPath)) {
        $folderId = Get-FolderIdByPath -FolderPath $folderPath -FolderHierarchy $FolderHierarchy
    }

    $displayName = $_.displayName
    $ItemBody = @{
        "displayName" =  $_.displayName
        "description" = $_.displayName
        "type" = $FabricItemType
        "definition" = @{ "parts" = @($ItemDefinitionPart) }
        "folderId" = $folderId
    } | ConvertTo-Json -Compress -Depth 100
    
    #  display ItemBody for debugging
    Write-Host "##[debug] ItemBody for $($displayName): $ItemBody"
    
    $itemLookup = $WorkspaceItemsLookup | Where-Object { $_.displayName -eq $displayName }
    
    $operation_url = $null
    
    Write-Output "`tDeploying: $($displayName)  (ID: $($itemLookup.id))"
    
    try {
        if ($null -eq $itemLookup.id) {
            # Create the item definition if item does not exist, based off of displayName for an Item.
            $itemUrl = "https://api.fabric.Microsoft.com/v1/workspaces/$($WorkspaceId)/reports"
        
            $crud_response = Invoke-WebRequest -Uri $itemUrl -Headers $global:auth_header -Body $ItemBody -Method POST -UseBasicParsing
            Write-Output "`t`tStatus Code: $($crud_response.StatusCode)"
            Write-Output "`t`tStatus Description: $($crud_response.StatusDescription)"            
            $operation_url = [System.Uri]::new($crud_response.Headers["Location"])
   
            Write-Output "`t`tItem Created Successfully"
            $DeploymentCreatedCount++
        } else {
            # Update the item definition
            $itemUrl = "https://api.fabric.microsoft.com/v1/workspaces/{0}/reports/{1}/updateDefinition" -f $WorkspaceId, $itemLookup.id
            Write-Host "##[debug] Updating existing item with ID: $($itemLookup.id)"
        
            $crud_response = Invoke-WebRequest -Uri $itemUrl -Headers $global:auth_header -Body $ItemBody -Method POST -UseBasicParsing
            Write-Output "`t`tStatus Code: $($crud_response.StatusCode)"
            Write-Output "`t`tStatus Description: $($crud_response.StatusDescription)"            
            $operation_url = [System.Uri]::new($crud_response.Headers["Location"])

            if (-not [string]::IsNullOrEmpty($folderId)) {
                # Get current folder of the report
                $currentFolderId = Get-ReportCurrentFolder -WorkspaceId $WorkspaceId -ReportId $itemLookup.id -Token $FabricToken

                # Check if the report needs to be moved
                $needsMove = $false
                if ([string]::IsNullOrEmpty($currentFolderId) -and -not [string]::IsNullOrEmpty($folderId)) {
                    # Report is in root, but should be in a folder
                    $needsMove = $true
                    Write-Host "##[debug]Report is currently in workspace root, needs to move to folder: $folderId"
                } elseif (-not [string]::IsNullOrEmpty($currentFolderId) -and $currentFolderId -ne $folderId) {
                    # Report is in different folder
                    $needsMove = $true
                    Write-Host "##[debug]Report is currently in folder: $currentFolderId, needs to move to folder: $folderId"
                } else {
                    Write-Host "##[debug]Report is already in the correct folder: $folderId"
                }
                
                if ($needsMove) {
                    Write-Host "##[debug]Moving report to target folder: $folderId"
                    Move-ReportToFolder -WorkspaceId $WorkspaceId -ReportId $itemLookup.id -TargetFolderId $folderId -Token $FabricToken
                    Move-ReportToFolder -WorkspaceId $WorkspaceId -ReportId $itemLookup.id -TargetFolderId $folderId -Token $FabricToken
                    Write-Host "##[debug]Successfully moved report to folder: $folderId"
                }
            }

            Write-Output "`t`tItem Updated Successfully"
            $DeploymentModifiedCount++
        }
    
        # Extract Location header for operation URL
         $operation_url = [System.Uri]::new($crud_response.Headers["Location"])

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

    while ($true) {

        if ($crud_response.StatusCode -eq 200) {
            Write-Host "`t`tSuccessful Deployment: Status Code: $($crud_response.StatusCode)" -ForegroundColor Green
        }
        if ($crud_response.StatusCode -ne 202) {
            break
        }

        if ($null -eq $operation_url ) {
            Write-Host "`t`tWarning: Operation URL is null skipping polling status check..." -ForegroundColor Yellow
            break
        }

        Start-Sleep -Seconds 1  # Wait for the specified retry interval
        
        try {
            $crud_response = Invoke-WebRequest -Uri $operation_url -Headers $global:auth_header -Method GET -UseBasicParsing
            
        } catch {
            Write-Host "`t`tError during status 202 status polling request: $_" -ForegroundColor Red
            break
        }
        if (($crud_response.Content | ConvertFrom-Json).status -eq 'Failed') {
            Write-Host ($crud_response.Content | ConvertFrom-Json).error -ForegroundColor Red
            break
        }
    }

}
Write-Output "Deployment Completed for Fabric Item Type | $($FabricItemType) - Created: $($DeploymentCreatedCount), Modified: $($DeploymentModifiedCount), Errors: $($DeploymentErrorCount)"
Write-Output "===================================================================================================="

