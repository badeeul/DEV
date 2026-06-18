param(
    [Parameter(Mandatory=$true)]
    [string]$OrganizationUrl,  # https://dev.azure.com/yourorg
   
    [Parameter(Mandatory=$true)]
    [string]$ClientId,  # Service Principal Application (Client) ID
   
    [Parameter(Mandatory=$true)]
    [string]$ClientSecret,  # Service Principal Client Secret
   
    [Parameter(Mandatory=$true)]
    [string]$TenantId,  # Azure AD Tenant ID
   
    [Parameter(Mandatory=$true)]
    [string]$ProjectName,
   
    [Parameter(Mandatory=$false)]
    [string]$ProjectDescription = "",
   
    [Parameter(Mandatory=$false)]
    [ValidateSet("private", "public")]
    [string]$Visibility = "private",
   
    [Parameter(Mandatory=$false)]
    [ValidateSet("Agile", "Basic", "Scrum", "CMMI", "Scrum Custom")]
    [string]$ProcessTemplate = "Scrum Custom",
   
    [Parameter(Mandatory=$false)]
    [ValidateSet("Git", "Tfvc")]
    [string]$SourceControl = "Git",  
   
    [Parameter(Mandatory=$false)]
    [int]$MaxRetries = 3,
   
    [Parameter(Mandatory=$false)]
    [int]$BaseRetryDelaySeconds = 5
)

$script:accessToken = $null
$script:headers = $null
$script:apiVersion = "7.1"

# Process template IDs
$script:processTemplates = @{
    "Agile" = "adcc42ab-9882-485e-a3ed-7678f01f66bc"
    "Basic" = "b8a3a935-7e91-48b8-a94c-606d37c3e9f2"
    "Scrum" = "6b724908-ef14-45cf-84f8-768b5384da45"
    "CMMI" = "27450541-8e31-4150-9947-dc59f998fc01"
    "Scrum Custom" = "560834dc-a4b9-4792-8a64-31e5459dd8a7"
}

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
            $resource = "499b84ac-1321-427f-aa17-267ca6975798"  # Azure DevOps
           
            $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/token"
           
            $body = @{
                grant_type    = "client_credentials"
                client_id     = $ClientId
                client_secret = $ClientSecret
                resource      = $resource
            }
           
            $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
           
            Write-Host "##[command]Successfully acquired access token"
            Write-Host "##[debug]Token expires in: $($response.expires_in) seconds"
           
            return $response.access_token
        }
        catch {
            Write-Warning "Attempt $attempt failed to acquire token: $_"
           
            if ($attempt -eq $MaxRetries) {
                Write-Error "Failed to acquire access token after $MaxRetries attempts"
                Write-Error "Error details: $_"
               
                if ($_.Exception.Response) {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $responseBody = $reader.ReadToEnd()
                    Write-Error "Response: $responseBody"
                }
               
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
   
    Write-Host "##[debug]API headers initialized with Bearer token"
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
            Write-Host "##[debug]API call attempt $attempt of $MaxRetries to: $Uri"
           
            # Check if token might be expired and refresh if needed
            if ($attempt -gt 1) {
                Write-Host "##[debug]Refreshing access token before retry..."
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
            Write-Host "##[debug]API call successful on attempt $attempt"
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
           
            # Check for authentication errors
            if ($_.Exception.Response.StatusCode -eq 401) {
                Write-Warning "Authentication error (401). Token may be expired."
            }
           
            if ($attempt -eq $MaxRetries) {
                Write-Error "API call failed after $MaxRetries attempts. Last error: $_"
                if ($errorResponse) {
                    Write-Error "Response body: $errorResponse"
                }
                throw "API call failed after $MaxRetries attempts: $_"
            }
           
            $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Host "##[warning]API call failed (attempt $attempt), retrying in $retryDelay seconds. Error: $_"
            Start-Sleep -Seconds $retryDelay
            $attempt++
        }
    }
}

