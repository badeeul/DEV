param (
    [Parameter(Mandatory=$true)]
    [string]$ReleaseMajorVersion,
    [Parameter(Mandatory=$true)]
    [string]$ReleaseMinorVersion,
    [Parameter(Mandatory=$true)]
    [string]$ReleasePatchVersion,
    [Parameter(Mandatory=$true)]
    [string]$SourceBranch = "main",
    [Parameter(Mandatory=$true)]
    [string]$Organization,
    [Parameter(Mandatory=$true)]
    [string]$Project,
    [Parameter(Mandatory=$true)]
    [string]$Repository,
    [Parameter(Mandatory=$false)]
    [string]$ProjectPrefix = "platform-services-monitor",
    [Parameter(Mandatory=$false)]
    [int]$DaysToLookBack = 30    
)

# Service Principal Authentication details will come from environment variables:
# ARM_CLIENT_ID
# ARM_CLIENT_SECRET
# ARM_TENANT_ID

function Get-DevOpsAuthToken {
    try {
        $resource = "499b84ac-1321-427f-aa17-267ca6975798"
        $authUrl = "https://login.microsoftonline.com/$env:ARM_TENANT_ID/oauth2/token"

        # Construct token request
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $env:ARM_CLIENT_ID
            client_secret = $env:ARM_CLIENT_SECRET
            resource      = $resource
        }

        # Get token
        $response = Invoke-RestMethod -Method Post -Uri $authUrl -Body $body
        $token = $response.access_token

        return $token
    }
    catch {
        Write-Error "Failed to get Azure DevOps token: $_"
        throw
    }
}

function Test-GitRepository {
  $gitDir = Get-Command "git" -ErrorAction SilentlyContinue
  if (-not $gitDir) {
      throw "Git is not installed."
  }
}

function Get-ProjectId {
    param (
        [string]$Organization,
        [string]$ProjectName,
        [string]$Token
    )
   
    Write-Host "##[debug]Looking up Project ID for: $ProjectName"
   
    # Construct API URL to get project details
    $uri = "https://dev.azure.com/$Organization/_apis/projects?api-version=7.0"
    Write-Host "##[debug]API URL: $uri"
   
    $response = Invoke-AzDevOpsApi -Uri $uri -Token $Token

    # filter response by project name
    $response = $response.value | Where-Object { $_.name -eq $ProjectName }
   
    if ($response.count -eq 0) {
        throw "Project '$ProjectName' not found in organization '$Organization'"
    }
   
    Write-Host "##[debug]Found project response: $($response | ConvertTo-Json -Depth 3)"
    $projectId = $response.id
    Write-Host "##[debug]Found Project ID: $projectId"
   
    return $projectId
}

function Get-RepositoryId {
    param (
        [string]$Organization,
        [string]$ProjectId,
        [string]$RepositoryName,
        [string]$Token
    )
   
    Write-Host "##[debug]Looking up Repository ID for: $RepositoryName in Project ID: $ProjectId"
   
    # Construct API URL to get repository details
    $uri = "https://dev.azure.com/$Organization/$ProjectId/_apis/git/repositories?api-version=7.0"
   
    $response = Invoke-AzDevOpsApi -Uri $uri -Token $Token
   
    if ($response.count -eq 0) {
        throw "No repositories found in project ID '$ProjectId'"
    }
   
    $repository = $response.value | Where-Object { $_.name -eq $RepositoryName }
   
    if (-not $repository) {
        throw "Repository '$RepositoryName' not found in project ID '$ProjectId'"
    }
   
    $repositoryId = $repository.id
    Write-Host "##[debug]Found Repository ID: $repositoryId"
   
    return $repositoryId
}

