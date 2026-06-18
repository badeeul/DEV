##################################
# Deploy Fabric Environment Spark Libraries
##################################
# Objective:
# The purpose of this script is to get all of the Fabric Environment Spark Libraries
# from Fabric source code and deploy it to the workspace environment. This is not
# supported by Terraform and should happen after the Environments have been created
# for a workspace.
#
# This supports .whl and .yml files for the custom libraries.
#
# Parameters:
# - $SourceCodePath: The path to the Fabric source code (default: "../../../src/fabric").
# - $FabricItemType: The type of Fabric item to process (default: "Environment").
##################################

param (
    [string] $SourceCodePath = "../../../src/fabric",
    [string] $FabricItemType = "Environment"
)

# Check if the module is installed
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    # Install the module if it's not installed
    Install-Module -Name powershell-yaml -Force -Scope CurrentUser
}
# Import the module
Import-Module -Name powershell-yaml


$FabricToken = $env:FABRIC_TOKEN
$workspaceIds = $env:WORKSPACE_IDS | ConvertFrom-Json

Write-Host "##[debug]Workspace IDs: $workspaceIds"
Write-Host "##[debug]Update Spark Libraries: $updateSparkLibraries"

$WorkspaceId = $workspaceIds.PSObject.Properties.Value

# Set auth headers for both the POST and GET. "Content-Type"  = "multipart/form-data" is needed for the POST of Libraries.
$global:auth_header = @{
    'Content-Type'  = "application/json"
    'Authorization' = "Bearer {0}" -f $FabricToken
}

##################################
# Function to Gather Source Content Information from Microsoft Fabric Environments
##################################
function Read-PlatformFiles {
    param (
        [string]$BaseFolderPath,
        [string]$FabricItemType = "Environment"
    )

    $results = @()

    # Get all subfolders in the base folder
    $folders = Get-ChildItem -Path $BaseFolderPath -Directory -Recurse -Include "*.$($FabricItemType)"
    Write-Host "##[debug]Found $($folders.Count) folders for Fabric Item Type: $FabricItemType"
    if ($folders.Count -eq 0) {
        Write-Host "##[debug]No folders found for Fabric Item Type: $FabricItemType"
        return $results
    }
    # list folders for debugging
    Write-Host "##[debug]Folders found:"
    $folders | ForEach-Object { Write-Host "##[debug] - $($_.FullName)" }   
    
    foreach ($folder in $folders) {
        $platformFilePath = Join-Path -Path $folder.FullName -ChildPath ".platform"
        if (Test-Path -Path $platformFilePath) {
            $platformContent = Get-Content -Path $platformFilePath -Raw | ConvertFrom-Json
            $whlFiles = @()
            $customLibraryFiles = @()

            $result = [pscustomobject]@{
                logicalId   = $platformContent.config.logicalId
                type        = $platformContent.metadata.type
                displayName = $platformContent.metadata.displayName
                description = $platformContent.metadata.description
                folderPath  = $folder.FullName
            }
            $contentFileName = "Setting/Sparkcompute.yml"
            $contentFilePath = Join-Path -Path $folder.FullName -ChildPath  $contentFileName
            $environmentSparkPoolId = (Get-Content -Path $contentFilePath -Raw | ConvertFrom-Yaml).instance_pool_id
            $environmentSparkPoolName = ($global:devLkupSparkPools | Where-Object { $_.id -eq $environmentSparkPoolId }).name
            $platformFilePath = Join-Path -Path $folder.FullName -ChildPath ".platform"
            $libraryFilePath = Join-Path -Path $folder.FullName -ChildPath "Libraries"

            # Conditionally add the attribute
            if (Test-Path -Path $contentFilePath) { $result | Add-Member -MemberType NoteProperty -Name "contentFile" -Value $contentFilePath }
            if (Test-Path -Path (Join-Path -Path $folder.FullName -ChildPath "Libraries")) { $result | Add-Member -MemberType NoteProperty -Name "environmentLibrariesPath" -Value $libraryFilePath }
            if ($platformContent.metadata.type -eq "Environment") {
                $result | Add-Member -MemberType NoteProperty -Name "environmentDevSparkPoolId" -Value $environmentSparkPoolId
                $result | Add-Member -MemberType NoteProperty -Name "environmentSparkPoolName" -Value $environmentSparkPoolName
            }
           
            # Get all files in the library file path and its subfolders, currently supports .whl and .yml files
            if (Test-Path -Path $libraryFilePath) {
                $files = Get-ChildItem -Path $libraryFilePath -Recurse -File
               
                foreach ($file in $files) {
                    if ($file.Extension -eq ".whl") {
                        $whlFiles += $file.FullName
                    }
                    elseif ($file.Extension -eq ".yml") {
                        $customLibraryFiles += $file.FullName
                    }
                }
                if ($whlFiles | Where-Object { $_ }) { $result | Add-Member -MemberType NoteProperty -Name "whlFiles" -Value $whlFiles }
                if ($customLibraryFiles | Where-Object { $_ }) { $result | Add-Member -MemberType NoteProperty -Name "customLibraryFiles" -Value $customLibraryFiles }

                # display whlFiles and customLibraryFiles for debugging
                Write-Host "##[debug]Found $($whlFiles.Count) .whl files and $($customLibraryFiles.Count) .yml files in $libraryFilePath"
                Write-Host "##[debug] .whl files:"
                $whlFiles | ForEach-Object { Write-Host "##[debug] - $_" }
                Write-Host "##[debug] .yml files:"
                $customLibraryFiles | ForEach-Object { Write-Host "##[debug] - $_" }
            }
            $results += $result
        }
    }

    return $results
}