function Test-ProjectExists {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName
    )
   
    try {
        Write-Host "##[debug]Checking if project '$ProjectName' already exists..."
       
        # List all projects in the organization
        $listUri = "$OrganizationUrl/_apis/projects?api-version=$script:apiVersion"
       
        try {
            $projectsList = Invoke-AzDoApiWithRetry -Uri $listUri -Method GET -MaxRetries 2
           
            if ($projectsList -and $projectsList.value) {
                Write-Host "##[debug]Found $($projectsList.count) project(s) in organization"
               
                # Find project by name (case-insensitive)
                $matchingProject = $projectsList.value | Where-Object {
                    $_.name -eq $ProjectName
                }
               
                if ($matchingProject) {
                    Write-Host "##[command]Project '$ProjectName' already exists" -ForegroundColor Yellow
                    Write-Host "##[debug]Project ID: $($matchingProject.id)"
                    Write-Host "##[debug]Project State: $($matchingProject.state)"
                    Write-Host "##[debug]Project Visibility: $($matchingProject.visibility)"
                   
                    # Get full project details using project ID
                    $projectUri = "$OrganizationUrl/_apis/projects/$($matchingProject.id)?api-version=$script:apiVersion"
                    $fullProject = Invoke-AzDoApiWithRetry -Uri $projectUri -Method GET -MaxRetries 2
                   
                    return $fullProject
                }
                else {
                    Write-Host "##[debug]Project '$ProjectName' not found in organization"
                    return $null
                }
            }
            else {
                Write-Host "##[debug]No projects found in organization"
                return $null
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                Write-Host "##[debug]Organization has no projects or API returned 404"
                return $null
            }
            throw
        }
    }
    catch {
        Write-Error "Failed to check project existence: $_"
        throw
    }
}


function New-AzDoProject {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [string]$Description,
        [string]$Visibility,
        [string]$ProcessTemplate,
        [string]$SourceControl
    )
   
    try {
        Write-Host "##[command]Creating Azure DevOps project: $ProjectName"
       
        # get all process tempplate, GET https://dev.azure.com/{organization}/_apis/process/processes?api-version=7.1-preview.1
        $processTemplates = Invoke-AzDoApiWithRetry -Uri "$OrganizationUrl/_apis/process/processes?api-version=7.1-preview.1" -Method GET
        # display all process templates
        $processTemplates.value | ForEach-Object {
            Write-Host "##[debug]Process Template: $($_.name) (ID: $($_.id))"
            $script:processTemplates[$_.name] = $_.id
        }

        # Get process template ID
        $processTemplateId = $script:processTemplates[$ProcessTemplate]
       
        if ([string]::IsNullOrEmpty($processTemplateId)) {
            throw "Invalid process template: $ProcessTemplate"
        }
       
        Write-Host "##[debug]Using process template: $ProcessTemplate (ID: $processTemplateId)"
       
        $uri = "$OrganizationUrl/_apis/projects?api-version=$script:apiVersion"
       
        $body = @{
            name = $ProjectName
            description = $Description
            visibility = $Visibility
            capabilities = @{
                versioncontrol = @{
                    sourceControlType = $SourceControl
                }
                processTemplate = @{
                    templateTypeId = $processTemplateId
                }
            }
        } | ConvertTo-Json -Depth 10
       
        Write-Host "##[debug]Sending project creation request..."
       
        $response = Invoke-AzDoApiWithRetry -Uri $uri -Method POST -Body $body -MaxRetries $MaxRetries
       
        Write-Host "##[command]Project creation request submitted successfully"
        Write-Host "##[debug]Operation ID: $($response.id)"
       
        # Wait for project creation to complete
        $operationId = $response.id
        $statusUri = "$OrganizationUrl/_apis/operations/$operationId`?api-version=$script:apiVersion"
       
        $maxAttempts = 60  # 2 minutes max (60 * 2 seconds)
        $attempt = 0
       
        Write-Host "##[debug]Polling for project creation completion..."
       
        while ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds 2
           
            try {
                $operation = Invoke-AzDoApiWithRetry -Uri $statusUri -Method GET -MaxRetries 2
               
                Write-Host "##[debug]Project creation status: $($operation.status) (Attempt $($attempt + 1)/$maxAttempts)"
               
                if ($operation.status -eq "succeeded") {
                    Write-Host "##[command]Project '$ProjectName' created successfully!" -ForegroundColor Green
                   
                    # Get the created project details
                    Start-Sleep -Seconds 2  # Give it a moment to fully initialize
                    $projectUri = "$OrganizationUrl/_apis/projects/$ProjectName`?api-version=$script:apiVersion"
                    $project = Invoke-AzDoApiWithRetry -Uri $projectUri -Method GET
                   
                    return $project
                }
                elseif ($operation.status -eq "failed") {
                    $errorMessage = "Project creation failed"
                    if ($operation.error) {
                        $errorMessage += ": $($operation.error.message)"
                    }
                    throw $errorMessage
                }
                elseif ($operation.status -eq "cancelled") {
                    throw "Project creation was cancelled"
                }
               
            }
            catch {
                Write-Warning "Error checking operation status: $_"
            }
           
            $attempt++
        }
       
        throw "Project creation timed out after $maxAttempts attempts (2 minutes)"
    }
    catch {
        Write-Error "Failed to create project '$ProjectName': $_"
        throw
    }
}