function Initialize-GitConfiguration {
     param (
        [string]$Token,
        [string]$Organization,
        [string]$Project,
        [string]$Repository
    )    
    Write-Host "##[debug]Initializing Git configurations..."

    # Configure Git to avoid common issues
    git config --global core.longpaths true
    git config --global core.autocrlf false
    git config --global core.packedGitLimit 512m
    git config --global core.packedGitWindowSize 512m
    git config --global pack.windowMemory 512m
    git config --global pack.packSizeLimit 512m
    git config --global http.postBuffer 524288000

    # Set git config for commits
    git config --global user.email "azure-pipeline@bhg.com"
    git config --global user.name "Azure Pipeline"
}

function New-ReleaseBranch {
    param (
        [string]$Version,
        [string]$SourceBranch,
        [string]$Organization,
        [string]$ProjectId,
        [string]$RepositoryId
    )

    Write-Host "##[section]Creating release branch for version $Version from $SourceBranch"
    try {
        $tenantId = $env:ARM_TENANT_ID
        $clientId = $env:ARM_CLIENT_ID
        $clientSecret = $env:ARM_CLIENT_SECRET

        # Get Azure AD token
        $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        $bodyParams = @{
            grant_type    = "client_credentials"
            client_id     = $clientId
            client_secret = $clientSecret
            scope         = "499b84ac-1321-427f-aa17-267ca6975798/.default"
        }

        Add-Type -AssemblyName System.Web
        $encodedBody = ($bodyParams.GetEnumerator() | ForEach-Object {
            "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
        }) -join "&"

        $authResult = Invoke-RestMethod -Method Post -Uri $tokenUrl `
            -ContentType "application/x-www-form-urlencoded" `
            -Body $encodedBody

        # Create a temp directory for repo operations
        $tempDir = Join-Path $env:TEMP "release_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        Set-Location $tempDir
       
        Write-Host "##[debug]Working in temporary directory: $tempDir"

        # Clone repository with source branch
        $repoUrl = "https://oauth2:$($authResult.access_token)@dev.azure.com/$Organization/$ProjectId/_git/$RepositoryId"
        Write-Host "##[debug]Cloning repository from $SourceBranch branch..."
        git clone -b $SourceBranch --single-branch --depth=1 $repoUrl .
        if ($LASTEXITCODE -ne 0) { throw "Failed to clone repository" }

        # Remove all folders except DevOpsServices
        Write-Host "##[debug]Removing unnecessary folders..."
        Get-ChildItem -Directory |
            Where-Object { $_.Name -ne "DevOpsServices" -and $_.Name -ne ".git" } |
            Remove-Item -Recurse -Force   
       
        # Create and switch to new branch
        $branchName = "release/$ProjectPrefix-v$Version"
        Write-Host "##[debug]Creating branch: $branchName"
        git checkout -b $branchName
        if ($LASTEXITCODE -ne 0) { throw "Failed to create branch $branchName" }

        # Stage the deletions
        git add -A

        Write-Host "##[debug]Successfully created release branch: $branchName"
        return @{
            BranchName = $branchName
            TempDir = $tempDir
        }
    }
    catch {
        Write-Error "Failed to create release branch: $_"
        throw
    }
}

function Invoke-AzDevOpsApi {
    param (
        [string]$Uri,
        [string]$Token,
        [string]$Method = "GET",
        [object]$Body = $null,
        [string]$ContentType = "application/json"
    )
   
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Accept" = "application/json"
    }
   
    $params = @{
        Uri = $Uri
        Headers = $headers
        Method = $Method
        ContentType = $ContentType
        UseBasicParsing = $true
    }
   
    if ($Body -and $Method -ne "GET") {
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 100 }
    }
   
    # Invoke the REST API call
    Write-Host "##[debug]Invoking API: $Uri"
    Write-Host "##[debug]Method: $Method"
   
    try {
        if ($Body -eq $null) {
            $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers
        }
        else {
            $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -Body $($params.Body)
        }
       
        return $response
    }
    catch {
        Write-Host "##[error]API call failed: $_"
        Write-Host "##[error]Status Code: $($_.Exception.Response.StatusCode.value__)"
       
        if ($_.ErrorDetails.Message) {
            Write-Host "##[error]Error Details: $($_.ErrorDetails.Message)"
        }
       
        # Return null instead of throwing to allow the script to continue
        return $null
    }
}

