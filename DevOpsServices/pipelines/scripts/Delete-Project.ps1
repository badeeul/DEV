param(
    [Parameter(Mandatory=$true)]
    [string]$OrganizationUrl,
   
    [Parameter(Mandatory=$true)]
    [string]$ClientId,
   
    [Parameter(Mandatory=$true)]
    [string]$ClientSecret,
   
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
   
    [Parameter(Mandatory=$true)]
    [string]$ProjectName,
   
    [Parameter(Mandatory=$false)]
    [bool]$WaitForCompletion = $true,
   
    [Parameter(Mandatory=$false)]
    [int]$MaxWaitMinutes = 10,
   
    [Parameter(Mandatory=$false)]
    [int]$MaxRetries = 3,
   
    [Parameter(Mandatory=$false)]
    [int]$BaseRetryDelaySeconds = 5
)

#region Global Variables

$script:accessToken = $null
$script:headers = $null
$script:apiVersion = "7.1"

#endregion

#region Helper Functions

function Write-Section {
    param([string]$Title)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Get-AzureAdAccessToken {
    param(
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$TenantId,
        [int]$MaxRetries = 3
    )
   
    $attempt = 1
   
    while ($attempt -le $MaxRetries) {
        try {
            Write-Host "##[debug]Acquiring Azure AD access token (Attempt $attempt of $MaxRetries)"
           
            # Azure DevOps resource ID
            $resource = "499b84ac-1321-427f-aa17-267ca6975798"
           
            $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/token"
           
            $body = @{
                grant_type    = "client_credentials"
                client_id     = $ClientId
                client_secret = $ClientSecret
                resource      = $resource
            }
           
            $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
           
            Write-Host "##[command]Successfully acquired access token"
            return $response.access_token
        }
        catch {
            if ($attempt -eq $MaxRetries) {
                Write-Error "Failed to acquire access token after $MaxRetries attempts"
                throw "Failed to authenticate with Azure AD: $_"
            }
           
            $retryDelay = 5 * [math]::Pow(2, $attempt - 1)
            Write-Host "##[debug]Waiting $retryDelay seconds before retry..."
            Start-Sleep -Seconds $retryDelay
            $attempt++
        }
    }
}

function Initialize-Headers {
    param([string]$AccessToken)
   
    $script:headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }
}

function Invoke-AzDoApiWithRetry {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [int]$MaxRetries = 3,
        [int]$BaseRetryDelaySeconds = 5
    )
   
    $attempt = 1
   
    while ($attempt -le $MaxRetries) {
        try {
            Write-Host "##[debug]API call attempt $attempt of $MaxRetries"
           
            if ($attempt -gt 1) {
                $script:accessToken = Get-AzureAdAccessToken -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId -MaxRetries 2
                Initialize-Headers -AccessToken $script:accessToken
            }
           
            $requestParams = @{
                Uri = $Uri
                Headers = $script:headers
                Method = $Method
            }
           
            if (-not [string]::IsNullOrEmpty($Body)) {
                $requestParams.Body = $Body
            }
           
            $response = Invoke-RestMethod @requestParams
            Write-Host "##[debug]API call successful"
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
                catch {
                    Write-Host "##[debug]Could not read error response body"
                }
            }
           
            if ($attempt -eq $MaxRetries) {
                Write-Error "API call failed after $MaxRetries attempts. Last error: $_"
                if ($errorResponse) {
                    Write-Error "Response body: $errorResponse"
                }
                throw
            }
           
            $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Host "##[warning]API call failed (attempt $attempt), retrying in $retryDelay seconds"
            Start-Sleep -Seconds $retryDelay
            $attempt++
        }
    }
}

function Get-ProjectByName {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName
    )
   
    try {
        Write-Host "##[debug]Looking up project: $ProjectName"
       
        $listUri = "$OrganizationUrl/_apis/projects?api-version=$script:apiVersion"
        $projectsList = Invoke-AzDoApiWithRetry -Uri $listUri -Method GET
       
        $project = $projectsList.value | Where-Object { $_.name -eq $ProjectName }
       
        if ($project) {
            Write-Host "##[debug]Found project ID: $($project.id)"
            return $project
        }
        else {
            throw "Project '$ProjectName' not found in organization"
        }
    }
    catch {
        Write-Error "Failed to get project: $_"
        throw
    }
}