function Get-ProjectDetails {
    param(
        [object]$Project
    )
   
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Project Details" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Name:        $($Project.name)" -ForegroundColor White
    Write-Host "ID:          $($Project.id)" -ForegroundColor White
    Write-Host "Description: $($Project.description)" -ForegroundColor White
    Write-Host "State:       $($Project.state)" -ForegroundColor White
    Write-Host "Visibility:  $($Project.visibility)" -ForegroundColor White
    Write-Host "URL:         $($Project.url)" -ForegroundColor White
   
    if ($Project._links -and $Project._links.web) {
        Write-Host "Web URL:     $($Project._links.web.href)" -ForegroundColor Cyan
    }
   
    Write-Host "`n========================================`n" -ForegroundColor Green
}

function Verify-ProjectAccess {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName
    )
   
    try {
        Write-Host "##[debug]Verifying project access and configuration..."
       
        # Get project details
        $projectUri = "$OrganizationUrl/_apis/projects/$ProjectName`?includeCapabilities=true&api-version=$script:apiVersion"
        $project = Invoke-AzDoApiWithRetry -Uri $projectUri -Method GET
       
        # Verify repositories
        $reposUri = "$OrganizationUrl/$ProjectName/_apis/git/repositories?api-version=$script:apiVersion"
        $repos = Invoke-AzDoApiWithRetry -Uri $reposUri -Method GET
       
        Write-Host "##[debug]Project has $($repos.count) repository(ies)" -ForegroundColor Green
       
        # Verify teams
        $teamsUri = "$OrganizationUrl/_apis/projects/$ProjectName/teams?api-version=$script:apiVersion"
        $teams = Invoke-AzDoApiWithRetry -Uri $teamsUri -Method GET
       
        Write-Host "##[debug]Project has $($teams.count) team(s)" -ForegroundColor Green
       
        return @{
            Project = $project
            RepositoryCount = $repos.count
            TeamCount = $teams.count
            DefaultTeam = $teams.value | Where-Object { $_.name -eq $ProjectName }
        }
    }
    catch {
        Write-Warning "Could not fully verify project access: $_"
        return $null
    }
}



