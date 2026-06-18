# Function to get staging libraries
function Get-StagingLibraries {
    param (
        [string]$token,
        [string]$workspaceId,
        [string]$environmentId
    )
   
    Write-Host "##[debug]Getting staging libraries..."

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    try {
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/environments/$environmentId/staging/libraries"
        Write-Host "##[debug]Fetching staging libraries from: $uri"

        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method Get `
            -Headers $headers

        return $response
    }
    catch {
        # Log the error but don't throw - this allows the caller to proceed with upload
        Write-Host "##[warning]Failed to get staging libraries: $_"
        return $null
    }
}

# Function to get published libraries
function Get-PublishedLibraries {
    param (
        [string]$token,
        [string]$workspaceId,
        [string]$environmentId
    )
   
    Write-Host "##[debug]Getting published libraries..."

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    try {
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/environments/$environmentId/libraries"
        Write-Host "##[debug]Fetching libraries from: $uri"

        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method Get `
            -Headers $headers

        return $response
    }
    catch {
        # Log the error but don't throw - this allows the caller to proceed with publish
        Write-Host "##[warning]Failed to get publishing libraries: $_"
        return $null
    }
}

# Function to upload Spark library
# function Upload-SparkLibrary {
#     param (
#         [string]$token,
#         [string]$workspaceId,
#         [string]$environmentId,
#         [string]$libraryPath
#     )
   
#     Write-Host "##[debug]Starting Spark library upload..."

#     $headers = @{
#         "Authorization" = "Bearer $token"
#     }

#     try {
#         # Verify file exists
#         if (-not (Test-Path -Path $libraryPath)) {
#             throw "Library file not found at path: $libraryPath"
#         }

#         # Read file content and convert to base64
#         $fileContent = Get-Content -Path $libraryPath -Raw -Encoding Byte
#         $base64Content = [Convert]::ToBase64String($fileContent)

#         $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/environments/$environmentId/staging/libraries"
       
#         Write-Host "##[debug]Uploading library to: $uri"
       
#         $boundary = [System.Guid]::NewGuid().ToString()
#         $headers["Content-Type"] = "multipart/form-data; boundary=$boundary"

#         # Construct multipart form data
#         $body = @"
# --$boundary
# Content-Disposition: form-data; name="file"; filename="spark_engine-0.1.0-py3-none-any.whl"
# Content-Type: application/octet-stream

# $base64Content
# --$boundary--
# "@

#         $response = Invoke-RestMethod `
#             -Uri $uri `
#             -Method Post `
#             -Headers $headers `
#             -Body $body

#         Write-Host "##[debug]Library upload successful"
#         return $response
#     }
#     catch {
#         Write-Error "##[error]Failed to upload library: $_"
#         throw
#     }
# }

function Upload-SparkLibrary {
    param (
        [string]$token,
        [string]$workspaceId,
        [string]$environmentId,
        [string]$libraryPath
    )
   
    Write-Host "##[debug]Starting Spark library upload..."

    $headers = @{
        "Authorization" = "Bearer $token"
    }

    try {
        # Verify file exists
        if (-not (Test-Path -Path $libraryPath)) {
            throw "Library file not found at path: $libraryPath"
        }

        # Read file content and convert to base64
        $fileContent = Get-Content -Path $libraryPath -Raw -Encoding Byte
        $base64Content = [Convert]::ToBase64String($fileContent)

        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/environments/$environmentId/staging/libraries"
       
        Write-Host "##[debug]Uploading library to: $uri"
       
        $boundary = [System.Guid]::NewGuid().ToString()
        $headers["Content-Type"] = "multipart/form-data; boundary=$boundary"

        # Construct multipart form data
        $body = @"
--$boundary
Content-Disposition: form-data; name="file"; filename="sparkengine.whl"
Content-Type: application/octet-stream

$base64Content
--$boundary--
"@

        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method Post `
            -Headers $headers `
            -Body $body

        Write-Host "##[debug]Library upload successful"
        return $response
    }
    catch {
        Write-Error "##[error]Failed to upload library: $_"
        throw
    }
}

