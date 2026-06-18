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
   
    [Parameter(Mandatory=$true)]
    [string]$AgentPoolNames,
   
    [Parameter(Mandatory=$false)]
    [bool]$GrantAccessToAllPipelines = $true,
   
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

function Get-OrganizationAgentPools {
    param(
        [string]$OrganizationUrl,
        [string[]]$PoolNames
    )
   
    try {
        Write-Host "##[debug]Getting organization-level agent pools..."
       
        # Get all agent pools at organization level
        $poolsUri = "$OrganizationUrl/_apis/distributedtask/pools?api-version=$script:apiVersion"
        $pools = Invoke-AzDoApiWithRetry -Uri $poolsUri -Method GET
       
        Write-Host "##[debug]Found $($pools.value.Count) total agent pool(s) at organization level"
       
        $foundPools = @()
       
        foreach ($poolName in $PoolNames) {
            $trimmedName = $poolName.Trim()
           
            if ([string]::IsNullOrEmpty($trimmedName)) {
                continue
            }
           
            # Find pool by name
            $matchedPool = $pools.value | Where-Object { $_.name -eq $trimmedName }
           
            if ($matchedPool) {
                if ($matchedPool -is [array]) {
                    Write-Warning "Multiple pools matched '$trimmedName', using: $($matchedPool[0].name)"
                    $matchedPool = $matchedPool[0]
                }
               
                Write-Host "##[command]Found agent pool: $trimmedName" -ForegroundColor Green
                Write-Host "##[debug]  Pool ID: $($matchedPool.id)"
                Write-Host "##[debug]  Pool Type: $($matchedPool.poolType)"
                Write-Host "##[debug]  Is Hosted: $($matchedPool.isHosted)"
                Write-Host "##[debug]  Size: $($matchedPool.size)"
               
                $foundPools += $matchedPool
            }
            else {
                Write-Warning "Agent pool not found at organization level: $trimmedName"
            }
        }
       
        return $foundPools
    }
    catch {
        Write-Error "Failed to get organization agent pools: $_"
        throw
    }
}

function Get-ProjectAgentQueues {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId
    )
   
    try {
        Write-Host "##[debug]Getting project-level agent queues..."
       
        # Get all agent queues (pools) at project level
        $queuesUri = "$OrganizationUrl/$ProjectId/_apis/distributedtask/queues?api-version=$script:apiVersion"
        $queues = Invoke-AzDoApiWithRetry -Uri $queuesUri -Method GET
       
        Write-Host "##[debug]Found $($queues.value.Count) agent queue(s) in project"
       
        return $queues.value
    }
    catch {
        Write-Error "Failed to get project agent queues: $_"
        throw
    }
}

function Test-PoolInProject {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [int]$PoolId
    )
   
    try {
        $queues = Get-ProjectAgentQueues -OrganizationUrl $OrganizationUrl -ProjectId $ProjectId
       
        $existingQueue = $queues | Where-Object { $_.pool.id -eq $PoolId }
       
        return $existingQueue
    }
    catch {
        return $null
    }
}

