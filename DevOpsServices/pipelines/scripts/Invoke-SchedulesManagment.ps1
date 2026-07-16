param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,
    [Parameter(Mandatory = $true)]
    [string]$FabricSourcePath = "../../../src/fabric"
)

function Get-NotebookIdByName {
    param(
        [string]$WorkspaceId,
        [string]$Name,
        [string]$Token
    )

    try {
        Write-Host "Looking up notebook ID for notebook name: $Name in workspace: $WorkspaceId"
       
        if ($null -eq $WorkspaceId) {
            Write-Error "WorkspaceId parameter is null or empty. Cannot lookup notebook ID without workspace context."
            exit 1
        }
        if ($null -eq $Name) {
            Write-Error "Name parameter is null or empty. Cannot lookup notebook ID without a name to search for."
            exit 1
        }
        if ($null -eq $Token) {
            Write-Error "Token parameter is null or empty. Cannot authenticate API request to lookup notebook ID."
            exit 1
        }
        if ($null -eq $notebooks) {
            # Construct API URL for notebooks in the workspace
            $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks"
       
            # Set up headers with auth token
            $headers = @{
                "Authorization" = "Bearer $Token"
                "Content-Type"  = "application/json"
            }
       
            # Send request to get notebooks
            $notebooks = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
        }
       
        # Iterate through notebooks to find matching display name
        $matchingNotebook = $notebooks.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingNotebook) {
            Write-Error "No notebook found with name: $Name in workspace: $WorkspaceId"
            exit 1
        }
       
        $notebookId = $matchingNotebook.id
        Write-Host "Found notebook ID: $notebookId for notebook name: $Name in workspace: $WorkspaceId"
        return $notebookId
    }
    catch {
        Write-Error "Failed to get notebook ID: $_"
        exit 1
    }

}

function Get-PipelineIdByName {
    param(
        [string]$WorkspaceId,
        [string]$Name,
        [string]$Token
    )

    try {
        Write-Host "Looking up pipeline ID for pipeline name: $Name in workspace: $WorkspaceId"
       
        if ($null -eq $WorkspaceId) {
            Write-Error "WorkspaceId parameter is null or empty. Cannot lookup pipeline ID without workspace context."
            exit 1
        }
       
        if ($null -eq $Name) {
            Write-Error "Name parameter is null or empty. Cannot lookup pipeline ID without a name to search for."
            exit 1
        }
       
        if ($null -eq $Token) {
            Write-Error "Token parameter is null or empty. Cannot authenticate API request to lookup pipeline ID."
            exit 1
        }

        if ($null -eq $pipelines) {

            # Construct API URL for pipelines in the workspace
            $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/dataPipelines"
       
            # Set up headers with auth token
            $headers = @{
                "Authorization" = "Bearer $Token"
                "Content-Type"  = "application/json"
            }
       
            # Send request to get pipelines
            $pipelines = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
        }
       
        # Iterate through pipelines to find matching display name
        $matchingPipeline = $pipelines.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingPipeline) {
            Write-Error "No pipeline found with name: $Name in workspace: $WorkspaceId"
            exit 1
        }
       
        $pipelineId = $matchingPipeline.id
        Write-Host "Found pipeline ID: $pipelineId for pipeline name: $Name in workspace: $WorkspaceId"
        return $pipelineId
    }
    catch {
        Write-Error "Failed to get pipeline ID: $_"
        exit 1
    }

}