function Get-CompletedPullRequests {
    param (
        [string]$Organization,
        [string]$ProjectId,
        [string]$RepositoryId,
        [int]$DaysToLookBack,
        [string]$Token
    )
   
    $endDate = Get-Date
    $startDate = $endDate.AddDays(-$DaysToLookBack)
   
    Write-Host "##[debug]Getting completed pull requests between $($startDate.ToString('yyyy-MM-dd')) and $($endDate.ToString('yyyy-MM-dd'))"
   
    # Format dates for API
    $fromDate = $startDate.ToString("yyyy-MM-dd")
    $toDate = $endDate.ToString("yyyy-MM-dd")
   
    # Construct API URL to get completed pull requests
    $uri = "https://dev.azure.com/$Organization/$ProjectId/_apis/git/repositories/$RepositoryId/pullrequests?searchCriteria.status=completed&searchCriteria.minTime=$fromDate&searchCriteria.targetRefName=refs/heads/main&api-version=7.1"
   
    $pullRequests = Invoke-AzDevOpsApi -Uri $uri -Token $Token
   
    if ($pullRequests -and $pullRequests.value) {
        # Filter pull requests by completion date
        $filteredPRs = $pullRequests.value | Where-Object {
            (Get-Date $_.closedDate) -ge $startDate -and (Get-Date $_.closedDate) -le $endDate
        }
       
        Write-Host "##[debug]Found $($filteredPRs.Count) completed pull requests in date range"
        return $filteredPRs
    }
   
    Write-Host "##[debug]No pull requests found or API call failed"
    return @()
}

function Get-WorkItemsForPullRequest {
    param (
        [string]$Organization,
        [string]$ProjectId,
        [string]$RepositoryId,
        [int]$PullRequestId,
        [string]$Token
    )
   
    # Construct API URL to get work items for pull request
    $uri = "https://dev.azure.com/$Organization/$ProjectId/_apis/git/repositories/$RepositoryId/pullRequests/$PullRequestId/workitems?api-version=7.1"
   
    $workItems = Invoke-AzDevOpsApi -Uri $uri -Token $Token
   
    if ($workItems -and $workItems.value) {
        Write-Host "##[debug]Found $($workItems.value.Count) work items for PR #$PullRequestId"
        return $workItems.value
    }
   
    Write-Host "##[debug]No work items found for PR #$PullRequestId or API call failed"
    return @()
}

function Get-WorkItemDetails {
    param (
        [string]$Organization,
        [string]$ProjectId,
        [int]$WorkItemId,
        [string]$Token
    )
   
    # Construct API URL to get work item details
    $uri = "https://dev.azure.com/$Organization/$ProjectId/_apis/wit/workitems/$WorkItemId`?`$expand=all&api-version=7.1"
   
    $workItem = Invoke-AzDevOpsApi -Uri $uri -Token $Token
   
    return $workItem
}

function Format-ReleaseNotes {
    param (
        [PSCustomObject]$PullRequestInfo,
        [PSCustomObject]$WorkItemInfo
    )
   
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
   
    # Extract fields from work item 
    $workItemType = $WorkItemInfo.fields.'System.WorkItemType'
    $changeType = $WorkItemInfo.fields.'Custom.ChangeType' 
    $releaseNotes = $WorkItemInfo.fields.'Custom.ReleaseNotes' 
    $deployedVersion = $WorkItemInfo.fields.'Custom.DeployedReleaseVersion' 
    $releaseDate = $WorkItemInfo.fields.'Custom.ReleaseDate'
   
    # If no deployed version is set, use the current version being released
    if ([string]::IsNullOrEmpty($deployedVersion)) {
        $deployedVersion = "$ReleaseMajorVersion.$ReleaseMinorVersion.$ReleasePatchVersion"
    }
   
    # If no release date is set, use the current date
    if ([string]::IsNullOrEmpty($releaseDate)) {
        $releaseDate = Get-Date -Format "yyyy-MM-dd"
    }
   
    # Format the information
    $formattedInfo = [PSCustomObject]@{
        WorkItemId = $WorkItemInfo.id
        WorkItemType = $workItemType
        Title = $WorkItemInfo.fields.'System.Title'
        CommitId = $null # Not coming from commit but from PR
        CommitMessage = $null
        CommitDate = $null
        PullRequestId = $PullRequestInfo.pullRequestId
        PullRequestTitle = $PullRequestInfo.title
        ChangeType = $changeType
        ReleaseNotes = $releaseNotes
        DeployedVersion = $deployedVersion
        ReleaseDate = $releaseDate
        Timestamp = $timestamp
    }
   
    return $formattedInfo
}