##################################
# Gets list of environments for a workspace from Microsoft Fabric.
##################################
function Get-Environments {
    param (
        [string] $WorkspaceId
    )
    Write-Host "##[debug]Getting Environments for Workspace: $WorkspaceId"
    $environmentsUrl = "https://api.fabric.microsoft.com/v1/workspaces/$($workspaceId)/environments"
    Write-Host $environmentsUrl
    try {
        $environments = Invoke-RestMethod -Uri $environmentsUrl -Method Get -Headers $global:auth_header
        $environments.StatusDescription
        $environments.StatusCode

        return $environments
    }
    catch {
        Write-Error "##[debug]Failed to retrieve environments: $_"
        return $null
    }
}

##################################
# Function to Retrieve Environment Library State from Microsoft Fabric.
# This will check the status of the libraries in the environment.
##################################
function Get-EnvironmentLibraryState {
    param (
        [string]$WorkspaceId,
        [string]$environmentId
    )

    $librariesUrl = "https://api.fabric.microsoft.com/v1/workspaces/$($WorkspaceId)/environments/$($environmentId)"

    try {
        Write-Host "##[debug]Retrieving Spark Environment status for environment: $environmentId"
        $libraries = Invoke-RestMethod -Uri $librariesUrl -Method Get -Headers $global:auth_header
        Write-Host "##[debug]`tState: $($libraries.properties.publishDetails.state)"
        return @{
            id          = $libraries.id
            type        = $libraries.type
            displayName = $libraries.displayName
            state       = $libraries.properties.publishDetails.state
        }
    }
    catch {
        Write-Error "##[debug]Failed to retrieve libraries for environment: $environmentId. Error: $($_.Exception.Message)"
        return $null
    }
}

function Get-PublishedEnvironmentLibraries {
    param (
        [string]$WorkspaceId,
        [string]$environmentId
    )

    $librariesUrl = "https://api.fabric.microsoft.com/v1/workspaces/$($WorkspaceId)/environments/$($environmentId)/libraries"

    try {
        Write-Host "##[debug]Retrieving Spark Environment status for environment: $environmentId"
        $libraries = Invoke-RestMethod -Uri $librariesUrl -Method Get -Headers $global:auth_header
        Write-Host "##[debug]`tCustomLibraries: $($libraries.customLibraries.wheelFiles)"
        return @{
            libraries   = $libraries.customLibraries.wheelFiles
        }
    }
    catch {
        Write-Error "##[debug]Failed to retrieve libraries for environment: $environmentId. Error: $($_.Exception.Message)"
        return $null
    }
}