Function Get-SparkJobDefinitionIdByName {
    param(
        [string]$WorkspaceId,
        [string]$Name,
        [string]$Token
    )

    try {
        Write-Host "Looking up Spark job definition ID for name: $Name in workspace: $WorkspaceId"
       
        if ($null -eq $WorkspaceId) {
            Write-Error "WorkspaceId parameter is null or empty. Cannot lookup Spark job definition ID without workspace context."
            exit 1
        }
       
        if ($null -eq $Name) {
            Write-Error "Name parameter is null or empty. Cannot lookup Spark job definition ID without a name to search for."
            exit 1
        }
       
        if ($null -eq $Token) {
            Write-Error "Token parameter is null or empty. Cannot authenticate API request to lookup Spark job definition ID."
            exit 1
        }

        if ($null -eq $sparkJobDefinitions) {

            # Construct API URL for Spark job definitions in the workspace
            $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/sparkJobDefinitions"
       
            # Set up headers with auth token
            $headers = @{
                "Authorization" = "Bearer $Token"
                "Content-Type"  = "application/json"
            }
       
            # Send request to get Spark job definitions
            $sparkJobDefinitions = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
        }
       
        # Iterate through Spark job definitions to find matching display name
        $matchingSparkJobDefinition = $sparkJobDefinitions.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingSparkJobDefinition) {
            Write-Error "No Spark job definition found with name: $Name in workspace: $WorkspaceId"
            exit 1
        }
       
        $sparkJobDefinitionId = $matchingSparkJobDefinition.id
        Write-Host "Found Spark job definition ID: $sparkJobDefinitionId for name: $Name in workspace: $WorkspaceId"
        return $sparkJobDefinitionId
    }
    catch {
        Write-Error "Failed to get Spark job definition ID: $_"
        exit 1
    }

}

# Main execution
try {
    # Set Fabric token
    $token = $env:FABRIC_TOKEN

    if ($null -eq $token) {
        Write-Error "FABRIC_TOKEN environment variable is not set. Cannot authenticate API requests without a token."
        exit 1
    }
   
    $scheduleFiles = Get-ChildItem -Path $FabricSourcePath -Recurse -Filter ".schedules"
            
    if ($scheduleFiles.Count -eq 0) {
        Write-Host "##[warning]No schedule files found, skipping schedule management"
        return
    }

    foreach ($file in $scheduleFiles) {
        try {
            Write-Host "##[debug]Processing schedule file: $($file.FullName) folderPath: $($file.DirectoryName)"
            $scheduleContent = Get-Content -Path $file.FullName -Raw
            $scheduleJson = $scheduleContent | ConvertFrom-Json

            if ($null -eq $scheduleJson.Schedules) {
                Write-Host "##[warning]No Schedules section found in file: $($file.FullName), skipping"
                continue
            }

            $scheduleJson.Schedules | ConvertTo-Json -Depth 20
            $platformContent = Get-Content -Path ($file.DirectoryName + "\.platform") -Raw
            $platformJson = $platformContent | ConvertFrom-Json
            if ($null -eq $platformJson.Metadata) {
                Write-Host "##[warning]No Metadata section found in file: $($file.FullName), skipping"
                continue
            }
            $metadata = $platformJson.Metadata
            if ($null -eq $metadata.type -or $null -eq $metadata.displayName) {
                Write-Host "##[warning]Metadata section does not contain type or displayName in file: $($file.FullName), skipping"
                continue
            }
            $itemType = $metadata.type
            $displayName = $metadata.displayName
            switch ($itemType) {
                "Notebook" {
                    $itemId = Get-NotebookIdByName -WorkspaceId $WorkspaceId -Name $displayName -Token $token
                    $jobType = "RunNotebook"
                }
                "DataPipeline" {
                    $itemId = Get-PipelineIdByName -WorkspaceId $WorkspaceId -Name $displayName -Token $token
                    $jobType = "Pipeline"
                }
                "SparkJobDefinition" {
                    $itemId = Get-SparkJobDefinitionIdByName -WorkspaceId $WorkspaceId -Name $displayName -Token $token
                    $jobType = "sparkjob"
                }
                default {
                    Write-Host "##[warning]Unsupported item type: $itemType in file: $($file.FullName), skipping"
                    continue
                }
            }
            
            if ($null -eq $itemId) {
                Write-Host "##[warning]Could not find item ID for type: $itemType displayName: $displayName, skipping"
                continue
            }

            Write-Host "##[debug]Found schedule for item type: $itemType displayName: $displayName"
               
            Write-Host "##[debug]Calling Create-ItemSchedule.ps1 with resolved IDs"
        
            # Call the actual schedule creation script
            & "$PSScriptRoot\Create-ItemSchedule.ps1" `
                -WorkspaceId $WorkspaceId `
                -ItemId $itemId `
                -JobType $jobType `
                -ScheduleJson $scheduleContent
        }
        catch {
            Write-Error "Error processing schedule file $($file.FullName): $_"
            continue
        }
    }

    Write-Host "##[debug]Schedule creation process executed for all schedule files"
}
catch {
    Write-Error "Error in schedule creation process: $_"
    exit 1
}