try {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Azure DevOps Project Creator" -ForegroundColor Green
    Write-Host "Using Service Principal Authentication" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host "  Organization URL: $OrganizationUrl"
    Write-Host "  Project Name:     $ProjectName"
    Write-Host "  Description:      $ProjectDescription"
    Write-Host "  Visibility:       $Visibility"
    Write-Host "  Process Template: $ProcessTemplate"
    Write-Host "  Source Control:   $SourceControl"
    Write-Host "  Client ID:        $ClientId"
    Write-Host "  Tenant ID:        $TenantId"
    Write-Host ""
   
    # Step 0: Authenticate with Azure AD
    Write-Section "Step 0: Authenticating with Azure AD"
   
    $script:accessToken = Get-AzureAdAccessToken -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId -MaxRetries $MaxRetries
    Initialize-Headers -AccessToken $script:accessToken
   
    Write-Host "##[command]Authentication successful" -ForegroundColor Green
   
    # Step 1: Check if project already exists
    Write-Section "Step 1: Checking Project Existence"
   
    $existingProject = Test-ProjectExists -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
   
    if ($existingProject) {
        Write-Host "##[warning]Project '$ProjectName' already exists. Skipping creation." -ForegroundColor Yellow
       
        # Display existing project details
        Get-ProjectDetails -Project $existingProject
       
        # Verify access
        Write-Section "Verifying Project Access"
        $verification = Verify-ProjectAccess -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
       
        if ($verification) {
            Write-Host " Project is accessible" -ForegroundColor Green
            Write-Host " Default repository exists" -ForegroundColor Green
            Write-Host " Default team exists" -ForegroundColor Green
        }
       
        Write-Host "`n##[section]Project already exists - No action taken" -ForegroundColor Yellow
       
        # Return existing project
        return $existingProject
    }
   
    # Step 2: Create new project
    Write-Section "Step 2: Creating New Project"
   
    $newProject = New-AzDoProject `
        -OrganizationUrl $OrganizationUrl `
        -ProjectName $ProjectName `
        -Description $ProjectDescription `
        -Visibility $Visibility `
        -ProcessTemplate $ProcessTemplate `
        -SourceControl $SourceControl
   
    # Step 3: Display project details
    Write-Section "Step 3: Project Created Successfully"
   
    Get-ProjectDetails -Project $newProject
   
    # Step 4: Verify project access
    Write-Section "Step 4: Verifying Project Configuration"
   
    $verification = Verify-ProjectAccess -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
   
    if ($verification) {
        Write-Host " Project is accessible and configured" -ForegroundColor Green
        Write-Host " Default repository created: $($verification.RepositoryCount) repo(s)" -ForegroundColor Green
        Write-Host " Default team created: $($verification.TeamCount) team(s)" -ForegroundColor Green
       
        if ($verification.DefaultTeam) {
            Write-Host " Default team name: $($verification.DefaultTeam.name)" -ForegroundColor Green
        }
    }
   
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Project Creation Completed Successfully!" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "  1. Visit the project: $($newProject._links.web.href)" -ForegroundColor White
    Write-Host "  2. Configure additional teams and permissions" -ForegroundColor White
    Write-Host "  3. Create service connections" -ForegroundColor White
    Write-Host "  4. Set up pipelines and repositories" -ForegroundColor White
    Write-Host ""
   
    # Return the created project
    return $newProject
}
catch {
    Write-Error "##[error]Project creation failed: $_"
    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Verify Service Principal has correct permissions in Azure DevOps" -ForegroundColor White
    Write-Host "  2. Check Client ID, Client Secret, and Tenant ID are correct" -ForegroundColor White
    Write-Host "  3. Ensure Service Principal is added to Azure DevOps organization" -ForegroundColor White
    Write-Host "  4. Verify the organization URL is correct" -ForegroundColor White
    Write-Host "  5. Check Service Principal has 'Project Collection Administrators' group membership" -ForegroundColor White
    Write-Host ""
    exit 1
}

function Test-ProjectExists {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName
    )
   
    try {
        Write-Host "##[debug]Checking if project '$ProjectName' already exists..."
       
        $uri = "$OrganizationUrl/_apis/projects/$ProjectName`?api-version=$script:apiVersion"
       
        try {
            $project = Invoke-AzDoApiWithRetry -Uri $uri -Method GET -MaxRetries 2
           
            if ($project) {
                Write-Host "##[command]Project '$ProjectName' already exists" -ForegroundColor Yellow
                Write-Host "##[debug]Project ID: $($project.id)"
                Write-Host "##[debug]Project State: $($project.state)"
                Write-Host "##[debug]Project Visibility: $($project.visibility)"
                return $project
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                Write-Host "##[debug]Project does not exist (404 Not Found)"
                return $null
            }
            throw
        }
    }
    catch {
        Write-Error "Failed to check project existence: $_"
        throw
    }
}