function Remove-AzDoProject {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId
    )
   
    try {
        Write-Host "##[debug]Initiating project deletion..."
       
        # Build the DELETE API URI
        $deleteUri = "$OrganizationUrl/_apis/projects/$ProjectId`?api-version=$script:apiVersion"
       
        Write-Host "##[debug]DELETE URI: $deleteUri"
       
        # Make the DELETE API call
        $operation = Invoke-AzDoApiWithRetry -Uri $deleteUri -Method DELETE
       
        Write-Host "##[command]Project deletion initiated" -ForegroundColor Yellow
        Write-Host "##[debug]Operation ID: $($operation.id)"
        Write-Host "##[debug]Operation Status: $($operation.status)"
        Write-Host "##[debug]Operation URL: $($operation.url)"
       
        return $operation
    }
    catch {
        Write-Error "Failed to delete project: $_"
        throw
    }
}

function Get-OperationStatus {
    param(
        [string]$OperationUrl
    )
   
    try {
        Write-Host "##[debug]Checking operation status..."
       
        # Make the GET API call to operation URL
        $operation = Invoke-AzDoApiWithRetry -Uri $OperationUrl -Method GET
       
        Write-Host "##[debug]Operation Status: $($operation.status)"
       
        return $operation
    }
    catch {
        Write-Warning "Could not get operation status: $_"
        return $null
    }
}

function Wait-ForOperationCompletion {
    param(
        [string]$OperationUrl,
        [int]$MaxWaitMinutes = 10
    )
   
    try {
        Write-Host "##[command]Waiting for deletion operation to complete..." -ForegroundColor Cyan
        Write-Host "##[debug]Maximum wait time: $MaxWaitMinutes minutes"
       
        $startTime = Get-Date
        $endTime = $startTime.AddMinutes($MaxWaitMinutes)
        $pollIntervalSeconds = 5
       
        while ((Get-Date) -lt $endTime) {
            $operation = Get-OperationStatus -OperationUrl $OperationUrl
           
            if (-not $operation) {
                Write-Warning "Could not retrieve operation status, continuing to wait..."
                Start-Sleep -Seconds $pollIntervalSeconds
                continue
            }
           
            $elapsedMinutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 2)
           
            switch ($operation.status) {
                "notSet" {
                    Write-Host "##[debug][$elapsedMinutes min] Status: Not Set - Waiting..."
                }
                "queued" {
                    Write-Host "##[debug][$elapsedMinutes min] Status: Queued - Waiting for processing..."
                }
                "inProgress" {
                    Write-Host "##[debug][$elapsedMinutes min] Status: In Progress - Deleting project..."
                }
                "succeeded" {
                    Write-Host "##[command]Operation completed successfully!" -ForegroundColor Green
                    Write-Host "##[debug]Total time: $elapsedMinutes minutes"
                    return @{
                        status = "succeeded"
                        operation = $operation
                    }
                }
                "cancelled" {
                    Write-Warning "Operation was cancelled"
                    return @{
                        status = "cancelled"
                        operation = $operation
                    }
                }
                "failed" {
                    Write-Error "Operation failed"
                    return @{
                        status = "failed"
                        operation = $operation
                    }
                }
                default {
                    Write-Host "##[debug][$elapsedMinutes min] Status: $($operation.status)"
                }
            }
           
            Start-Sleep -Seconds $pollIntervalSeconds
        }
       
        Write-Warning "Operation did not complete within $MaxWaitMinutes minutes"
        return @{
            status = "timeout"
            operation = $operation
        }
    }
    catch {
        Write-Error "Error while waiting for operation completion: $_"
        throw
    }
}

#endregion

#region Main Execution