# Function to publish Spark library
function Publish-SparkLibrary {
    param (
        [string]$token,
        [string]$workspaceId,
        [string]$environmentId,
        [int]$timeoutMinutes = 30
    )
   
    Write-Host "##[debug]Starting Spark library publishing..."

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    try {
        # Initiate publishing
        $publishUri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/environments/$environmentId/staging/publish"
        Write-Host "##[debug]Publishing library at: $publishUri"

        $response = Invoke-RestMethod -Uri $publishUri -Method Post -Headers $headers
       
        # Get status check URI
        $statusUri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/environments/$environmentId"
       
        # Initialize tracking variables
        $startTime = Get-Date
        $timeout = $startTime.AddMinutes($timeoutMinutes)
        $lastState = ""

        while ($true) {
            # Check for timeout
            if ((Get-Date) -gt $timeout) {
                throw "Publishing timed out after $timeoutMinutes minutes"
            }

            # Get current status
            $statusResponse = Invoke-RestMethod -Uri $statusUri -Method Get -Headers $headers
            $currentState = $statusResponse.properties.publishDetails.state

            # Log state change
            if ($currentState -ne $lastState) {
                Write-Host "##[debug]Current publish state: $currentState"
                $lastState = $currentState
               
                # Log component states if available
                if ($statusResponse.properties.publishDetails.componentPublishInfo) {
                    $sparkLibState = $statusResponse.properties.publishDetails.componentPublishInfo.sparkLibraries.state
                    $sparkSettingsState = $statusResponse.properties.publishDetails.componentPublishInfo.sparkSettings.state
                    Write-Host "##[debug]Spark Libraries state: $sparkLibState"
                    Write-Host "##[debug]Spark Settings state: $sparkSettingsState"
                }
            }

            # Check for completion
            if ($currentState -eq "Success") {
                Write-Host "##[debug]Library publishing completed successfully"
                return $statusResponse
            }
            elseif ($currentState -eq "Failed") {
                throw "Publishing failed. Check environment logs for details."
            }

            # Wait for 1 minute before next check
            Start-Sleep -Seconds 60
        }
    }
    catch {
        Write-Error "##[error]Failed to publish library: $_"
        throw
    }
}


# Main script execution
try {
    Write-Host "##[section]Starting Spark Library Deployment"
   
    $token = $env:FABRIC_TOKEN
    $workspaceId = $env:WORKSPACE_ID
    $environmentId = $env:ENVIRONMENT_ID
    $libraryPath = "../../../src/fabric/den_env_pdi_001_spark_runtime_environment.Environment/Libraries/CustomLibraries/spark_engine-0.1.0-py3-none-any.whl"
   
    Write-Host "##[debug]Parameters:"
    Write-Host "##[debug]Workspace ID: $workspaceId"
    Write-Host "##[debug]Environment ID: $environmentId"
    Write-Host "##[debug]Library Path: $libraryPath"

    # Get the wheel file name
    $wheelFileName = Split-Path $libraryPath -Leaf

    # Step 1: Check if library already exists in staging
    $proceedWithUpload = $true
    $stagingLibraries = Get-StagingLibraries `
        -token $token `
        -workspaceId $workspaceId `
        -environmentId $environmentId

    if ($null -ne $stagingLibraries -and $stagingLibraries.customLibraries.wheelFiles) {
        if ($stagingLibraries.customLibraries.wheelFiles -contains $wheelFileName) {
            Write-Host "##[debug]Library $wheelFileName already exists in staging. Skipping upload."
            $proceedWithUpload = $false
        }
    }

    # Step 2: Check if library already exists in published
    $proceedWithPublishing = $true
    $publishingLibrary = Get-PublishedLibraries `
        -token $token `
        -workspaceId $workspaceId `
        -environmentId $environmentId

   if ($null -ne $publishingLibrary -and $publishingLibrary.customLibraries.wheelFiles) {
        if ($publishingLibrary.customLibraries.wheelFiles -contains $wheelFileName) {
            Write-Host "##[debug]Library $wheelFileName already exists in publishing. Skipping publish."
            $proceedWithPublishing = $false
        }
    }

    if ($proceedWithUpload) {

        # Step 3: Upload library
        $uploadResult = Upload-SparkLibrary `
            -token $token `
            -workspaceId $workspaceId `
            -environmentId $environmentId `
            -libraryPath $libraryPath

        Write-Host "##[debug]Library upload result: $($uploadResult | ConvertTo-Json -Depth 10)"
    }

    if ($proceedWithPublishing) {
        # Step 4: Publish library
        $publishResult = Publish-SparkLibrary `
            -token $token `
            -workspaceId $workspaceId `
            -environmentId $environmentId

        Write-Host "##[debug]Library publish result: $($publishResult | ConvertTo-Json -Depth 10)"
    }
    
    Write-Host "##[section]Spark Library Deployment completed successfully"
    
}
catch {
    Write-Error "##[error]Script failed: $_"
    throw
}