function New-AzDoProject {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [string]$Description,
        [string]$Visibility,
        [string]$ProcessTemplate,
        [string]$SourceControl
    )
   
    try {
        Write-Host "##[command]Creating Azure DevOps project: $ProjectName"
       
        # Get process template ID
        $processTemplateId = $script:processTemplates[$ProcessTemplate]
       
        if ([string]::IsNullOrEmpty($processTemplateId)) {
            throw "Invalid process template: $ProcessTemplate"
        }
       
        Write-Host "##[debug]Using process template: $ProcessTemplate (ID: $processTemplateId)"
       
        $uri = "$OrganizationUrl/_apis/projects?api-version=$script:apiVersion"
       
        $body = @{
            name = $ProjectName
            description = $Description
            visibility = $Visibility
            capabilities = @{
                versioncontrol = @{
                    sourceControlType = $SourceControl
                }
                processTemplate = @{
                    templateTypeId = $processTemplateId
                }
            }
        } | ConvertTo-Json -Depth 10
       
        Write-Host "##[debug]Sending project creation request..."
       
        $response = Invoke-AzDoApiWithRetry -Uri $uri -Method POST -Body $body -MaxRetries $MaxRetries
       
        Write-Host "##[command]Project creation request submitted successfully"
        Write-Host "##[debug]Operation ID: $($response.id)"
       
        # Wait for project creation to complete
        $operationId = $response.id
        $statusUri = "$OrganizationUrl/_apis/operations/$operationId`?api-version=$script:apiVersion"
       
        $maxAttempts = 60  # 2 minutes max (60 * 2 seconds)
        $attempt = 0
       
        Write-Host "##[debug]Polling for project creation completion..."
       
        while ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds 2
           
            try {
                $operation = Invoke-AzDoApiWithRetry -Uri $statusUri -Method GET -MaxRetries 2
               
                Write-Host "##[debug]Project creation status: $($operation.status) (Attempt $($attempt + 1)/$maxAttempts)"
               
                if ($operation.status -eq "succeeded") {
                    Write-Host "##[command]Project '$ProjectName' created successfully!" -ForegroundColor Green
                   
                    # Get the created project details
                    Start-Sleep -Seconds 2  # Give it a moment to fully initialize
                    $projectUri = "$OrganizationUrl/_apis/projects/$ProjectName`?api-version=$script:apiVersion"
                    $project = Invoke-AzDoApiWithRetry -Uri $projectUri -Method GET
                   
                    return $project
                }
                elseif ($operation.status -eq "failed") {
                    $errorMessage = "Project creation failed"
                    if ($operation.error) {
                        $errorMessage += ": $($operation.error.message)"
                    }
                    throw $errorMessage
                }
                elseif ($operation.status -eq "cancelled") {
                    throw "Project creation was cancelled"
                }
               
            }
            catch {
                Write-Warning "Error checking operation status: $_"
            }
           
            $attempt++
        }
       
        throw "Project creation timed out after $maxAttempts attempts (2 minutes)"
    }
    catch {
        Write-Error "Failed to create project '$ProjectName': $_"
        throw
    }
}

function Get-ProjectDetails {
    param(
        [object]$Project
    )
   
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Project Details" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Name:        $($Project.name)" -ForegroundColor White
    Write-Host "ID:          $($Project.id)" -ForegroundColor White
    Write-Host "Description: $($Project.description)" -ForegroundColor White
    Write-Host "State:       $($Project.state)" -ForegroundColor White
    Write-Host "Visibility:  $($Project.visibility)" -ForegroundColor White
    Write-Host "URL:         $($Project.url)" -ForegroundColor White
   
    if ($Project._links -and $Project._links.web) {
        Write-Host "Web URL:     $($Project._links.web.href)" -ForegroundColor Cyan
    }
   
    Write-Host "`n========================================`n" -ForegroundColor Green
}