try {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "Delete Azure DevOps Project" -ForegroundColor Red
    Write-Host "WARNING: THIS OPERATION CANNOT BE UNDONE!" -ForegroundColor Red
    Write-Host "========================================`n" -ForegroundColor Red
   
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host "  Organization URL: $OrganizationUrl"
    Write-Host "  Project Name:     $ProjectName"
    Write-Host "  Wait for Completion: $WaitForCompletion"
    if ($WaitForCompletion) {
        Write-Host "  Max Wait Time:    $MaxWaitMinutes minutes"
    }
    Write-Host ""
   
    # Step 0: Authenticate
    Write-Section "Step 0: Authenticating with Azure AD"
   
    $script:accessToken = Get-AzureAdAccessToken -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId -MaxRetries $MaxRetries
    Initialize-Headers -AccessToken $script:accessToken
   
    Write-Host "##[command]Authentication successful" -ForegroundColor Green
   
    # Step 1: Get Project
    Write-Section "Step 1: Getting Project Information"
   
    $project = Get-ProjectByName -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
   
    Write-Host "##[command]Project found: $($project.name)" -ForegroundColor Green
    Write-Host "##[debug]Project ID: $($project.id)"
    Write-Host "##[debug]Project State: $($project.state)"
    Write-Host "##[debug]Project Visibility: $($project.visibility)"
   
    # Step 2: Confirm Deletion (in pipeline, this is implicit)
    Write-Section "Step 2: Initiating Project Deletion"
   
    Write-Host "##[warning]Deleting project: $($project.name)" -ForegroundColor Yellow
    Write-Host "##[warning]Project ID: $($project.id)" -ForegroundColor Yellow
   
    $operation = Remove-AzDoProject -OrganizationUrl $OrganizationUrl -ProjectId $project.id
   
    Write-Host "##[command]Deletion operation initiated" -ForegroundColor Yellow
    Write-Host "##[debug]Operation ID: $($operation.id)"
    Write-Host "##[debug]Initial Status: $($operation.status)"
   
    # Step 3: Wait for Completion (if requested)
    if ($WaitForCompletion) {
        Write-Section "Step 3: Waiting for Deletion to Complete"
       
        $result = Wait-ForOperationCompletion -OperationUrl $operation.url -MaxWaitMinutes $MaxWaitMinutes
       
        # Summary
        Write-Host "`n========================================" -ForegroundColor Red
        Write-Host "Summary" -ForegroundColor Red
        Write-Host "========================================`n" -ForegroundColor Red
       
        Write-Host "Project: $($project.name)" -ForegroundColor Cyan
        Write-Host "Operation ID: $($operation.id)" -ForegroundColor Cyan
        Write-Host "Final Status: $($result.status)" -ForegroundColor $(
            switch ($result.status) {
                "succeeded" { "Green" }
                "failed" { "Red" }
                "cancelled" { "Yellow" }
                "timeout" { "Yellow" }
                default { "White" }
            }
        )
       
        if ($result.status -eq "succeeded") {
            Write-Host "`n Project deleted successfully" -ForegroundColor Green
        }
        elseif ($result.status -eq "timeout") {
            Write-Warning "Operation did not complete within the timeout period"
            Write-Host "Check operation status manually at: $($operation.url)" -ForegroundColor Yellow
            exit 1
        }
        else {
            Write-Error "Project deletion failed"
            exit 1
        }
    }
    else {
        # Summary without waiting
        Write-Host "`n========================================" -ForegroundColor Yellow
        Write-Host "Summary" -ForegroundColor Yellow
        Write-Host "========================================`n" -ForegroundColor Yellow
       
        Write-Host "Project: $($project.name)" -ForegroundColor Cyan
        Write-Host "Operation ID: $($operation.id)" -ForegroundColor Cyan
        Write-Host "Status: Deletion initiated (not waiting for completion)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Check operation status at:" -ForegroundColor Cyan
        Write-Host "  $($operation.url)" -ForegroundColor Yellow
    }
}
catch {
    Write-Error "##[error]Failed to delete project: $_"
    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Verify Service Principal has Project Delete permissions" -ForegroundColor White
    Write-Host "  2. Check that project name is correct" -ForegroundColor White
    Write-Host "  3. Ensure project exists and is not already being deleted" -ForegroundColor White
    Write-Host "  4. Verify Service Principal is Project Collection Administrator" -ForegroundColor White
    Write-Host ""
    exit 1
}