##################################
# Function to Get Existing Libraries from Microsoft Fabric Environment
##################################
function Get-ExistingLibraries {
    param (
        [string]$WorkspaceId,
        [string]$environmentId
    )

    Write-Host "##[debug]Getting existing libraries for environment: $environmentId"

    $state = Get-EnvironmentLibraryState -WorkspaceId $WorkspaceId -environmentId $environmentId
    return $state.libraries
}

##################################
# Function to Delete Existing Library from Microsoft Fabric Environment
##################################
function Remove-ExistingLibrary {
    param (
        [string]$WorkspaceId,
        [string]$environmentId,
        [string]$libraryName
    )

    $deleteUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments/$environmentId/staging/libraries?libraryToDelete=$libraryName"

    try {
        Write-Host "##[debug]`tDeleting library: $libraryName from environment: $environmentId"
        $response = Invoke-RestMethod -Uri $deleteUrl -Method Delete -Headers $global:auth_header
        Write-Host "##[debug]`tSuccessfully deleted library: $libraryName"
        return $true
    }
    catch {
        Write-Error "##[debug]Failed to delete library $libraryName from environment $environmentId. Error: $($_.Exception.Message)"
        return $false
    }
}

##################################
# Function to Upload Staging Libraries to Microsoft Fabric Environment
##################################
function Send-StagingLibraries {
    param (
        [string]$FabricToken,
        [string]$WorkspaceId,
        [string]$environmentId,
        [string]$libraryType,
        [array]$libraryPaths
    )

    $librariesUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments/$environmentId/staging/libraries"
    $headers = @{
        "Authorization" = "Bearer $FabricToken"
    }
    $uploadStageStatus = @()

        $library_auth_headers = @{
            'Authorization' = "Bearer {0}" -f $FabricToken
            "Content-Type"  = "multipart/form-data"
        }

    foreach ($library in $libraryPaths) {
        # Get just the filename from the path
        $libraryFileName = Split-Path -Path $library -Leaf

        # Check if the library already exists and delete it
        $existingLibraries =  Get-PublishedEnvironmentLibraries -WorkspaceId $WorkspaceId -environmentId $environmentId
        $existingLibrariesJson = $existingLibraries | ConvertTo-Json -Compress
                
        write-Host "##[debug]Existing Libraries Json: $existingLibrariesJson"
        write-Host "##[debug]Library File Name: $libraryFileName"
        write-Host "##[debug]Update Spark Libraries: $env:UPGRADE_SPARK_LIBRARIES" 

        if ($existingLibraries.libraries) {
            $existingLibrariesArray = $existingLibraries.libraries
            if ($existingLibrariesArray -and $existingLibrariesArray -contains $libraryFileName) {
                if ($env:UPGRADE_SPARK_LIBRARIES -eq "True") {
                    Write-Host "##[debug]##[debug]`tLibrary $libraryFileName already exists. Deleting it first..."
                    $deleted = Remove-ExistingLibrary -WorkspaceId $WorkspaceId -environmentId $environmentId -libraryName $libraryFileName
                    if (-not $deleted) {
                        Write-Warning "`tFailed to delete existing library. Continuing with upload anyway..."
                    }
                }
                else
                {
                    Write-Host "##[debug]##[debug]`tLibrary $libraryFileName already exists. Skipping upload..."
                    continue
                }
                # Wait a bit after deletion
                Start-Sleep -Seconds 3
            }
        }

        $form = @{
            "file" = Get-Item -Path $library
        }
        Start-Sleep -Seconds 3
        Write-Host "##[debug]##[debug]`tStarting upload of $libraryType library: $library"
        try {
            $response = Invoke-WebRequest -Uri $librariesUrl -Method Post -Headers $library_auth_headers -Form $form
            $uploadStageStatus += @{
                workspaceId   = $WorkspaceId
                environmentId = $environmentId
                library       = $library
                statusCode    = $response.StatusCode
                statusMessage = "Success: $($response.StatusDescription)"
            }
        }
        catch {
            Write-Error "##[debug]Failed to upload $libraryType library: $_"
            $uploadStageStatus += @{
                workspaceId   = $WorkspaceId
                environmentId = $environmentId
                library       = $library
                statusCode    = $_.FullyQualifiedErrorId
                statusMessage = "Failed: $($_.ErrorDetails.Message)"
            }
        }
    }
    return $uploadStageStatus
}

