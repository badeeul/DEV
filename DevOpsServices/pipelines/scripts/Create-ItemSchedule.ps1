param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $true)]
    [string]$ItemId,

    [Parameter(Mandatory = $false)]
    [string]$JobType = 'DefaultJob',

    [Parameter(Mandatory = $true)]
    [string]$ScheduleJson
)

function Invoke-FabricApiWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method,
        [string]$Body = $null,
        [int]$MaxRetries = 3,
        [int]$BaseRetryDelaySeconds = 10
    )

    $attempt = 1
    while ($attempt -le $MaxRetries) {
        try {
            $requestParams = @{
                Uri     = $Uri
                Headers = $Headers
                Method  = $Method
            }
            if (-not [string]::IsNullOrEmpty($Body)) { $requestParams.Body = $Body }

            $response = Invoke-RestMethod @requestParams
            return $response
        }
        catch {
            $errorResponse = $null
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $errorResponse = $reader.ReadToEnd()
                    $reader.Close()
                }
                catch {}
            }

            if ($attempt -eq $MaxRetries) {
                Write-Error "API call to $Uri failed after $MaxRetries attempts. Last error: $_"
                if ($errorResponse) { Write-Error "Response body: $errorResponse" }
                throw $_
            }

            $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Warning "API call failed (attempt $attempt), retrying in $retryDelay seconds. Error: $_"
            Start-Sleep -Seconds $retryDelay
            $attempt++
        }
    }
}

function Get-ExistingSchedules {
    param(
        [string]$WorkspaceId,
        [string]$ItemId,
        [string]$JobType,
        [string]$Token
    )
    Write-Host "Checking for existing schedules for item $ItemId in workspace $WorkspaceId and job type $JobType"

    $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$ItemId/jobs/$JobType/schedules"
    $headers = @{ "Authorization" = "Bearer $Token"; "Content-Type" = "application/json" }
    try {
        $resp = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 3
        return $resp
    }
    catch {
        Write-Warning "Failed to list existing schedules: $_"
        return $null
    }
}

function Get-ItemJobInstances {
    param(
        [string]$WorkspaceId,
        [string]$ItemId,
        [string]$JobType,
        [string]$Token
    )
    Write-Host "Getting job instances for item $ItemId in workspace $WorkspaceId and job type $JobType"
    $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$ItemId/jobs/instances"
    $headers = @{ "Authorization" = "Bearer $Token"; "Content-Type" = "application/json" }
    try {
        $resp = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 3
        $resp.value | ConvertTo-Json -Depth 10
        return $resp
    }
    catch {
        Write-Warning "Failed to get job instances: $_"
        return $null
    }
}

Function Remove-ExistingSchedule {
    param(
        [string]$WorkspaceId,
        [string]$ItemId,
        [string]$JobType,
        [string]$ScheduleId,
        [string]$Token
    )

    $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$ItemId/jobs/$JobType/schedules/$ScheduleId"
    $headers = @{ "Authorization" = "Bearer $Token"; "Content-Type" = "application/json" }
    try {
        Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method DELETE -MaxRetries 3
        Write-Host "Deleted existing schedule with id: $ScheduleId from workspace: $WorkspaceId, item: $ItemId, job type: $JobType"
    }
    catch {
        Write-Warning "Failed to delete existing schedule with id ${ScheduleId} from workspace: $WorkspaceId, item: $ItemId, job type: $JobType. Error: $_"
    }
}

Function Create-ItemSchedule {
    param(
        [string]$WorkspaceId,
        [string]$ItemId,
        [string]$JobType,
        [string]$ScheduleJson,
        [string]$Token
    )

    $headers = @{ "Authorization" = "Bearer $Token"; "Content-Type" = "application/json" }

    $scheduleObj = $null
    try { $scheduleObj = $ScheduleJson | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Error "Schedule file does not contain valid JSON: $_"; exit 1 }

    if ($null -eq $scheduleObj) { Write-Error "Parsed schedule is null"; exit 1 }

    $apiBase = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$ItemId/jobs/$JobType/schedules"

    Write-Host "Creating schedule for item $ItemId in workspace $WorkspaceId"
    $bodyCreate = ($scheduleObj | ConvertTo-Json -Depth 20)
    $createResp = Invoke-FabricApiWithRetry -Uri $apiBase -Headers $headers -Method POST -Body $bodyCreate -MaxRetries 5
    return $createResp
}

# Main
try {
    
    $token = $env:FABRIC_TOKEN
    
    if ($null -eq $token) {
        Write-Error "FABRIC_TOKEN environment variable is not set. Cannot authenticate API requests without a token."
        exit 1
    }
    
    $existingSchedules = Get-ExistingSchedules -WorkspaceId $WorkspaceId -ItemId $ItemId -JobType $JobType -Token $token
    if ($existingSchedules -and $existingSchedules.value) {
        foreach ($sched in $existingSchedules.value) {
            Remove-ExistingSchedule -WorkspaceId $WorkspaceId -ItemId $ItemId -JobType $JobType -ScheduleId $sched.id -Token $token
        }
    }

    try { $scheduleObj = $ScheduleJson | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Error "Schedule JSON does not contain valid JSON: $_"; exit 1 }

    if ($null -eq $scheduleObj) { Write-Error "Parsed schedule is null"; exit 1 }

    foreach ($sched in $scheduleObj.Schedules) {
        $result = Create-ItemSchedule -WorkspaceId $WorkspaceId -ItemId $ItemId -JobType $JobType -ScheduleJson ($sched | ConvertTo-Json -Depth 20) -Token $token
        Write-Host "Operation completed. Result:"
        Write-Host ($result | ConvertTo-Json -Depth 10 -Compress)
    }

}
catch {
    Write-Error "Failed to create/update schedule: $_"
    exit 1
}