function Add-AgentPoolToProject {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [object]$AgentPool,
        [bool]$GrantAccessToAllPipelines
    )
   
    try {
        $poolName = $AgentPool.name
        Write-Host "##[command]Adding agent pool '$poolName' to project..." -ForegroundColor Cyan
       
        # Check if pool already exists in project
        $existingQueue = Test-PoolInProject -OrganizationUrl $OrganizationUrl -ProjectId $ProjectId -PoolId $AgentPool.id
       
        if ($existingQueue) {
            Write-Host "##[command]Agent pool '$poolName' already exists in project" -ForegroundColor Yellow
            Write-Host "##[debug]  Queue ID: $($existingQueue.id)"
            Write-Host "##[debug]  Queue Name: $($existingQueue.name)"
            return @{
                status = "existing"
                queue = $existingQueue
            }
        }
       
        # Add agent pool to project (create queue)
        $queuesUri = "$OrganizationUrl/$ProjectId/_apis/distributedtask/queues?api-version=$script:apiVersion"
       
        $body = @{
            name = $AgentPool.name
            pool = @{
                id = $AgentPool.id
            }
        }
       
        $bodyJson = $body | ConvertTo-Json -Depth 10
       
        Write-Host "##[debug]Request URI: $queuesUri"
        Write-Host "##[debug]Request body: $bodyJson"
       
        # Make the POST API call
        $queue = Invoke-AzDoApiWithRetry -Uri $queuesUri -Method POST -Body $bodyJson
       
        Write-Host "##[command]Successfully added agent pool '$poolName' to project" -ForegroundColor Green
        Write-Host "##[debug]Queue ID: $($queue.id)"
       
        # Grant access to all pipelines if requested
        if ($GrantAccessToAllPipelines) {
            Write-Host "##[debug]Granting access to all pipelines..."
            Grant-QueueAccessToAllPipelines -OrganizationUrl $OrganizationUrl -ProjectId $ProjectId -QueueId $queue.id
        }
       
        return @{
            status = "added"
            queue = $queue
        }
    }
    catch {
        Write-Error "Failed to add agent pool '$poolName' to project: $_"
        throw
    }
}

function Grant-QueueAccessToAllPipelines {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [int]$QueueId
    )
   
    try {
        Write-Host "##[debug]Granting queue access to all pipelines..."
       
        # Use pipeline permissions API
        $permissionsUri = "$OrganizationUrl/$ProjectId/_apis/pipelines/pipelinepermissions/queue/$QueueId`?api-version=7.1-preview.1"
       
        $body = @{
            allPipelines = @{
                authorized = $true
                authorizedBy = $null
                authorizedOn = $null
            }
        } | ConvertTo-Json -Depth 10
       
        Write-Host "##[debug]Permissions URI: $permissionsUri"
       
        # Make the PATCH API call
        $response = Invoke-AzDoApiWithRetry -Uri $permissionsUri -Method PATCH -Body $body
       
        Write-Host "##[command]Successfully granted access to all pipelines" -ForegroundColor Green
       
        return $response
    }
    catch {
        Write-Warning "Could not grant access to all pipelines (may require manual configuration): $_"
        return $null
    }
}

function Get-QueueDetails {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [int]$QueueId
    )
   
    try {
        Write-Host "##[debug]Getting queue details..."
       
        $queueUri = "$OrganizationUrl/$ProjectId/_apis/distributedtask/queues/$QueueId`?api-version=$script:apiVersion"
        $queue = Invoke-AzDoApiWithRetry -Uri $queueUri -Method GET
       
        return $queue
    }
    catch {
        Write-Warning "Could not get queue details: $_"
        return $null
    }
}

#endregion

#region Main Execution

