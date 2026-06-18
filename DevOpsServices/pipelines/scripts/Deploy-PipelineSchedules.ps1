# Deploy-PipelineSchedules.ps1
# This script deploys .schedules files for Fabric Data Pipelines
# Uses the Data Pipeline schedule API: /dataPipelines/{id}/jobs/execute/schedules
# Reference: https://learn.microsoft.com/en-us/rest/api/fabric/datapipeline/background-jobs/schedule-execute

function Get-PipelineSchedules {
    <#
    .SYNOPSIS
        Scans for .schedules files in pipeline folders
    #>
    Write-Host "##[debug]Searching for .schedules files..."
   
    $scheduleFiles = Get-ChildItem -Path "../../../src/fabric" -Filter "*.DataPipeline" -Recurse |
        ForEach-Object {
            $schedulePath = Join-Path -Path $_.FullName -ChildPath ".schedules"
            $platformPath = Join-Path -Path $_.FullName -ChildPath ".platform"
            
            if ((Test-Path -Path $schedulePath) -and (Test-Path -Path $platformPath)) {
                $scheduleContent = Get-Content -Path $schedulePath -Raw | ConvertFrom-Json
                $platformContent = Get-Content -Path $platformPath -Raw | ConvertFrom-Json
                
                @{
                    pipelineName = $platformContent.metadata.displayName
                    pipelineId = $platformContent.config.logicalId
                    schedules = $scheduleContent.schedules
                    schedulePath = $schedulePath
                }
            }
        }
   
    $count = ($scheduleFiles | Measure-Object).Count
    Write-Host "##[debug]Found $count pipeline(s) with .schedules files"
    return $scheduleFiles
}

function Get-ExistingSchedules {
    <#
    .SYNOPSIS
        Gets existing schedules for a pipeline item
    #>
    param (
        [string]$token,
        [string]$workspaceId,
        [string]$itemId
    )
    
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
   
    # Data Pipeline schedules use the execute schedules endpoint
    $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/dataPipelines/$itemId/jobs/execute/schedules"
    
    try {
        Write-Host "##[debug]Getting existing schedules from: $uri"
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        
        if ($response.value -and $response.value.Count -gt 0) {
            Write-Host "##[debug]Found $($response.value.Count) existing schedule(s)"
            foreach ($sched in $response.value) {
                Write-Host "##[debug]Schedule ID: $($sched.id), Enabled: $($sched.enabled)"
            }
            return $response.value
        }
        else {
            Write-Host "##[debug]No schedules returned in response"
            return @()
        }
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Host "##[debug]Error status code: $statusCode"
        
        # Only 404 means no schedules exist - return empty array
        if ($statusCode -eq 404) {
            Write-Host "##[debug]No existing schedules found for item $itemId (404 - Not Found)"
            return @()
        }
        
        # For 400 or any other error, this is a real problem - don't pretend no schedules exist
        Write-Host "##[error]Failed to get existing schedules for item $itemId"
        Write-Host "##[error]Status Code: $statusCode"
        Write-Host "##[error]This may indicate an API issue or incorrect request format"
        Write-Host "##[error]Will skip schedule deployment for this pipeline to avoid creating duplicates"
        throw "Cannot retrieve existing schedules - aborting to prevent duplicate creation"
    }
}