function Export-ReleaseNotesToMarkdown {
    param (
        [Array]$ReleaseNotes,
        [string]$OutputPath = "changelog.md",
        [string]$Organization,
        [string]$Project
    )
   
    # Group release notes by version
    $groupedNotes = $ReleaseNotes | Group-Object -Property DeployedVersion
   
    # Define emoji codes using Unicode escape sequences
    $breakingEmoji = [char]::ConvertFromUtf32(0x1F4A5)  # 💥
    $featureEmoji = [char]::ConvertFromUtf32(0x2728)    # ✨
    $fixEmoji = [char]::ConvertFromUtf32(0x1F527)       # 🔧
    $docsEmoji = [char]::ConvertFromUtf32(0x1F4DD)      # 📝
    $internalEmoji = [char]::ConvertFromUtf32(0x26A1)   # ⚡
    $bulletEmoji = [char]::ConvertFromUtf32(0x2022)     # •
    $unknownEmoji = [char]::ConvertFromUtf32(0x2753)    # ❓
   
    # Create changelog content with emoji icons
    $markdownContent = @"
# Changelog

The following contains all major, minor, and patch version release notes.

$bulletEmoji $breakingEmoji Breaking change!

$bulletEmoji $featureEmoji New Functionality

$bulletEmoji $fixEmoji Bug Fix

$bulletEmoji $docsEmoji Documentation Update

$bulletEmoji $internalEmoji Internal Optimization

$bulletEmoji $unknownEmoji Unspecified Change Type


"@
   
    # Sort versions (assuming semver format)
    $sortedGroups = $groupedNotes | Sort-Object -Property Name -Descending
   
    foreach ($versionGroup in $sortedGroups) {
        $version = $versionGroup.Name
        # Take the first release date from the group (should be the same for all items in a version)
        $releaseDate = ($versionGroup.Group | Select-Object -First 1).ReleaseDate
       
        # Add version header
        $markdownContent += @"

## Version $version

Release Date: $releaseDate


"@
       
        # Add each release note item
        foreach ($note in $versionGroup.Group) {
            # Map change type to emoji
            $icon = switch -Regex ($note.ChangeType) {
                "Breaking Change" { $breakingEmoji }
                "New Functionality" { $featureEmoji }
                "Bug Fix" { $fixEmoji }
                "Documentation Update" { $docsEmoji }
                "Internal Optimization" { $internalEmoji }
                default { $unknownEmoji }
            }
           
            # Clean up release notes text by removing HTML tags
            $cleanNotes = $note.ReleaseNotes
           
            # Replace common HTML patterns with Markdown equivalents
            if ($cleanNotes) {
                # Remove div tags
                $cleanNotes = $cleanNotes -replace '<div>', '' -replace '</div>', ''
               
                # Replace HTML lists with Markdown lists
                $cleanNotes = $cleanNotes -replace '<ul>', "`n"
                $cleanNotes = $cleanNotes -replace '</ul>', "`n"
                $cleanNotes = $cleanNotes -replace '<li>', '  * ' -replace '</li>', "`n"
               
                # Replace breaks with newlines + indent
                $cleanNotes = $cleanNotes -replace '<br>', "`n  "
               
                # Replace other common HTML tags
                $cleanNotes = $cleanNotes -replace '<[/]?(p|span|b|i|strong|em|h\d)[^>]*>', ''
               
                # Replace &quot; with actual quotes
                $cleanNotes = $cleanNotes -replace '&quot;', '"'
               
                # Remove any remaining HTML tags
                $cleanNotes = $cleanNotes -replace '<[^>]+>', ''
               
                # Trim whitespace
                $cleanNotes = $cleanNotes.Trim()
               
                # Normalize spacing (remove multiple consecutive blank lines)
                $cleanNotes = $cleanNotes -replace '(\r?\n){3,}', "`n`n"
               
                # Ensure proper indentation for multi-line notes
                if ($cleanNotes.Contains("`n")) {
                    $indentedLines = $cleanNotes -split "`n" | ForEach-Object {
                        if ($_ -match "^\s*\*$bulletEmoji") {
                            # Already a list item, leave as is
                            $_
                        } else {
                            # Add proper indentation to continuation lines
                            "  $_"
                        }
                    }
                    $cleanNotes = $indentedLines -join "`n"
                }
            } else {
                $cleanNotes = "No details provided"
            }
           
            # Add release note with work item link
            $markdownContent += "$bulletEmoji $icon $cleanNotes ([#$($note.WorkItemId)](https://dev.azure.com/$Organization/$Project/_workitems/edit/$($note.WorkItemId)))`n"
            # add newline for readability
            $markdownContent += "`n"
        }
    }
   
    # Use .NET methods to write the file with proper UTF-8 encoding with BOM
    $utf8WithBom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($OutputPath, $markdownContent, $utf8WithBom)
   
    Write-Host "##[debug]Changelog exported to $OutputPath"
}