function Verify-ProjectAccess {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName
    )
   
    try {
        Write-Host "##[debug]Verifying project access and configuration..."
       
        # Get project details
        $projectUri = "$OrganizationUrl/_apis/projects/$ProjectName`?includeCapabilities=true&api-version=$script:apiVersion"
        $project = Invoke-AzDoApiWithRetry -Uri $projectUri -Method GET
       
        # Verify repositories
        $reposUri = "$OrganizationUrl/$ProjectName/_apis/git/repositories?api-version=$script:apiVersion"
        $repos = Invoke-AzDoApiWithRetry -Uri $reposUri -Method GET
       
        Write-Host "##[debug]Project has $($repos.count) repository(ies)" -ForegroundColor Green
       
        # Verify teams
        $teamsUri = "$OrganizationUrl/_apis/projects/$ProjectName/teams?api-version=$script:apiVersion"
        $teams = Invoke-AzDoApiWithRetry -Uri $teamsUri -Method GET
       
        Write-Host "##[debug]Project has $($teams.count) team(s)" -ForegroundColor Green
       
        return @{
            Project = $project
            RepositoryCount = $repos.count
            TeamCount = $teams.count
            DefaultTeam = $teams.value | Where-Object { $_.name -eq $ProjectName }
        }
    }
    catch {
        Write-Warning "Could not fully verify project access: $_"
        return $null
    }
}


try {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Azure DevOps Project Creator" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host "  Organization URL: $OrganizationUrl"
    Write-Host "  Project Name:     $ProjectName"
    Write-Host "  Description:      $ProjectDescription"
    Write-Host "  Visibility:       $Visibility"
    Write-Host "  Process Template: $ProcessTemplate"
    Write-Host "  Source Control:   $SourceControl"
    Write-Host ""
   
    # Step 1: Check if project already exists
    Write-Section "Step 1: Checking Project Existence"
   
    $existingProject = Test-ProjectExists -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
   
    if ($existingProject) {
        Write-Host "##[warning]Project '$ProjectName' already exists. Skipping creation." -ForegroundColor Yellow
       
        # Display existing project details
        Get-ProjectDetails -Project $existingProject
       
        # Verify access
        Write-Section "Verifying Project Access"
        $verification = Verify-ProjectAccess -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
       
        if ($verification) {
            Write-Host "Project is accessible" -ForegroundColor Green
            Write-Host "Default repository exists" -ForegroundColor Green
            Write-Host "Default team exists" -ForegroundColor Green
        }
       
        Write-Host "`n##[section]Project already exists - No action taken" -ForegroundColor Yellow
       
        # Return existing project
        return $existingProject
    }
   
    # Step 2: Create new project
    Write-Section "Step 2: Creating New Project"
   
    $newProject = New-AzDoProject `
        -OrganizationUrl $OrganizationUrl `
        -ProjectName $ProjectName `
        -Description $ProjectDescription `
        -Visibility $Visibility `
        -ProcessTemplate $ProcessTemplate `
        -SourceControl $SourceControl
   
    # Step 3: Display project details
    Write-Section "Step 3: Project Created Successfully"
   
    Get-ProjectDetails -Project $newProject
   
    # Step 4: Verify project access
    Write-Section "Step 4: Verifying Project Configuration"
   
    $verification = Verify-ProjectAccess -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
   
    if ($verification) {
        Write-Host "Project is accessible and configured" -ForegroundColor Green
        Write-Host "Default repository created: $($verification.RepositoryCount) repo(s)" -ForegroundColor Green
        Write-Host "Default team created: $($verification.TeamCount) team(s)" -ForegroundColor Green
       
        if ($verification.DefaultTeam) {
            Write-Host "Default team name: $($verification.DefaultTeam.name)" -ForegroundColor Green
        }
    }
   
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Project Creation Completed Successfully!" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "  1. Visit the project: $($newProject._links.web.href)" -ForegroundColor White
    Write-Host "  2. Configure additional teams and permissions" -ForegroundColor White
    Write-Host "  3. Create service connections" -ForegroundColor White
    Write-Host "  4. Set up pipelines and repositories" -ForegroundColor White
    Write-Host ""
   
    # Return the created project
    return $newProject
}
catch {
    Write-Error "##[error]Project creation failed: $_"
    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Verify your Personal Access Token has 'Project and Team' permissions" -ForegroundColor White
    Write-Host "  2. Check that you have Project Collection Administrator access" -ForegroundColor White
    Write-Host "  3. Ensure the project name doesn't contain invalid characters" -ForegroundColor White
    Write-Host "  4. Verify the organization URL is correct" -ForegroundColor White
    Write-Host ""
    exit 1
}
