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
    [string]$Repositories,
   
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

function New-GitRepository {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [string]$RepositoryName
    )
   
    try {
        Write-Host "##[debug]Creating repository: $RepositoryName"
       
        # check if repository already exists
        $listUri = "$OrganizationUrl/$ProjectId/_apis/git/repositories?api-version=$script:apiVersion"
        $reposList = Invoke-AzDoApiWithRetry -Uri $listUri -Method GET
        $existingRepo = $reposList.value | Where-Object { $_.name -eq $RepositoryName }
        if ($existingRepo) {
            Write-Host "##[warning]Repository '$RepositoryName' already exists. Skipping creation."
            return $existingRepo
        }
        # Build the Git Repositories API URI
        $repoUri = "$OrganizationUrl/$ProjectId/_apis/git/repositories?api-version=$script:apiVersion"
       
        # Build request body
        $body = @{
            name = $RepositoryName
            project = @{
                id = $ProjectId
            }
        } | ConvertTo-Json
       
        Write-Host "##[debug]Request URI: $repoUri"
        Write-Host "##[debug]Request body: $body"
       
        # Make the POST API call
        $repo = Invoke-AzDoApiWithRetry -Uri $repoUri -Method POST -Body $body
       
        Write-Host "##[command]Successfully created repository: $RepositoryName" -ForegroundColor Green
        Write-Host "##[debug]Repository ID: $($repo.id)"
        Write-Host "##[debug]Default Branch: $($repo.defaultBranch)"
       
        return $repo
    }
    catch {
        Write-Error "Failed to create repository '$RepositoryName': $_"
        throw
    }
}

function Initialize-Repository {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [string]$RepositoryId
    )
   
    try {
        Write-Host "##[debug]Initializing repository with initial commit..."
       
        # Create README.md content
        $readmeContent = @"
# Fabric Repository

This repository contains fabric-related resources.

## Structure

- `src/fabric/` - Main fabric source code directory
- `src/fabric/README.md` - This file

## Getting Started

Add your fabric configurations and code here.
"@
       
        # Convert content to Base64
        $readmeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($readmeContent))
       
        # Build the push request
        $pushUri = "$OrganizationUrl/$ProjectId/_apis/git/repositories/$RepositoryId/pushes?api-version=$script:apiVersion"
       
        # Create the push payload with folder structure and README.md
        $pushBody = @{
            refUpdates = @(
                @{
                    name = "refs/heads/main"
                    oldObjectId = "0000000000000000000000000000000000000000"
                }
            )
            commits = @(
                @{
                    comment = "Initial commit: Add src/fabric folder structure and README.md"
                    changes = @(
                        @{
                            changeType = "add"
                            item = @{
                                path = "/src/fabric/README.md"
                            }
                            newContent = @{
                                content = $readmeBase64
                                contentType = "base64encoded"
                            }
                        }
                    )
                }
            )
        } | ConvertTo-Json -Depth 10
       
        Write-Host "##[debug]Push URI: $pushUri"
        Write-Host "##[debug]Creating initial commit with src/fabric/README.md"


        # Make the POST API call to push
        $pushResponse = Invoke-AzDoApiWithRetry -Uri $pushUri -Method POST -Body $pushBody
       
        Write-Host "##[command]Successfully initialized repository with main branch" -ForegroundColor Green
        Write-Host "##[debug]Commit ID: $($pushResponse.commits[0].commitId)"
        Write-Host "##[debug]Branch: main"
        Write-Host "##[debug]Files added:"
        Write-Host "##[debug]  - /src/fabric/README.md"
       
        return $pushResponse
    }
    catch {
        Write-Error "Failed to initialize repository: $_"
        throw
    }
}

function Set-DefaultBranch {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [string]$RepositoryId
    )
   
    try {
        Write-Host "##[debug]Setting default branch to main..."
       
        # Update repository to set default branch
        $repoUri = "$OrganizationUrl/$ProjectId/_apis/git/repositories/$RepositoryId`?api-version=$script:apiVersion"
       
        $body = @{
            defaultBranch = "refs/heads/main"
        } | ConvertTo-Json
       
        Write-Host "##[debug]Request URI: $repoUri"
       
        # Make the PATCH API call
        $response = Invoke-AzDoApiWithRetry -Uri $repoUri -Method PATCH -Body $body
       
        Write-Host "##[command]Successfully set default branch to main" -ForegroundColor Green
       
        return $response
    }
    catch {
        Write-Warning "Could not set default branch: $_"
        return $null
    }
}

function Get-RepositoryDetails {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [string]$RepositoryId
    )
   
    try {
        Write-Host "##[debug]Retrieving repository details..."
       
        # Get repository info
        $repoUri = "$OrganizationUrl/$ProjectName/_apis/git/repositories/$RepositoryId`?api-version=$script:apiVersion"
        $repo = Invoke-AzDoApiWithRetry -Uri $repoUri -Method GET
       
        # Get commits
        $commitsUri = "$OrganizationUrl/$ProjectName/_apis/git/repositories/$RepositoryId/commits?api-version=$script:apiVersion"
        $commits = Invoke-AzDoApiWithRetry -Uri $commitsUri -Method GET
       
        Write-Host "`nRepository Details:" -ForegroundColor Cyan
        Write-Host "  Name: $($repo.name)" -ForegroundColor White
        Write-Host "  ID: $($repo.id)" -ForegroundColor White
        Write-Host "  Default Branch: $($repo.defaultBranch)" -ForegroundColor White
        Write-Host "  Clone URL (HTTPS): $($repo.remoteUrl)" -ForegroundColor White
        Write-Host "  Web URL: $($repo.webUrl)" -ForegroundColor White
        Write-Host "  Commits: $($commits.count)" -ForegroundColor White
       
        if ($commits.value.Count -gt 0) {
            Write-Host "`n  Latest Commit:" -ForegroundColor Cyan
            Write-Host "    ID: $($commits.value[0].commitId)" -ForegroundColor White
            Write-Host "    Comment: $($commits.value[0].comment)" -ForegroundColor White
            Write-Host "    Author: $($commits.value[0].author.name)" -ForegroundColor White
            Write-Host "    Date: $($commits.value[0].author.date)" -ForegroundColor White
        }
       
        return @{
            repository = $repo
            commits = $commits
        }
    }
    catch {
        Write-Warning "Could not retrieve repository details: $_"
        return $null
    }
}