function Commit-ChangelogToReleaseBranch {
    param (
        [string]$ChangelogPath,
        [string]$BranchName,
        [string]$TempDir
    )
   
    Write-Host "##[section]Committing changelog to release branch"
   
    # Ensure we're in the right directory
    Set-Location $TempDir
   
    # Add the changelog file
    git add $ChangelogPath
    if ($LASTEXITCODE -ne 0) { throw "Failed to add changelog file to git" }
   
    # Commit
    git commit -m "docs: Add changelog for release $BranchName"
    if ($LASTEXITCODE -ne 0) { throw "Failed to commit changelog" }
   
    # Push
    git push origin $BranchName
    if ($LASTEXITCODE -ne 0) { throw "Failed to push changelog to remote" }
   
    Write-Host "##[debug]Successfully committed and pushed changelog to $BranchName"
}

# Main execution flow
try {
    # Set full version string
    $version = "$ReleaseMajorVersion.$ReleaseMinorVersion.$ReleasePatchVersion"
   
    # Get token and validate repository
    $token = Get-DevOpsAuthToken
    Test-GitRepository
   
    # Using splatting for Initialize-GitConfiguration
    $gitConfig = @{
        Token = $Token
        Organization = $Organization
        Project = $Project
        Repository = $Repository
    }
    Initialize-GitConfiguration @gitConfig
   
    # Look up Project and Repository IDs
    Write-Host "##[section]Looking up Project and Repository IDs"
    $projectId = Get-ProjectId -Organization $Organization -ProjectName $Project -Token $token
    $repositoryId = Get-RepositoryId -Organization $Organization -ProjectId $projectId -RepositoryName $Repository -Token $token  
   
    # Create release branch using IDs
    $branchInfo = New-ReleaseBranch -Version $version -SourceBranch $SourceBranch -Organization $Organization -ProjectId $projectId -RepositoryId $repositoryId
    $branchName = $branchInfo.BranchName
    $tempDir = $branchInfo.TempDir

    Write-Host "##[section]Generating changelog for release $version"
   
    # Get completed pull requests for the specified period
    $pullRequests = Get-CompletedPullRequests -Organization $Organization -ProjectId $projectId -RepositoryId $repositoryId -DaysToLookBack $DaysToLookBack -Token $token

    $releaseNotes = @()
   
    # Process each pull request to get work items
    foreach ($pr in $pullRequests) {
        Write-Host "##[debug]Processing pull request #$($pr.pullRequestId): $($pr.title)"
       
        # Get work items associated with this pull request
        $workItems = Get-WorkItemsForPullRequest -Organization $Organization -ProjectId $projectId -RepositoryId $repositoryId -PullRequestId $pr.pullRequestId -Token $token
       
        foreach ($workItem in $workItems) {
            # Get full work item details
            $workItemDetails = Get-WorkItemDetails -Organization $Organization -ProjectId $projectId -WorkItemId $workItem.id -Token $token
           
            # Check if work item is a Fluidity Request Form
            if ($workItemDetails -and $workItemDetails.fields -and $workItemDetails.fields.'System.WorkItemType' -eq 'Fluidity Request Form') {
                Write-Host "##[debug]    Found Fluidity Request Form #$($workItemDetails.id): $($workItemDetails.fields.'System.Title')"
               
                # Format and collect release notes
                $formattedInfo = Format-ReleaseNotes -PullRequestInfo $pr -WorkItemInfo $workItemDetails
                $releaseNotes += $formattedInfo
            }
            elseif ($workItemDetails -and ($workItemDetails.fields -and $workItemDetails.fields.'System.WorkItemType' -eq 'Bug') -and ($workItemDetails.fields.'System.State' -eq 'Resolved' -or $workItemDetails.fields.'System.State' -eq 'Done')) {
                # Format and collect release notes
                $formattedInfo = Format-ReleaseNotes -PullRequestInfo $pr -WorkItemInfo $workItemDetails
                $releaseNotes += $formattedInfo                
            }
            elseif ($workItemDetails) {
                $workItemType = $workItemDetails.fields.'System.WorkItemType'
                Write-Host "##[debug]    Skipping work item #$($workItemDetails.id): not a Fluidity Request Form (type: $workItemType)"
            }
        }
    }
   
    # Export results to changelog.md
    $changelogPath = Join-Path $tempDir "changelog.md"
    if ($releaseNotes.Count -gt 0) {
        Write-Host "##[section]Found $($releaseNotes.Count) release notes entries"
        Export-ReleaseNotesToMarkdown -ReleaseNotes $releaseNotes -OutputPath $changelogPath -Organization $Organization -Project $Project
       
        # Commit and push changelog to release branch
        Commit-ChangelogToReleaseBranch -ChangelogPath $changelogPath -BranchName $branchName -TempDir $tempDir
    }
    else {
        Write-Host "##[section]No release notes found, creating empty changelog"
        $emptyChangelogContent = @"
# Changelog

The following contains all major, minor, and patch version release notes.

- [BREAKING] Breaking change!
- [FEATURE] New Functionality
- [FIX] Bug Fix
- [DOCS] Documentation Update
- [INTERNAL] Internal Optimization

## Version $version
Release Date: $(Get-Date -Format "yyyy-MM-dd")

No release notes available for this version.
"@
        Set-Content -Path $changelogPath -Value $emptyChangelogContent -Encoding UTF8
       
        # Commit and push changelog to release branch
        Commit-ChangelogToReleaseBranch -ChangelogPath $changelogPath -BranchName $branchName -TempDir $tempDir
    }
   
    # Output the branch name for Azure DevOps pipeline
    Write-Host "##vso[task.setvariable variable=ReleaseBranchName;isoutput=true]$branchName"
}
catch {
    Write-Error $_
    exit 1
}
finally {
    # Clean up
    if (Test-Path "$HOME/.git-credentials") {
        Remove-Item "$HOME/.git-credentials" -Force
    }
   
    # Return to original location if needed
    if (Get-Location -Stack -ErrorAction SilentlyContinue) {
        Pop-Location
    }
}