function New-PipelineSchedule {
    <#
    .SYNOPSIS
        Creates a new schedule for a pipeline
    #>
    param (
        [string]$token,
        [string]$workspaceId,
        [string]$itemId,
        [object]$schedule
    )
    
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
    
    # Data Pipeline schedules use the execute schedules endpoint
    $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/dataPipelines/$itemId/jobs/execute/schedules"
    
    # Transform .schedules format to API configuration format
    $configuration = @{
        localTimeZoneId = $schedule.recurrence.timeZone
    }
    
    # Add startDateTime (required) - if provided in schedule, otherwise use current time in UTC
    if ($schedule.recurrence.startTime) {
        $configuration.startDateTime = $schedule.recurrence.startTime
    } else {
        # Use current time in UTC as default start time
        $configuration.startDateTime = (Get-Date).AddDays(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    
    # Add endDateTime (required) - if provided, otherwise use 10 years from now
    if ($schedule.recurrence.endTime) {
        $configuration.endDateTime = $schedule.recurrence.endTime
    } else {
        # Use 10 years from now as default end time (maximum allowed by API is 5270400 minutes)
        $configuration.endDateTime = (Get-Date).AddYears(10).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    
    # Map frequency to type
    if ($schedule.recurrence.frequency -eq "Week") {
        $configuration.type = "Weekly"
        $configuration.weekdays = $schedule.recurrence.schedule.weekDays
        
        # Convert hours and minutes to "HH:mm" time strings
        $times = @()
        foreach ($hour in $schedule.recurrence.schedule.hours) {
            foreach ($minute in $schedule.recurrence.schedule.minutes) {
                $times += "{0:D2}:{1:D2}" -f $hour, $minute
            }
        }
        $configuration.times = $times
    }
    elseif ($schedule.recurrence.frequency -eq "Day") {
        $configuration.type = "Daily"
        
        # Convert hours and minutes to "HH:mm" time strings
        $times = @()
        foreach ($hour in $schedule.recurrence.schedule.hours) {
            foreach ($minute in $schedule.recurrence.schedule.minutes) {
                $times += "{0:D2}:{1:D2}" -f $hour, $minute
            }
        }
        $configuration.times = $times
    }
    else {
        Write-Warning "Unsupported schedule frequency: $($schedule.recurrence.frequency). Only Week and Day are supported."
        throw "Unsupported schedule frequency"
    }
    
    $body = @{
        enabled = $schedule.enabled
        configuration = $configuration
    }
    
    $bodyJson = ConvertTo-Json -InputObject $body -Depth 10
    
    try {
        Write-Host "##[debug]Creating schedule for item $itemId"
        Write-Host "##[debug]URI: $uri"
        Write-Host "##[debug]Body: $bodyJson"
        
        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method Post `
            -Headers $headers `
            -Body $bodyJson
            
        Write-Host "##[section]Schedule created successfully with ID: $($response.id)"
        return $response
    }
    catch {
        Write-Host "##[error]Failed to create schedule for item $itemId"
        
        # Capture status code if available
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
            Write-Host "##[error]HTTP Status Code: $statusCode"
            Write-Host "##[error]HTTP Status Description: $($_.Exception.Response.StatusDescription)"
            
            # Try to read the response body for detailed error message
            try {
                $responseStream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($responseStream)
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
                $responseStream.Close()
                
                Write-Host "##[error]API Response Body: $responseBody"
                
                # Try to parse as JSON
                try {
                    $apiError = $responseBody | ConvertFrom-Json
                    if ($apiError.errorCode) {
                        Write-Host "##[error]API Error Code: $($apiError.errorCode)"
                    }
                    if ($apiError.message) {
                        Write-Host "##[error]API Error Message: $($apiError.message)"
                    }
                }
                catch {
                    # Not JSON, already logged as raw response body
                }
            }
            catch {
                Write-Host "##[debug]Could not read response body: $($_.Exception.Message)"
            }
        }
        
        # Capture error message
        Write-Host "##[error]Exception Message: $($_.Exception.Message)"
        
        # Capture API error details if available
        if ($_.ErrorDetails.Message) {
            Write-Host "##[error]API Error Details: $($_.ErrorDetails.Message)"
            try {
                $apiError = $_.ErrorDetails.Message | ConvertFrom-Json
                Write-Host "##[error]API Error Code: $($apiError.error.code)"
                Write-Host "##[error]API Error Message: $($apiError.error.message)"
            }
            catch {
                # If JSON parsing fails, just show raw message
                Write-Host "##[error]Raw API Error: $($_.ErrorDetails.Message)"
            }
        }
        
        # Show full error for debugging
        Write-Host "##[debug]Full Error Object: $($_ | ConvertTo-Json -Depth 3)"
        
        throw "Failed to create schedule for item $itemId. See error details above."
    }
}

function Update-PipelineSchedule {
    <#
    .SYNOPSIS
        Updates an existing schedule for a pipeline
    #>
    param (
        [string]$token,
        [string]$workspaceId,
        [string]$itemId,
        [string]$scheduleId,
        [object]$schedule
    )
    
    # Validate schedule ID at runtime instead of parameter validation
    if ([string]::IsNullOrWhiteSpace($scheduleId)) {
        $errorMsg = "Schedule ID cannot be null or empty for item $itemId"
        Write-Error $errorMsg
        throw $errorMsg
    }
    
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
    
    # Data Pipeline schedules use the execute schedules endpoint
    $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/dataPipelines/$itemId/jobs/execute/schedules/$scheduleId"
    
    # Transform .schedules format to API configuration format
    $configuration = @{
        localTimeZoneId = $schedule.recurrence.timeZone
    }
    
    # Add startDateTime (required) - if provided in schedule, otherwise use current time in UTC
    if ($schedule.recurrence.startTime) {
        $configuration.startDateTime = $schedule.recurrence.startTime
    } else {
        # Use current time in UTC as default start time
        $configuration.startDateTime = (Get-Date).AddDays(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    
    # Add endDateTime (required) - if provided, otherwise use 10 years from now
    if ($schedule.recurrence.endTime) {
        $configuration.endDateTime = $schedule.recurrence.endTime
    } else {
        # Use 10 years from now as default end time (maximum allowed by API is 5270400 minutes)
        $configuration.endDateTime = (Get-Date).AddYears(10).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    
    # Map frequency to type
    if ($schedule.recurrence.frequency -eq "Week") {
        $configuration.type = "Weekly"
        $configuration.weekdays = $schedule.recurrence.schedule.weekDays
        
        # Convert hours and minutes to "HH:mm" time strings
        $times = @()
        foreach ($hour in $schedule.recurrence.schedule.hours) {
            foreach ($minute in $schedule.recurrence.schedule.minutes) {
                $times += "{0:D2}:{1:D2}" -f $hour, $minute
            }
        }
        $configuration.times = $times
    }
    elseif ($schedule.recurrence.frequency -eq "Day") {
        $configuration.type = "Daily"
        
        # Convert hours and minutes to "HH:mm" time strings
        $times = @()
        foreach ($hour in $schedule.recurrence.schedule.hours) {
            foreach ($minute in $schedule.recurrence.schedule.minutes) {
                $times += "{0:D2}:{1:D2}" -f $hour, $minute
            }
        }
        $configuration.times = $times
    }
    else {
        Write-Warning "Unsupported schedule frequency: $($schedule.recurrence.frequency). Only Week and Day are supported."
        throw "Unsupported schedule frequency"
    }
    
    $body = @{
        enabled = $schedule.enabled
        configuration = $configuration
    }
    
    $bodyJson = ConvertTo-Json -InputObject $body -Depth 10
    
    try {
        Write-Host "##[debug]Updating schedule $scheduleId for item $itemId"
        Write-Host "##[debug]URI: $uri"
        Write-Host "##[debug]Body: $bodyJson"
        
        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method Patch `
            -Headers $headers `
            -Body $bodyJson
            
        Write-Host "##[section]Schedule updated successfully"
        return $response
    }
    catch {
        Write-Host "##[error]Failed to update schedule $scheduleId for item $itemId"
        
        # Capture status code if available
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
            Write-Host "##[error]HTTP Status Code: $statusCode"
            Write-Host "##[error]HTTP Status Description: $($_.Exception.Response.StatusDescription)"
            
            # Try to read the response body for detailed error message
            try {
                $responseStream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($responseStream)
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
                $responseStream.Close()
                
                Write-Host "##[error]API Response Body: $responseBody"
                
                # Try to parse as JSON
                try {
                    $apiError = $responseBody | ConvertFrom-Json
                    if ($apiError.errorCode) {
                        Write-Host "##[error]API Error Code: $($apiError.errorCode)"
                    }
                    if ($apiError.message) {
                        Write-Host "##[error]API Error Message: $($apiError.message)"
                    }
                }
                catch {
                    # Not JSON, already logged as raw response body
                }
            }
            catch {
                Write-Host "##[debug]Could not read response body: $($_.Exception.Message)"
            }
        }
        
        # Capture error message
        Write-Host "##[error]Exception Message: $($_.Exception.Message)"
        
        # Capture API error details if available
        if ($_.ErrorDetails.Message) {
            Write-Host "##[error]API Error Details: $($_.ErrorDetails.Message)"
            try {
                $apiError = $_.ErrorDetails.Message | ConvertFrom-Json
                Write-Host "##[error]API Error Code: $($apiError.error.code)"
                Write-Host "##[error]API Error Message: $($apiError.error.message)"
            }
            catch {
                # If JSON parsing fails, just show raw message
                Write-Host "##[error]Raw API Error: $($_.ErrorDetails.Message)"
            }
        }
        
        # Show full error for debugging
        Write-Host "##[debug]Full Error Object: $($_ | ConvertTo-Json -Depth 3)"
        
        throw "Failed to update schedule $scheduleId for item $itemId. See error details above."
    }
}

function Deploy-PipelineSchedules {
    <#
    .SYNOPSIS
        Main function to deploy all pipeline schedules
    #>
    param (
        [string]$token,
        [string]$workspaceId,
        [array]$createdPipelines
    )
    
    Write-Host "##[section]Starting Pipeline Schedule Deployment"
    
    # Get all .schedules files
    $scheduleFiles = Get-PipelineSchedules
    
    if ($scheduleFiles.Count -eq 0) {
        Write-Host "##[debug]No .schedules files found. Skipping schedule deployment."
        return
    }
    
    foreach ($scheduleFile in $scheduleFiles) {
        Write-Host "##[section]Processing schedules for pipeline: $($scheduleFile.pipelineName)"
        
        # Validate schedule file has required properties
        if (-not $scheduleFile.pipelineName) {
            Write-Warning "Schedule file missing pipeline name. Skipping."
            continue
        }
        
        if (-not $scheduleFile.schedules -or $scheduleFile.schedules.Count -eq 0) {
            Write-Warning "No schedules defined in .schedules file for: $($scheduleFile.pipelineName)"
            continue
        }
        
        # Find the corresponding created pipeline
        $pipeline = $createdPipelines | Where-Object { $_.displayName -eq $scheduleFile.pipelineName }
        
        if (-not $pipeline) {
            Write-Warning "Pipeline '$($scheduleFile.pipelineName)' not found in created pipelines. Skipping schedule deployment."
            Write-Host "##[debug]Available pipelines: $($createdPipelines.displayName -join ', ')"
            continue
        }
        
        # Handle case where multiple pipelines have the same name (should not happen, but be defensive)
        if ($pipeline -is [array]) {
            Write-Warning "Multiple pipelines found with name '$($scheduleFile.pipelineName)'. Using the first one."
            Write-Host "##[debug]Found $($pipeline.Count) pipelines with matching name"
            $pipeline = $pipeline[0]
        }
        
        $itemId = $pipeline.id
        
        if ([string]::IsNullOrWhiteSpace($itemId)) {
            Write-Warning "Pipeline '$($scheduleFile.pipelineName)' has no ID. Skipping schedule deployment."
            continue
        }
        
        Write-Host "##[debug]Pipeline ID: $itemId"
        
        # Get existing schedules - this will throw if API returns non-404 error
        try {
            $existingSchedules = Get-ExistingSchedules -token $token -workspaceId $workspaceId -itemId $itemId
        }
        catch {
            Write-Host "##[error]Cannot retrieve existing schedules for pipeline '$($scheduleFile.pipelineName)'"
            Write-Host "##[error]Skipping schedule deployment for this pipeline to avoid creating duplicates"
            Write-Host "##[error]Error: $($_.Exception.Message)"
            continue
        }
        
        # Warn if multiple schedules already exist (duplicates)
        if ($existingSchedules -and $existingSchedules.Count -gt 1) {
            Write-Host "##[warning]=================================================="
            Write-Host "##[warning]Found $($existingSchedules.Count) existing schedules for pipeline '$($scheduleFile.pipelineName)'"
            Write-Host "##[warning]This may indicate duplicate schedules were created previously"
            Write-Host "##[warning]Only the FIRST schedule will be updated"
            Write-Host "##[warning]To clean up duplicates, manually delete extra schedules in Fabric UI:"
            Write-Host "##[warning]  1. Open the Data Pipeline in Fabric"
            Write-Host "##[warning]  2. Go to Settings > Schedule"
            Write-Host "##[warning]  3. Delete duplicate schedules"
            Write-Host "##[warning]=================================================="
            
            # List all schedule IDs for reference
            foreach ($sched in $existingSchedules) {
                $schedId = if ($sched.id) { $sched.id } else { $sched.scheduleId }
                Write-Host "##[debug]  - Schedule ID: $schedId, Enabled: $($sched.enabled)"
            }
        }
        
        # Process each schedule in the .schedules file
        foreach ($schedule in $scheduleFile.schedules) {
            Write-Host "##[debug]Processing schedule: $($schedule.description)"
            
            # Check if we have valid existing schedules with IDs
            $shouldUpdate = $false
            $existingScheduleId = $null
            
            if ($existingSchedules -and $existingSchedules.Count -gt 0) {
                $firstSchedule = $existingSchedules[0]
                
                # Try to get the schedule ID from various possible properties
                if (-not [string]::IsNullOrWhiteSpace($firstSchedule.id)) {
                    $existingScheduleId = $firstSchedule.id
                    $shouldUpdate = $true
                }
                elseif (-not [string]::IsNullOrWhiteSpace($firstSchedule.scheduleId)) {
                    $existingScheduleId = $firstSchedule.scheduleId
                    $shouldUpdate = $true
                }
                
                if ($shouldUpdate) {
                    Write-Host "##[debug]Found existing schedule with valid ID: $existingScheduleId"
                }
                else {
                    Write-Host "##[debug]Existing schedule found but has no valid ID property"
                }
            }
            else {
                Write-Host "##[debug]No existing schedules found"
            }
            
            # If there are existing schedules, update the first one
            # If there are multiple schedules (duplicates), we update only the first one
            # Manual cleanup of duplicates should be done in Fabric UI if needed
            if ($shouldUpdate -and -not [string]::IsNullOrWhiteSpace($existingScheduleId)) {
                Write-Host "##[debug]Updating existing schedule: $existingScheduleId"
                Write-Host "##[debug]Note: If multiple schedules exist, only the first will be updated"
                
                Update-PipelineSchedule `
                    -token $token `
                    -workspaceId $workspaceId `
                    -itemId $itemId `
                    -scheduleId $existingScheduleId `
                    -schedule $schedule
                    
                Write-Host "##[section]Schedule updated successfully"
            }
            else {
                # Only create if NO schedules exist
                Write-Host "##[debug]No existing schedules found - creating new schedule"
                
                New-PipelineSchedule `
                    -token $token `
                    -workspaceId $workspaceId `
                    -itemId $itemId `
                    -schedule $schedule
            }
        }
    }
    
    Write-Host "##[section]Pipeline schedule deployment completed"
}

# Main execution
try {
    $token = $env:FABRIC_TOKEN
    $workspaceIds = ConvertFrom-Json -InputObject $env:WORKSPACE_IDS
    $workspaceId = $workspaceIds.PSObject.Properties.Value
    
    # This should be passed from the Setup-FabricDataPipelines.ps1 script
    # as it contains the pipeline IDs
    $createdPipelinesJson = $env:CREATED_PIPELINES
    if ($createdPipelinesJson) {
        $createdPipelines = ConvertFrom-Json -InputObject $createdPipelinesJson
        
        Write-Host "##[debug]Found $($createdPipelines.Count) created pipeline(s)"
        
        Deploy-PipelineSchedules `
            -token $token `
            -workspaceId $workspaceId `
            -createdPipelines $createdPipelines
            
        Write-Host "##[section]All schedules processed successfully"
    }
    else {
        Write-Warning "CREATED_PIPELINES environment variable not set. Cannot deploy schedules without pipeline IDs."
        Write-Host "##[section]Skipping schedule deployment - this is normal on first deployment"
        # Don't throw - this is expected on first run
    }
}
catch {
    # Log the error but don't fail the entire deployment
    Write-Warning "##[warning]Schedule deployment failed: $_"
    Write-Host "##[debug]Error details: $($_.Exception.Message)"
    Write-Host "##[debug]Stack trace: $($_.ScriptStackTrace)"
    Write-Host "##[section]Schedules were not deployed but pipelines are ready"
    Write-Host "##[section]You can add schedules manually in the Fabric portal or fix the error and redeploy"
    
    # Exit with success code so pipeline deployment isn't marked as failed
    exit 0
}