function Get-Repository {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [string]$RepositoryName
    )
   
    try {
        Write-Host "##[debug]Checking if repository exists: $RepositoryName"
       
        # Get all repositories in the project
        $reposUri = "$OrganizationUrl/$ProjectId/_apis/git/repositories?api-version=$script:apiVersion"
        $repos = Invoke-AzDoApiWithRetry -Uri $reposUri -Method GET
       
        # Find repository by name
        $existingRepo = $repos.value | Where-Object { $_.name -eq $RepositoryName }
       
        if ($existingRepo) {
            Write-Host "##[command]Repository '$RepositoryName' already exists" -ForegroundColor Yellow
            Write-Host "##[debug]  Repository ID: $($existingRepo.id)"
            Write-Host "##[debug]  Default Branch: $($existingRepo.defaultBranch)"
            Write-Host "##[debug]  Size: $($existingRepo.size) bytes"
            return $existingRepo
        }
        else {
            Write-Host "##[debug]Repository '$RepositoryName' does not exist"
            return $null
        }
    }
    catch {
        Write-Warning "Could not check for existing repository: $_"
        return $null
    }
}

#endregion

#region Main Execution

try {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Create Git Repository with Structure" -ForegroundColor Green
    Write-Host "Using Service Principal Authentication" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host "  Organization URL: $OrganizationUrl"
    Write-Host "  Project Name:     $ProjectName"
    Write-Host "  Repository Name:  $RepositoryName"
    Write-Host ""
   
    # Parse security groups
    $repositoryNames = $Repositories -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    Write-Host "##[debug]Parsed $($repositoryNames.Count) repository(ies)"

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
   
    # Step 2: Create Repository
    Write-Section "Step 2: Creating Git Repository"
   
    foreach ($repositoryName in $repositoryNames) {

        # Check if repository exists
        $existingRepo = Get-Repository -OrganizationUrl $OrganizationUrl -ProjectId $project.id -RepositoryName $repositoryName

        if ($existingRepo) {
            Write-Host "##[warning]Repository '$repositoryName' already exists. Skipping creation."
            continue
        }
        $repository = New-GitRepository -OrganizationUrl $OrganizationUrl -ProjectId $project.id -RepositoryName $repositoryName
    
        Write-Host "##[command]Repository created: $($repository.name)" -ForegroundColor Green
        Write-Host "##[debug]Repository ID: $($repository.id)"
        
        # Step 3: Initialize Repository with main branch and folder structure
        Write-Section "Step 3: Initializing Repository"
        
        $push = Initialize-Repository -OrganizationUrl $OrganizationUrl -ProjectId $project.id -RepositoryId $repository.id
        
        Write-Host "##[command]Repository initialized with main branch and src/fabric/README.md" -ForegroundColor Green
        
        # Step 4: Set default branch to main
        Write-Section "Step 4: Setting Default Branch"
        
        Set-DefaultBranch -OrganizationUrl $OrganizationUrl -ProjectId $project.id -RepositoryId $repository.id
        
        # Step 5: Display Repository Details
        Write-Section "Step 5: Repository Summary"
        
        $details = Get-RepositoryDetails -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName -RepositoryId $repository.id
        
        # Summary
        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "Summary" -ForegroundColor Green
        Write-Host "========================================`n" -ForegroundColor Green
        
        Write-Host " Repository '$repositoryName' created successfully" -ForegroundColor Green
        Write-Host " Main branch initialized" -ForegroundColor Green
        Write-Host " Folder structure created: src/fabric/" -ForegroundColor Green
        Write-Host " README.md added to src/fabric/" -ForegroundColor Green
        Write-Host ""
        Write-Host "Repository Structure:" -ForegroundColor Cyan
        Write-Host "  repo-test/" -ForegroundColor White
        Write-Host "  └── src/" -ForegroundColor White
        Write-Host "      └── fabric/" -ForegroundColor White
        Write-Host "          └── README.md" -ForegroundColor White
        Write-Host ""
        Write-Host "Clone the repository:" -ForegroundColor Cyan
        Write-Host "  git clone $($repository.remoteUrl)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "View in browser:" -ForegroundColor Cyan
        Write-Host "  $($repository.webUrl)" -ForegroundColor Yellow
    }
  }
  catch {
      Write-Error "##[error]Failed to create repository: $_"
      Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
      Write-Host "  1. Verify Service Principal has appropriate Git repository permissions" -ForegroundColor White
      Write-Host "  2. Check that project name is correct" -ForegroundColor White
      Write-Host "  3. Ensure repository name is unique within the project" -ForegroundColor White
      Write-Host "  4. Verify Service Principal has 'vso.code_write' scope" -ForegroundColor White
      Write-Host ""
      exit 1
  }

#endregion