##################################
# Function to Publish Staging Libraries to Microsoft Fabric Environment
##################################
function Publish-StagingLibraries {
    param (
        [string]$WorkspaceId,
        [string]$environmentId
    )

    $publishUrl = "https://api.fabric.microsoft.com/v1/workspaces/$($WorkspaceId)/environments/$($environmentId)/staging/publish"

    try {
        Write-Host "##[debug]`tPublishing staging libraries for environment: $environmentId"
        $response = Invoke-WebRequest -Uri $publishUrl -Method Post -Headers $global:auth_header
        Write-Host "##[debug]`tPublish response: $($response.StatusDescription)"
        return $response.Content
    }
    catch {
        Write-Error "##[debug]Failed to publish libraries for environment: $environmentId. Error: $($_.Exception.Message)"
        return $null
    }
}

# Gets all of the platform files for Environment, this will get any .whl files to be deployed
$itemPlatformFiles = Read-PlatformFiles -BaseFolderPath $SourceCodePath -FabricItemType $FabricItemType

# display itemPlatformFiles for debugging 
Write-Host "##[debug]Item Platform Files JSON: $($itemPlatformFiles | ConvertTo-Json -Compress)"

# Get the environments for the workspace
$workspaceEnvironments = Get-Environments -workspaceId $WorkspaceId #- workspaceId $WorkspaceId

foreach ($environment in $workspaceEnvironments.value) {
    $environmentId = $environment.id
    $environmentItem = $itemPlatformFiles | Where-Object { $_.displayName -eq $environment.displayName }
    $whlFiles = $environmentItem.whlFiles
    $customLibraryFiles = $environmentItem.customLibraryFiles

    Write-Host "##[debug]Processing Environment: $($environment.displayName) | ID: $($environment.id) | Workspace ID: $WorkspaceId"

    $getState = Get-EnvironmentLibraryState -workspaceId $WorkspaceId -environmentId $environmentId

    if ($getState.state -eq "Running") {
        Write-Host "##[debug]`tEnvironment libraries are currently being published. Skipping upload and publish."
        continue
    }

    if ($whlFiles) {
        # Send the whl libraries to the environment for staging.
        "-------------------------------------"
        $uploadStatus = Send-StagingLibraries -FabricToken $FabricToken -workspaceId $WorkspaceId -environmentId $environmentId -libraryType "wheelFiles" -libraryPaths $whlFiles

        $uploadStatus | ForEach-Object {
            Write-Host "##[debug]`tLibrary: $($_.library), Status: $($_.statusMessage)"
        }  
    }
    if ($customLibraryFiles) {
        
        # Send the custom yml libraries to the environment for staging.
        $uploadStatus = Send-StagingLibraries -FabricToken $FabricToken -workspaceId $WorkspaceId -environmentId $environmentId -libraryType "customYmlFiles" -libraryPaths $customLibraryFiles
        $uploadStatus | ForEach-Object {
            Write-Host "##[debug]`tLibrary: $($_.library), Status: $($_.statusMessage)"
        }
    }
    if (-Not $whlFiles -and -Not $customLibraryFiles) {
        Write-Host "##[debug]`tNo libraries to upload for environment: $($environment.displayName)"
        continue
    }
    $WaitForPublish = $false

    if ($WaitForPublish) {
        Write-Host "##[debug]`tPublishing libraries to staging environment..."
        Publish-StagingLibraries -workspaceId $WorkspaceId -environmentId $environmentId
        $finalState = Wait-ForEnvironmentState -workspaceId $WorkspaceId -environmentId $environmentId
        Write-Host "##[debug]`tFinal State: $($finalState.state)"
    }
    else {
        Publish-StagingLibraries -workspaceId $WorkspaceId -environmentId $environmentId
    }
}

