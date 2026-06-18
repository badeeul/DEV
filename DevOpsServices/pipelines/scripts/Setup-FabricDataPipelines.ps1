param(
    [Parameter(Mandatory=$false)]
    [string]$FolderHierarchy
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

# Function to get notebook mappings from .platform files
function Get-NotebookMappings {
    Write-Host "##[debug]Searching for notebook platform files..."
   
    $result = @()
    $notebooks = Get-ChildItem -Path "../../../src/fabric" -Filter "*.Notebook" -Recurse |
        ForEach-Object {
            $platformPath = Join-Path -Path $_.FullName -ChildPath ".platform"
            if (Test-Path -Path $platformPath) {
                $content = Get-Content -Path $platformPath | ConvertFrom-Json
                $result += @{
                    searchId = $content.config.logicalId
                    displayName = $content.metadata.displayName
                }
            }
        }
   
    Write-Host ("##[debug]Found " + ($result | Measure-Object).Count + " notebook platform files")
    return $result
}

# Function to search and read platform files
function Get-PlatformFiles {
    Write-Host "##[debug]Searching for platform files..."
   
    $platformFiles = Get-ChildItem -Path "../../../src/fabric" -Filter "*.DataPipeline" -Recurse |
        ForEach-Object {
            $platformPath = Join-Path -Path $_.FullName -ChildPath ".platform"
            if (Test-Path -Path $platformPath) {
                # handle utf=8
                $content = Get-Content -Path $platformPath | ConvertFrom-Json
                @{
                    displayName = $content.metadata.displayName
                    description = $content.metadata.description
                    logicalId = $content.config.logicalId
                    folderPath = $_.FullName
                }
            }
        }
   
    Write-Host ("##[debug]Found " + ($platformFiles | Measure-Object).Count + " platform files")
    Write-Host ("##[debug]Platform files: " + (ConvertTo-Json -InputObject $platformFiles -Depth 10))

    return $platformFiles
}

# Function to get existing data pipelines
function Get-ExistingDataPipelines {
    param (
        [string]$token,
        [string]$workspaceId
    )
   
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
   
    try {
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/dataPipelines"
        Write-Host ("##[debug]Getting existing data pipelines from: " + $uri)
        
        $response = Invoke-FabricApiWithRetry -Uri $uri -Headers $headers -Method GET -MaxRetries 5
        return $response.value
    }
    catch {
        Write-Error ("Failed to get existing data pipelines: " + $_)
        throw
    }
}


function Update-FabricDataPipelines {
    param (
        [string]$token,
        [string]$workspaceId,
        [string]$pipelineId,
        [object]$platformFile
    )
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    $description = $platformFile.description
    # truncate description up to 256 characters
    if ($description.Length -gt 256) {
        $description = $description.Substring(0, 256)
    }    
   
    $body = @{
        displayName = $platformFile.displayName
        description = $description
    }
   
    # Convert to JSON with proper encoding
    $bodyJson = ConvertTo-Json -InputObject $body -Depth 100
   
    $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/dataPipelines/$pipelineId"
   
    Write-Host ("##[debug]Update pipeline: " + $platformFile.displayName)
    Write-Host ("##[debug]Body: " + $bodyJson)
    Write-Host ("##[debug]URI: " + $uri)
   
    try {
  
        $response = Invoke-FabricApiWithRetry -Uri $uri -Headers $headers -Method PATCH -Body $bodyJson -MaxRetries 5
        return $response
    }
    catch {
        Write-Error ("Failed to update pipeline " + $platformFile.displayName + ": " + $_)
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

function Move-DataPipelineToFolder {
    param(
        [string]$WorkspaceId,
        [string]$DataPipelineId,
        [string]$TargetFolderId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Moving data pipeline with ID: $DataPipelineId to folder: $TargetFolderId"
       
        # Construct API URL for moving item
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$DataPipelineId/move"
       
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
       
        # Send request to move data pipeline
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5

        Write-Host "##[debug]Successfully moved data pipeline with ID: $DataPipelineId to folder: $TargetFolderId"

        return $response
    }
    catch {
        Write-Error "Failed to move data pipeline with ID '$DataPipelineId' to folder '$TargetFolderId': $_"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

function Get-DataPipeline    {
    param(
        [string]$WorkspaceId,
        [string]$DataPipelineId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting data pipeline with ID: $DataPipelineId from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/dataPipelines/$DataPipelineId"

        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get data pipeline
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5
       
        Write-Host "##[debug]Successfully retrieved data pipeline: $($response.displayName)"
        return $response
    }
    catch {
        Write-Error "Failed to get data pipeline with ID '$DataPipelineId': $_"
        exit 1
    }
}

function Get-DataPipelineCurrentFolder {
    param(
        [string]$WorkspaceId,
        [string]$DataPipelineId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Getting current folder for data pipeline with ID: $DataPipelineId"

        # Get data pipeline details which should include folder information
        $dataPipeline = Get-DataPipeline -WorkspaceId $WorkspaceId -DataPipelineId $DataPipelineId -Token $Token

        # The folderId property indicates the current folder
        $currentFolderId = $dataPipeline.folderId

        if ([string]::IsNullOrEmpty($currentFolderId)) {
            Write-Host "##[debug]Data pipeline is currently in the workspace root (no folder)"
            return $null
        }

        Write-Host "##[debug]Data pipeline is currently in folder: $currentFolderId"
        return $currentFolderId
    }
    catch {
        Write-Error "Failed to get current folder for data pipeline with ID '$DataPipelineId': $_"
        exit 1
    }
}

# Function to create data pipelines
function New-FabricDataPipelines {
    param (
        [string]$token,
        [string]$workspaceId,
        [array]$platformFiles
    )
   
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
   
    # Get existing pipelines
    $existingPipelines = Get-ExistingDataPipelines -token $token -workspaceId $workspaceId

    $recordedPipelines = @()
    foreach ($pf in $platformFiles) {

        $description = $pf.description
        # truncate description up to 256 characters
        if ($description.Length -gt 256) {
            $description = $description.Substring(0, 256)
        }   

        $folderPath = $pf.folderPath
        $folderId = $null
        if (-not [string]::IsNullOrEmpty($folderPath)) {
            $folderId = Get-FolderIdByPath -FolderPath $folderPath -FolderHierarchy $FolderHierarchy
        }

        # Check if pipeline already exists
        $existingPipeline = $existingPipelines | Where-Object { $_.displayName -eq $pf.displayName }
       
        if ($existingPipeline) {
            Write-Host ("##[debug]Pipeline already exists: " + $pf.displayName)
            # Add existing pipeline to our tracking list
            $recordedPipelines += @{
                id = $existingPipeline.id
                displayName = $pf.displayName
                description = $description
                workspaceId = $existingPipeline.workspaceId
                logicalId = $pf.logicalId
                folderPath = $pf.folderPath
            }

            Write-Host "##[debug]Updating existing data pipeline: $($pf.displayName)"
            Write-Host "##[debug]recordedPipelines: " + (ConvertTo-Json -InputObject $recordedPipelines -Depth 10)

            Update-FabricDataPipelines -token $token -workspaceId $workspaceId -pipelineId $existingPipeline.id -platformFile $pf

            if (-not [string]::IsNullOrEmpty($folderId)) {
                # Get current folder of the data pipeline
                $currentFolderId = Get-DataPipelineCurrentFolder -WorkspaceId $WorkspaceId -DataPipelineId $existingPipeline.id -Token $token

                # Check if the data pipeline needs to be moved
                $needsMove = $false
                if ([string]::IsNullOrEmpty($currentFolderId) -and -not [string]::IsNullOrEmpty($folderId)) {
                    # Data pipeline is in root, but should be in a folder
                    $needsMove = $true
                    Write-Host "##[debug]Data pipeline is currently in workspace root, needs to move to folder: $folderId"
                } elseif (-not [string]::IsNullOrEmpty($currentFolderId) -and $currentFolderId -ne $folderId) {
                    # Data pipeline is in different folder
                    $needsMove = $true
                    Write-Host "##[debug]Data pipeline is currently in folder: $currentFolderId, needs to move to folder: $folderId"
                } else {
                    Write-Host "##[debug]Data pipeline is already in the correct folder: $folderId"
                }
                
                if ($needsMove) {
                    Write-Host "##[debug]Moving data pipeline to target folder: $folderId"
                    Move-DataPipelineToFolder -WorkspaceId $WorkspaceId -DataPipelineId $existingPipeline.id -TargetFolderId $folderId -Token $token
                    Write-Host "##[debug]Successfully moved data pipeline to folder: $folderId"
                }
            }
            continue
        }
       
        $body = @{
            displayName = $pf.displayName
            description = $description
        }

        if (-not [string]::IsNullOrEmpty($folderId)) {
            $body.folderId = $folderId
            Write-Host "##[debug]Creating data pipeline in folder: $folderId"
        }

        # Convert to JSON with proper encoding
        $bodyJson = ConvertTo-Json -InputObject $body -Depth 100
       
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/dataPipelines"
       
        Write-Host ("##[debug]Creating pipeline: " + $pf.displayName)
        Write-Host ("##[debug]Body: " + $bodyJson)
        Write-Host ("##[debug]URI: " + $uri)
       
        try {

            $response = Invoke-FabricApiWithRetry -Uri $uri -Headers $headers -Method POST -Body $bodyJson -MaxRetries 5    

            $recordedPipelines += @{
                id = $response.id
                displayName = $response.displayName
                description = $response.description
                workspaceId = $response.workspaceId
                logicalId = $pf.logicalId
                folderPath = $pf.folderPath
            }
            Write-Host ("##[debug]Created pipeline: " + $response.displayName + " with ID: " + $response.id)
            Write-Host "##[debug]recordedPipelines: " + (ConvertTo-Json -InputObject $recordedPipelines -Depth 10)
        }
        catch {
            Write-Error ("Failed to create pipeline " + $pf.displayName + ": " + $_)
        }
    }

    return $recordedPipelines
}

# Function to get lakehouses
function Get-Lakehouses {
    param (
        [string]$token,
        [string]$workspaceId
    )
   
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
   
    try {
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/lakehouses"
        Write-Host ("##[debug]Getting lakehouses from: " + $uri)
           
        $response = Invoke-FabricApiWithRetry -Uri $uri -Headers $headers -Method GET -MaxRetries 5

        return $response.value
    }
    catch {
        Write-Error ("Failed to get lakehouses: " + $_)
        throw
    }
}

# Function to update pipeline content
function Update-PipelineContent {
    param (
        [string]$pipelinePath,
        [object]$lakehouses,
        [string]$workspaceId,
        [array]$pipelineReplacements,
        [array]$fabricConnections,
        [array]$notebookIds,
        [array]$fabricManagedConnections

    )

    Write-Host ("##[debug]Updating pipeline content: " + $pipelinePath)
    $content = Get-Content -Path $pipelinePath | ConvertFrom-Json
   
    function Get-LakehouseNameFromParameter {
        param([string]$parameterName)
       
        # Pattern: lh_{lakehousename}_id
        # Extract the part between 'lh_' and '_id'
        if ($parameterName -match '^lh_(.+?)_id$') {
            $lakehouseName = $Matches[1]
            Write-Host "##[debug]  Extracted lakehouse name: '$lakehouseName' from parameter: '$parameterName'"
            return $lakehouseName
        }
       
        return $null
    }

    if ($content.properties -and $content.properties.parameters) {
        Write-Host "##[debug]Checking parameters..."
       
        if ($content.properties.parameters.lh_metadata_id) {
            Write-Host "##[debug]Updating lh_metadata_id"
            $metadataLakehouse = $lakehouses | Where-Object { $_.displayName -like "*metadata*" }
            if ($metadataLakehouse) {
                if ($content.properties.parameters.lh_metadata_id.defaultValue) {
                    $content.properties.parameters.lh_metadata_id.defaultValue = $metadataLakehouse.id
                }
            } else {
                Write-Host "##[warning]Metadata lakehouse not found"
            }
        }
       
        if ($content.properties.parameters.lh_raw_id) {
            Write-Host "##[debug]Updating lh_raw_id"
            $rawLakehouse = $lakehouses | Where-Object { $_.displayName -like "*raw*" }
            if ($rawLakehouse) {
                 if ($content.properties.parameters.lh_raw_id.defaultValue) {
                    $content.properties.parameters.lh_raw_id.defaultValue = $rawLakehouse.id
                 }
            } else {
                Write-Host "##[warning]Raw lakehouse not found"
            }
        }
       
        if ($content.properties.parameters.lh_observability_id) {
            Write-Host "##[debug]Updating lh_observability_id"
            $observabilityLakehouse = $lakehouses | Where-Object { $_.displayName -like "*observability*" }
            if ($observabilityLakehouse) {
                if ($content.properties.parameters.lh_observability_id.defaultValue) {
                    $content.properties.parameters.lh_observability_id.defaultValue = $observabilityLakehouse.id
                }
            } else {
                Write-Host "##[warning]Observability lakehouse not found"
            }
        }
       
        if ($content.properties.parameters.workspace_id) {
            Write-Host "##[debug]Updating workspace_id"
            if ($content.properties.parameters.workspace_id.defaultValue) {
                $content.properties.parameters.workspace_id.defaultValue = $workspaceId
            }
        }
    }

    $lakehouseParameters = $content.properties.parameters.PSObject.Properties |
        Where-Object { $_.Name -match '^lh_.+_id$' }
    
    Write-Host "##[debug]Found $($lakehouseParameters.Count) lakehouse parameter(s)"

    function Find-LakehouseByName {
        param(
            [string]$lakehouseName,
            [object]$lakehouses
        )
    
        Write-Host "##[debug]  Searching for lakehouse matching: '$lakehouseName'"
    
        # Try exact match first (case-insensitive)
        $lakehouse = $lakehouses | Where-Object {
            $_.displayName -eq $lakehouseName
        } | Select-Object -First 1
    
        if ($lakehouse) {
            Write-Host "##[debug]  Found exact match: '$($lakehouse.displayName)' (ID: $($lakehouse.id))"
            return $lakehouse
        }
    
        # Try case-insensitive match
        $lakehouse = $lakehouses | Where-Object {
            $_.displayName.ToLower() -eq $lakehouseName.ToLower()
        } | Select-Object -First 1
    
        if ($lakehouse) {
            Write-Host "##[debug]  Found case-insensitive match: '$($lakehouse.displayName)' (ID: $($lakehouse.id))"
            return $lakehouse
        }
    
        # Try wildcard match (contains)
        $lakehouse = $lakehouses | Where-Object {
            $_.displayName -like "*$lakehouseName*"
        } | Select-Object -First 1
    
        if ($lakehouse) {
            Write-Host "##[debug]  Found wildcard match: '$($lakehouse.displayName)' (ID: $($lakehouse.id))"
            return $lakehouse
        }
    
        Write-Host "##[warning]  No lakehouse found matching: '$lakehouseName'"
        return $null
    }

    foreach ($param in $lakehouseParameters) {
        $paramName = $param.Name
        $paramValue = $param.Value
        
        Write-Host "##[debug]Processing parameter: '$paramName'"
        
        # Extract lakehouse name from parameter name
        $lakehouseName = Get-LakehouseNameFromParameter -parameterName $paramName
        
        if ($lakehouseName) {
            # Find the matching lakehouse
            $targetLakehouse = Find-LakehouseByName -lakehouseName $lakehouseName -lakehouses $lakehouses
            
            if ($targetLakehouse) {
                if ($paramValue.defaultValue) {
                    $oldValue = $paramValue.defaultValue
                    $paramValue.defaultValue = $targetLakehouse.id
                    Write-Host "##[debug]  Updated '$paramName': $oldValue -> $($targetLakehouse.id)"
                } else {
                    Write-Host "##[debug]  Parameter '$paramName' has no defaultValue property"
                }
            } else {
                Write-Host "##[warning]  Could not find lakehouse for parameter '$paramName' (expected name: '$lakehouseName')"
            }
        } else {
            Write-Host "##[warning]  Could not extract lakehouse name from parameter: '$paramName'"
        }
    }        
    

    # if ($content.properties -and $content.properties.activities) {
    #     Write-Host "##[debug]Checking activities..."
        
    #     foreach ($activity in $content.properties.activities) {
    #         if ($activity.type -eq "InvokePipeline" -and $activity.typeProperties) {
    #             Write-Host "##[debug]Updating workspaceId for activity: $($activity.name)"
    #             $activity.typeProperties.workspaceId = $workspaceId
    #         }
    #     }
    # }

    # Recursively process all objects within the pipeline to update workspaceId
    function Update-WorkspaceIds {
        param(
            [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
            [object]$InputObject
        )
       
        # Skip if null
        if ($null -eq $InputObject) {
            return
        }
       
        # Process arrays
        if ($InputObject -is [System.Array]) {
            foreach ($item in $InputObject) {
                Update-WorkspaceIds -InputObject $item
            }
            return
        }
       
        # Process objects
        if ($InputObject -is [PSCustomObject]) {
            # Check if this is an activity with workspaceId that needs updating
            if (($InputObject.PSObject.Properties.Name -contains "type") -and
                ($InputObject.PSObject.Properties.Name -contains "typeProperties") -and
                ($InputObject.type -eq "InvokePipeline")) {
                Write-Host "##[debug]Updating workspaceId for activity: $($InputObject.name)"
                $InputObject.typeProperties.workspaceId = $workspaceId
            }
           
            # Recursively process all properties of this object
            foreach ($property in $InputObject.PSObject.Properties) {
                Update-WorkspaceIds -InputObject $property.Value
            }
        }
    }

    # Process all activities recursively to update workspaceIds
    if ($content.properties -and $content.properties.activities) {
        Write-Host "##[debug]Recursively updating workspaceIds in all activities..."
        Update-WorkspaceIds -InputObject $content.properties.activities
    }

    $contentJson = ConvertTo-Json -InputObject $content -Depth 100
   
   # Create a mapping of lakehouse names to IDs
    Write-Host "##[debug]Building lakehouse name to ID mappings..."
    foreach ($lakehouse in $lakehouses) {
        Write-Host "##[debug]Found lakehouse: $($lakehouse.displayName) with ID: $($lakehouse.id)"
    }
   
    # Now do string replacements for all artifactIds
    foreach ($lakehouse in $lakehouses) {
        # Look for linkedService pattern:
        # "linkedService": {
        #   "name": "den_lhw_pdi_001_metadata",
        #   "properties": {
        #     "type": "Lakehouse",
        #     "typeProperties": {
        #       "artifactId": "8b2c756c-53e7-bda0-4d1b-0fd908217f49",
       
        $linkedServicePattern = "name`":\s*`"$($lakehouse.displayName)`"[\s\S]*?`"artifactId`":\s*`"([^`"]+)`""
        if ($contentJson -match $linkedServicePattern) {
            $oldArtifactId = $Matches[1]
            Write-Host "##[debug]Replacing artifactId: $oldArtifactId with: $($lakehouse.id) for lakehouse: $($lakehouse.displayName)"
            $contentJson = $contentJson -replace $oldArtifactId, $lakehouse.id
        }
    }
          
    # Replace pipeline logicalIds with ids
    foreach ($replacement in $pipelineReplacements) {
        Write-Host ("##[debug]Replacing logicalId: " + $replacement.logicalId + " with id: " + $replacement.id)
        $contentJson = $contentJson.Replace($replacement.logicalId, $replacement.id)
    }
    
    # Replace "00000000-0000-0000-0000-000000000000" with workspaceId
    $contentJson = $contentJson.Replace("00000000-0000-0000-0000-000000000000", $workspaceId)
   
    # Process connection mappings
    write-host ("##[debug]Processing connection mappings")
    write-host ("##[debug]Fabric Connections: " + (ConvertTo-Json -InputObject $fabricConnections))
    Write-Host ("##[debug]Fabric Managed Connections: " + (ConvertTo-Json -InputObject $fabricManagedConnections))

    foreach ($mapping in $fabricManagedConnections) {
        $connection = $fabricConnections | Where-Object { $_.displayName -eq $mapping.new_name }
        if ($connection) {
            Write-Host ("##[debug]Replacing connection name from " + $mapping.original_name + " to " + $mapping.new_name)
            Write-Host ("##[debug]Replacing connection ID from " + $mapping.guid + " to " + $connection.id)
            $contentJson = $contentJson.Replace($mapping.original_name, $mapping.new_name)
            $contentJson = $contentJson.Replace($mapping.guid, $connection.id)
        }
    }

    # Get notebook mappings
    $notebookMappings = Get-NotebookMappings

    # Process notebook mappings
    foreach ($mapping in $notebookMappings) {
        Write-Host ("##[debug]Processing notebook mapping for: " + $mapping.displayName)
       
        # Find matching notebook from notebookIds array
        # Remove environment prefix (dev_) if present in the notebook displayName
        $matchingNotebook = $notebookIds | Where-Object {
            $cleanedDisplayName = $_.displayName -replace '^dev_', ''
            $cleanedDisplayName -like "*$($mapping.displayName)*"
        }

        if ($matchingNotebook) {
            Write-Host ("##[debug]Found matching notebook: " + $matchingNotebook.displayName)
            Write-Host ("##[debug]Replacing notebook ID: " + $mapping.searchId + " with: " + $matchingNotebook.id)
            $contentJson = $contentJson.Replace($mapping.searchId, $matchingNotebook.id)
        } else {
            Write-Host ("##[warning]No matching notebook found for: " + $mapping.displayName)
        }
    }
   
    return (ConvertFrom-Json -InputObject $contentJson)
}

# Function to update pipeline definition
function Update-PipelineDefinition {
    param (
        [string]$token,
        [string]$workspaceId,
        [string]$itemId,
        [object]$definition
    )
   
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
   
    # Convert definition to JSON string
    $definitionJson = ConvertTo-Json -InputObject $definition -Depth 100
   
    Write-Host ("##[debug]definitionJson: " + $definitionJson)

    # Convert to bytes then base64
    $fileBytes = [System.Text.Encoding]::UTF8.GetBytes($definitionJson)
    $contentPayload = [System.Convert]::ToBase64String($fileBytes)
   
    $body = @{
        displayName = $definition.displayName
        description = $definition.description
        definition = @{
            parts = @(
                @{
                    path = "pipeline-content.json"
                    payload = $contentPayload
                    payloadType = "InlineBase64"
                }
            )
        }
    }
        
    try {
        $bodyJson = ConvertTo-Json -InputObject $body -Depth 100
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items/$itemId/updateDefinition"
       
        Write-Host ("##[debug]Updating pipeline definition: " + $uri)
       
        $response = Invoke-FabricApiWithRetry -Uri $uri -Headers $headers -Method POST -Body $bodyJson -MaxRetries 5
        return $response
    }
    catch {
        Write-Error ("Failed to update pipeline definition: " + $_)
        throw
    }
}

# Main script execution
try {
    Write-Host "##[section]Starting Data Pipeline Setup"

   
    $token = $env:FABRIC_TOKEN
    $workspaceIds = ConvertFrom-Json -InputObject $env:WORKSPACE_IDS
    $fabricConnections = ConvertFrom-Json -InputObject $env:FABRIC_CONNECTIONS
    $notebookIds = ConvertFrom-Json -InputObject $env:NOTEBOOK_IDS
    $fabricManagedConnections = ConvertFrom-Json -InputObject $env:FABRIC_MANAGED_CONNECTIONS_DETAILED

    Write-Host "##[debug]Parameters from Setup-FabricDataPipelines.ps1"
    Write-Host ("##[debug]Workspace IDs: " + (ConvertTo-Json -InputObject $workspaceIds))
    Write-Host ("##[debug]Fabric Connections: " + (ConvertTo-Json -InputObject $fabricConnections))
    Write-Host ("##[debug]Notebook IDs: " + (ConvertTo-Json -InputObject $notebookIds)) 
    Write-Host ("##[debug]Fabric identifiers: " + $fabricIdentifiers)

    $workspaceId = $workspaceIds.PSObject.Properties.Value
    Write-Host ("##[debug]Using workspace ID: " + $workspaceId)
   
    # Step 1: Get platform files
    $platformFiles = Get-PlatformFiles
   
    # Step 2: Create data pipelines
    $createdPipelines = New-FabricDataPipelines -token $token -workspaceId $workspaceId -platformFiles $platformFiles
   
    Write-Host ("##[debug]Created pipelines: " + (ConvertTo-Json -InputObject $createdPipelines))

    # Create pipeline replacements
    $pipelineReplacements = @()
    foreach ($pipeline in $createdPipelines) {

        if ([string]::IsNullOrEmpty($pipeline.logicalId) -or [string]::IsNullOrEmpty($pipeline.id)) {
            Write-Host ("##[debug]Skipping pipeline replacement for pipeline with missing logicalId or id: " + $pipeline.displayName)
            continue
        }       
        $pipelineReplacements += @{
            logicalId = $pipeline.logicalId
            id = $pipeline.id
        }
    }
    
    # Step 3: Get lakehouses
    $lakehouses = Get-Lakehouses -token $token -workspaceId $workspaceId
   
    # Step 4 & 5: Update pipeline definitions
    foreach ($pipeline in $createdPipelines) {

        # skip if no folder path property exists
        if ([string]::IsNullOrEmpty($pipeline.folderPath)) {
            Write-Host ("##[debug]Skipping pipeline with no folder path: " + $pipeline.displayName)
            continue
        }

        Write-Host ("##[debug]Processing pipeline for definition update: " + $pipeline.displayName)
        Write-Host ("##[debug]Pipeline : " + (ConvertTo-Json -InputObject $pipeline))

        $pipelineContentPath = Join-Path -Path $pipeline.folderPath -ChildPath "pipeline-content.json"
        if (Test-Path -Path $pipelineContentPath) {
            Write-Host ("##[debug]Processing pipeline: " + $pipeline.displayName)
           
            $updatedContent = Update-PipelineContent `
                -pipelinePath $pipelineContentPath `
                -lakehouses $lakehouses `
                -workspaceId $workspaceId `
                -pipelineReplacements $pipelineReplacements `
                -fabricConnections $fabricConnections `
                -notebookIds $notebookIds `
                -fabricManagedConnections $fabricManagedConnections

               
            Update-PipelineDefinition `
                -token $token `
                -workspaceId $workspaceId `
                -itemId $pipeline.id `
                -definition $updatedContent 
        }
    }

    # Step 6: Deploy pipeline schedules
    Write-Host "##[section]Deploying pipeline schedules"
    
    # Export created pipelines for schedule deployment
    $env:CREATED_PIPELINES = ConvertTo-Json -InputObject $createdPipelines -Depth 10 -Compress
    
    # Call the schedule deployment script
    $scheduleScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Deploy-PipelineSchedules.ps1"
    if (Test-Path -Path $scheduleScriptPath) {
        Write-Host "##[debug]Invoking schedule deployment script: $scheduleScriptPath"
        . $scheduleScriptPath
    }
    else {
        Write-Warning "Schedule deployment script not found at: $scheduleScriptPath"
        Write-Host "##[debug]Skipping schedule deployment"
    }
   
    Write-Host "##[section]Pipeline creation and updates completed successfully"
}
catch {
    Write-Error ("##[error]Script failed: " + $_)
    throw
}