try {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Add Agent Pools to Project" -ForegroundColor Green
    Write-Host "Using Service Principal Authentication" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    # Parse agent pool names
    $poolNames = $AgentPoolNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
   
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host "  Organization URL: $OrganizationUrl"
    Write-Host "  Project Name:     $ProjectName"
    Write-Host "  Agent Pools:      $($poolNames.Count) pool(s)"
    Write-Host "  Grant Access to All Pipelines: $GrantAccessToAllPipelines"
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
   
    # Step 2: Get Organization Agent Pools
    Write-Section "Step 2: Getting Organization Agent Pools"
   
    $agentPools = Get-OrganizationAgentPools -OrganizationUrl $OrganizationUrl -PoolNames $poolNames
   
    if ($agentPools.Count -eq 0) {
        throw "No agent pools found at organization level. Please verify the pool names."
    }
   
    Write-Host "##[command]Found $($agentPools.Count) agent pool(s) at organization level" -ForegroundColor Green
   
    # Step 3: Add Agent Pools to Project
    Write-Section "Step 3: Adding Agent Pools to Project"
   
    $poolsAdded = 0
    $poolsExisting = 0
    $poolsFailed = 0
    $poolResults = @{}
   
    foreach ($pool in $agentPools) {
        try {
            $result = Add-AgentPoolToProject `
                -OrganizationUrl $OrganizationUrl `
                -ProjectId $project.id `
                -AgentPool $pool `
                -GrantAccessToAllPipelines $GrantAccessToAllPipelines
           
            $poolResults[$pool.name] = $result
           
            if ($result.status -eq "added") {
                $poolsAdded++
            }
            elseif ($result.status -eq "existing") {
                $poolsExisting++
            }
        }
        catch {
            Write-Error "Failed to add pool '$($pool.name)': $_"
            $poolResults[$pool.name] = @{
                status = "failed"
                error = $_.Exception.Message
            }
            $poolsFailed++
        }
    }
   
    # Step 4: Verify Agent Pools
    Write-Section "Step 4: Verifying Agent Pools in Project"
   
    $projectQueues = Get-ProjectAgentQueues -OrganizationUrl $OrganizationUrl -ProjectId $project.id
   
    Write-Host "`nAgent Pools in Project:" -ForegroundColor Cyan
    foreach ($pool in $agentPools) {
        $queue = $projectQueues | Where-Object { $_.pool.id -eq $pool.id }
       
        if ($queue) {
            Write-Host "   $($pool.name)" -ForegroundColor Green
            Write-Host "    Queue ID: $($queue.id)" -ForegroundColor White
            Write-Host "    Pool ID: $($queue.pool.id)" -ForegroundColor White
        }
        else {
            Write-Host "   $($pool.name) (not verified)" -ForegroundColor Yellow
        }
    }
   
    # Summary
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Summary" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Project: $($project.name)" -ForegroundColor Cyan
    Write-Host "Agent Pools Added: $poolsAdded" -ForegroundColor Green
    Write-Host "Agent Pools Already Existed: $poolsExisting" -ForegroundColor Cyan
    Write-Host "Agent Pools Failed: $poolsFailed" -ForegroundColor $(if ($poolsFailed -gt 0) { "Red" } else { "Green" })
    Write-Host ""
   
    foreach ($poolName in $poolResults.Keys) {
        $result = $poolResults[$poolName]
       
        switch ($result.status) {
            "added" {
                Write-Host " $poolName - Added to project" -ForegroundColor Green
            }
            "existing" {
                Write-Host " $poolName - Already in project" -ForegroundColor Yellow
            }
            "failed" {
                Write-Host " $poolName - Failed" -ForegroundColor Red
                Write-Host "    Error: $($result.error)" -ForegroundColor Red
            }
        }
    }
   
    Write-Host ""
   
    if ($poolsAdded -gt 0 -or $poolsExisting -gt 0) {
        Write-Host " Agent pool(s) are now available in project settings" -ForegroundColor Green
        Write-Host ""
        Write-Host "View agent pools in project:" -ForegroundColor Cyan
        Write-Host "  $OrganizationUrl/$ProjectName/_settings/agentqueues" -ForegroundColor Yellow
    }
   
    if ($poolsFailed -gt 0) {
        Write-Warning "Some agent pools could not be added. Check the errors above."
        exit 1
    }
}
catch {
    Write-Error "##[error]Failed to add agent pools: $_"
    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Verify Service Principal has appropriate agent pool permissions" -ForegroundColor White
    Write-Host "  2. Check that agent pools exist at organization level" -ForegroundColor White
    Write-Host "  3. Verify agent pool names are correct (case-sensitive)" -ForegroundColor White
    Write-Host "  4. Ensure Service Principal has 'vso.agentpools_manage' scope" -ForegroundColor White
    Write-Host "  5. Check Project Settings → Agent Pools at:" -ForegroundColor White
    Write-Host "     $OrganizationUrl/$ProjectName/_settings/agentqueues" -ForegroundColor White
    Write-Host ""
    exit 1
}

#endregion