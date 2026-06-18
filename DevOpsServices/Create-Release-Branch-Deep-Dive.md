# Create Release Branch: Automated Release Management - Deep Dive

---

## Table of Contents

### Architecture Foundation
1. [Release Branch Creation Overview](#release-branch-creation-overview)
2. [Automated Changelog Generation](#automated-changelog-generation)
3. [Common Patterns & Principles](#common-patterns-and-principles)

### Pipeline & Script
4. [Pipeline: Create-release-branch.yml](#pipeline-create-release-branchyml)
5. [Script: Create-release-branch.ps1](#script-create-release-branchps1)

### Core Functions
6. [Authentication Functions](#authentication-functions)
7. [Git Operations](#git-operations)
8. [Pull Request & Work Item Processing](#pull-request-and-work-item-processing)
9. [Changelog Generation](#changelog-generation)
10. [Teams Notification System](#teams-notification-system)

### Advanced Topics
11. [Work Item Filtering Strategy](#work-item-filtering-strategy)
12. [Markdown to HTML Conversion](#markdown-to-html-conversion)
13. [Teams Message Formatting](#teams-message-formatting)
14. [Error Handling & Cleanup](#error-handling-and-cleanup)
15. [Integration Workflows](#integration-workflows)

---

## Release Branch Creation Overview

The Create Release Branch workflow automates the creation of versioned release branches from source branches (typically `main` or `develop`), generates comprehensive changelogs from completed pull requests, and optionally sends formatted notifications to Microsoft Teams channels.

### Key Concepts

**Release Branch:** A version-tagged branch (e.g., `release/platform-services-v1.0.0`) created from a source branch containing tested code ready for deployment.

**Semantic Versioning:** Version numbers follow the `{major}.{minor}.{patch}` format where:
- **Major:** Breaking changes
- **Minor:** New features (backwards-compatible)
- **Patch:** Bug fixes (backwards-compatible)

**Changelog:** Automatically generated markdown file documenting all changes included in the release by analyzing completed pull requests and associated work items.

**Work Item Types:** Only specific work item types are included in changelog:
- **Fluidity Request Form:** Feature requests and enhancements
- **Bug:** Resolved/Done/Closed bugs

**Teams Notification:** Formatted HTML message sent to Microsoft Teams channel with release details and changelog.

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  Azure DevOps Pipeline (Create-release-branch.yml)          │
│  - Manual trigger with version parameters                    │
│  - Validates semantic version numbers                        │
└───────────────────┬─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  Create-release-branch.ps1 (PowerShell Script)              │
│  1. Authenticate (Azure DevOps + Microsoft Graph)           │
│  2. Create release branch from source branch                │
│  3. Query completed pull requests (last N days)             │
│  4. Extract associated work items                           │
│  5. Filter work items (Fluidity Request Forms, Bugs)        │
│  6. Generate changelog.md                                    │
│  7. Commit changelog to release branch                      │
│  8. Send Teams notification (optional)                      │
└───────────────────┬─────────────────────────────────────────┘
                    │
        ┌───────────┴───────────┬─────────────┐
        ▼                       ▼             ▼
┌──────────────────┐   ┌──────────────────┐  ┌──────────────────┐
│ Release Branch   │   │ changelog.md     │  │ Teams Channel    │
│ (Git)            │   │ (Committed)      │  │ (Notification)   │
│ - Source code    │   │ - Version info   │  │ - Release notes  │
│ - changelog.md   │   │ - Pull requests  │  │ - Tagged users   │
│ - Version tag    │   │ - Work items     │  │ - Links to work  │
└──────────────────┘   └──────────────────┘  └──────────────────┘
```

### Execution Flow

```
1. Pipeline Trigger (Manual)
   └── Parameters: majorVersion, minorVersion, patchVersion, sourceBranch, daysToLookBack

2. Validation Stage
   ├── Validate version numbers are numeric
   └── Validate environment variables

3. Authentication Setup
   ├── Get Azure DevOps token (OAuth 2.0)
   └── Get Microsoft Graph token (for Teams, optional)

4. Repository Setup
   ├── Initialize Git configuration
   ├── Clone source branch
   └── Create release branch

5. Pull Request Analysis
   ├── Query completed PRs (last N days)
   ├── Filter PRs targeting main branch
   └── Extract associated work items

6. Work Item Processing
   ├── Get work item details
   ├── Filter by type (Fluidity Request Form, Bug)
   ├── Filter bugs by state (Resolved/Done/Closed)
   └── Extract custom fields (ChangeType, ReleaseNotes)

7. Changelog Generation
   ├── Format release notes
   ├── Group by version
   ├── Generate markdown with emojis
   └── Convert to UTF-8 with BOM

8. Commit & Push
   ├── Commit changelog.md to release branch
   └── Push to remote repository

9. Teams Notification (Optional)
   ├── Get Teams channel info from URL
   ├── Get team tags for mentions
   ├── Format changelog as HTML
   ├── Create mentions for tagged users
   └── Send formatted message

10. Cleanup
    ├── Remove Git credentials
    └── Return to original directory
```

---

## Automated Changelog Generation

### Changelog Structure

The generated `changelog.md` file follows a consistent structure:

```markdown
# Changelog

The following contains all major, minor, and patch version release notes.

💥 Breaking change!
✨ New Functionality
🔧 Bug Fix
📝 Documentation Update
⚡ Internal Optimization
❓ Unspecified Change Type

## Version 1.0.0

Release Date: 2026-01-07

• ✨ Add new data pipeline orchestration framework ([#1234](link))

• 🔧 Fix memory leak in lakehouse sync operation ([#1235](link))

• 📝 Update deployment documentation with new capacity requirements ([#1236](link))
```

### Change Type Mapping

Work items include a `Custom.ChangeType` field that maps to emojis:

| Change Type | Emoji | Unicode | Description |
|-------------|-------|---------|-------------|
| Breaking Change | 💥 | U+1F4A5 | Incompatible API changes |
| New Functionality | ✨ | U+2728 | New features |
| Bug Fix | 🔧 | U+1F527 | Bug corrections |
| Documentation Update | 📝 | U+1F4DD | Documentation changes |
| Internal Optimization | ⚡ | U+26A1 | Performance improvements |
| Unspecified | ❓ | U+2753 | Unknown change type |

### Pull Request to Work Item Mapping

```
Pull Request #1234 (completed, merged to main)
├── Associated Work Item: Fluidity Request Form #5678
│   ├── Custom.ChangeType: "New Functionality"
│   ├── Custom.ReleaseNotes: "Add data pipeline orchestration..."
│   ├── Custom.DeployedReleaseVersion: "1.0.0"
│   └── Custom.ReleaseDate: "2026-01-07"
│
└── Associated Work Item: Bug #5679
    ├── System.State: "Resolved"
    ├── Custom.ChangeType: "Bug Fix"
    ├── Custom.ReleaseNotes: "Fix memory leak in sync..."
    ├── Custom.DeployedReleaseVersion: "1.0.0"
    └── Custom.ReleaseDate: "2026-01-07"
```

Only work items with these types/states are included:
- **Fluidity Request Form:** All states
- **Bug:** Only `Resolved`, `Done`, or `Closed` states

---

## Common Patterns and Principles

### 1. Dual Authentication Pattern

Script uses two separate authentication mechanisms:

**Azure DevOps Authentication (OAuth 2.0 Client Credentials):**
```powershell
function Get-DevOpsAuthToken {
    $resource = "499b84ac-1321-427f-aa17-267ca6975798"  # Azure DevOps resource ID
    $authUrl = "https://login.microsoftonline.com/$env:ARM_TENANT_ID/oauth2/token"
    
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $env:ARM_CLIENT_ID
        client_secret = $env:ARM_CLIENT_SECRET
        resource      = $resource
    }
    
    $response = Invoke-RestMethod -Method Post -Uri $authUrl -Body $body
    return $response.access_token
}
```

**Microsoft Graph Authentication (Resource Owner Password Credentials):**
```powershell
function Get-TeamsToken {
    $body = @{
        grant_type = "password"
        client_id = $env:TEAMS_CLIENT_ID
        client_secret = $env:TEAMS_CLIENT_SECRET
        resource = "https://graph.microsoft.com/"
        username = $env:TEAMS_NOTIFICATION_USERNAME
        password = $env:TEAMS_NOTIFICATION_PASSWORD
        scope = "ChannelMessage.Send User.Read"
    }
    
    $uri = "https://login.microsoftonline.com/$env:ARM_TENANT_ID/oauth2/token"
    $response = Invoke-RestMethod -Uri $uri -Method POST -Body $body
    
    return $response.access_token
}
```

**Why different grant types?**
- Azure DevOps: Service principal (client credentials) for automation
- Microsoft Graph: User account (password grant) for Teams posting on behalf of user

### 2. Unicode Emoji Handling

Emojis require careful handling across different contexts:

**For Console/Logs:**
```powershell
$rocketEmoji = [char]::ConvertFromUtf32(0x1F680)  # 🚀
Write-Host "##[section]$rocketEmoji Release branch creation"
```

**For Markdown Files:**
```powershell
# UTF-8 with BOM encoding
$utf8WithBom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($OutputPath, $markdownContent, $utf8WithBom)
```

**For Teams HTML:**
```powershell
$rocketEmoji = "&#x1F680;"  # HTML entity for 🚀
$htmlContent = "<p>$rocketEmoji Release Notification</p>"
```

**Why three different formats?**
- Console: Native PowerShell emoji rendering
- Markdown: UTF-8 encoding for Git compatibility
- Teams: HTML entities for reliable rendering in Teams

### 3. Git Credential Management

Credentials are configured for specific operations and cleaned up immediately:

```powershell
try {
    # Get fresh token
    $token = Get-DevOpsAuthToken
    
    # Configure Git to use bearer token for specific URL
    $repoUrl = "https://oauth2:$token@dev.azure.com/$Organization/$ProjectId/_git/$RepositoryId"
    git clone -b $SourceBranch $repoUrl .
    
    # Perform operations
    git checkout -b $branchName
    git commit -m "docs: Add changelog"
    git push origin $branchName
}
finally {
    # Always cleanup
    if (Test-Path "$HOME/.git-credentials") {
        Remove-Item "$HOME/.git-credentials" -Force
    }
}
```

**Why inline tokens?** Avoids global Git credential configuration that could leak to other operations.

### 4. Temporary Directory Pattern

All Git operations use isolated temporary directories:

```powershell
$tempDir = Join-Path $env:TEMP "release_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    Set-Location $tempDir
    # Perform Git operations
}
finally {
    Set-Location $originalLocation
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force
    }
}
```

**Benefits:**
- No conflicts with existing repositories
- Complete isolation between runs
- Automatic cleanup on error

### 5. API Wrapper Pattern

Centralized API call function with consistent error handling:

```powershell
function Invoke-AzDevOpsApi {
    param (
        [string]$Uri,
        [string]$Token,
        [string]$Method = "GET",
        [object]$Body = $null
    )
    
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Accept" = "application/json"
    }
    
    try {
        if ($Body -eq $null) {
            $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers
        } else {
            $bodyJson = $Body | ConvertTo-Json -Depth 100
            $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -Body $bodyJson
        }
        return $response
    }
    catch {
        Write-Host "##[error]API call failed: $_"
        Write-Host "##[error]Status Code: $($_.Exception.Response.StatusCode.value__)"
        return $null  # Return null instead of throwing
    }
}
```

**Benefits:**
- Consistent authentication
- Centralized error handling
- Graceful degradation (returns null on error)

---

## Pipeline Create-release-branch-yml

### Purpose
Azure DevOps YAML pipeline that orchestrates release branch creation with manual trigger, parameter validation, and automated changelog generation.

### Parameters

```yaml
parameters:
- name: variableGroup
  displayName: 'Variable Group'
  type: string
  default: 'PlatformServices'

- name: sendTeamsNotification
  type: boolean
  displayName: 'Send Teams Notification'
  default: false

- name: daysToLookBack
  displayName: 'Days to Look Back for Release Notes'
  type: number
  default: 8

- name: majorVersion
  type: string
  default: '1'
  displayName: 'Major Version'

- name: minorVersion
  type: string
  default: '0'
  displayName: 'Minor Version'

- name: patchVersion
  type: string
  default: '0'
  displayName: 'Patch Version'

- name: sourceBranch
  type: string
  default: 'main'
  displayName: 'Source Branch'

- name: organization
  type: string
  default: 'BHGDataAndAnalytics'
  displayName: 'Azure DevOps Organization'

- name: project
  type: string
  default: 'GDAP-Fluidity-PlatformServices'
  displayName: 'Azure DevOps Project'

- name: repository
  type: string
  default: 'PlatformServices-Fabric'
  displayName: 'Repository Name'
```

**Parameter Descriptions:**

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `variableGroup` | string | Variable group containing authentication secrets | `PlatformServices` |
| `sendTeamsNotification` | boolean | Enable/disable Teams notification | `false` |
| `daysToLookBack` | number | Days to scan for completed pull requests | `8` |
| `majorVersion` | string | Major version number (breaking changes) | `1` |
| `minorVersion` | string | Minor version number (new features) | `0` |
| `patchVersion` | string | Patch version number (bug fixes) | `0` |
| `sourceBranch` | string | Source branch to create release from | `main` |
| `organization` | string | Azure DevOps organization name | `BHGDataAndAnalytics` |
| `project` | string | Azure DevOps project name | `GDAP-Fluidity-PlatformServices` |
| `repository` | string | Repository name | `PlatformServices-Fabric` |

### Trigger Configuration

```yaml
trigger: none  # Manual trigger only
```

**Why manual only?** Release branch creation is a deliberate action requiring human decision-making about version numbers and timing.

### Variables

```yaml
variables:
  - group: ${{ parameters.variableGroup }}
  
  - name: agentPool
    value: GDAP-Fluidity-PlatformServices_Self-hosted-AgentPool

pool:
  name: $(agentPool)
  vmImage: windows-latest
```

**Required Variables from Variable Group:**
- `ARM_CLIENT_ID` → Service principal application ID
- `ARM_CLIENT_SECRET` → Service principal secret
- `ARM_CLIENT_OBJECT_ID` → Service principal object ID
- `ARM_TENANT_ID` → Azure AD tenant ID
- `TEAMS_CHANNEL_WEB_URL` → Teams channel URL for notifications
- `TEAMS_NOTIFICATION_USERNAME` → Teams user account
- `TEAMS_NOTIFICATION_PASSWORD` → Teams user password
- `TEAMS_CLIENT_ID` → Teams app client ID
- `TEAMS_CLIENT_SECRET` → Teams app client secret
- `TEAMS_TAGS` → Comma-separated list of Teams tags to mention

### Stages

#### Stage 1: Validate

Validates version parameters before proceeding:

```yaml
- stage: Validate
  displayName: 'Validate Release Parameters'
  jobs:
  - job: validate_version
    steps:
    - powershell: |
        # Validate version numbers
        $major = "${{ parameters.majorVersion }}"
        $minor = "${{ parameters.minorVersion }}"
        $patch = "${{ parameters.patchVersion }}"

        if (-not ($major -match '^\d+$' -and $minor -match '^\d+$' -and $patch -match '^\d+$')) {
            Write-Error "Version numbers must be numeric values"
            exit 1
        }
      displayName: 'Validate Parameters'
```

**Validation Rules:**
- All version components must be numeric
- No negative numbers
- No decimal points
- No special characters

**Why validate?** Prevents invalid branch names like `release/platform-services-v1.a.0`.

#### Stage 2: CreateRelease

Creates release branch and generates changelog:

```yaml
- stage: CreateRelease
  displayName: 'Create Release Branch'
  dependsOn: Validate
  jobs:
  - job: create_branch
    steps:
    # Checkout with credentials
    - checkout: self
      persistCredentials: true
      fetchDepth: 0

    # Debug: List all files
    - task: PowerShell@2
      displayName: 'List All Files and Folders'
      inputs:
        targetType: 'inline'
        script: |
          Write-Host "Current Directory: $(Get-Location)"
          Write-Host "`nListing all files and folders:"
          $currentPath = Get-Location
          Write-Host "`nUsing path: $currentPath"
          Get-ChildItem -Path $currentPath -Recurse | Select-Object FullName
        workingDirectory: '$(System.DefaultWorkingDirectory)'

    # Authentication setup
    - template: ../templates/auth-setup.yml
   
    # Execute release branch creation script
    - task: PowerShell@2
      name: createBranch
      inputs:
        targetType: 'filePath'
        filePath: '$(Build.SourcesDirectory)/DevOpsServices/pipelines/scripts/Create-ReleaseBranch.ps1'
        workingDirectory: '$(Build.SourcesDirectory)'
        arguments: >
          -ReleaseMajorVersion "${{ parameters.majorVersion }}"
          -ReleaseMinorVersion "${{ parameters.minorVersion }}"
          -ReleasePatchVersion "${{ parameters.patchVersion }}"
          -SourceBranch "${{ parameters.sourceBranch }}"
          -Organization "${{ parameters.organization }}"
          -Project "${{ parameters.project }}"
          -Repository "${{ parameters.repository }}"
          -DaysToLookBack ${{ parameters.daysToLookBack }}
          -TeamsChannelWebUrl "$(TEAMS_CHANNEL_WEB_URL)"
          -SendTeamsNotification $${{ parameters.sendTeamsNotification }}        
      env:
        ARM_CLIENT_ID: $(ARM_CLIENT_ID)
        ARM_CLIENT_SECRET: $(ARM_CLIENT_SECRET)
        ARM_TENANT_ID: $(ARM_TENANT_ID)
        TEAMS_CHANNEL_WEB_URL: $(TEAMS_CHANNEL_WEB_URL)
        TEAMS_NOTIFICATION_USERNAME: $(TEAMS_NOTIFICATION_USERNAME)
        TEAMS_NOTIFICATION_PASSWORD: $(TEAMS_NOTIFICATION_PASSWORD)
        TEAMS_CLIENT_ID: $(TEAMS_CLIENT_ID)
        TEAMS_CLIENT_SECRET: $(TEAMS_CLIENT_SECRET)
        TEAMS_TAGS: $(TEAMS_TAGS)

    # Display created branch name
    - powershell: |
        Write-Host "Created release branch: $(createBranch.ReleaseBranchName)"
      displayName: 'Display Branch Name'
```

**Checkout Options:**
- `persistCredentials: true` → Keep Git credentials for subsequent operations
- `fetchDepth: 0` → Full history (required for branch operations)

**Output Variables:**
Script sets output variables that can be used in subsequent stages:
- `$(createBranch.ReleaseBranchName)` → Created branch name
- `$(createBranch.ReleaseVersion)` → Full version string
- `$(createBranch.ReleaseNotesCount)` → Number of release notes

---

## Script Create-release-branch-ps1

### Purpose
PowerShell script that performs the core work: creates release branch, generates changelog from pull requests, and sends Teams notifications.

### Parameters

```powershell
param (
    [Parameter(Mandatory=$true)]
    [string]$ReleaseMajorVersion,
    
    [Parameter(Mandatory=$true)]
    [string]$ReleaseMinorVersion,
    
    [Parameter(Mandatory=$true)]
    [string]$ReleasePatchVersion,
    
    [Parameter(Mandatory=$false)]
    [string]$SourceBranch = "main",
    
    [Parameter(Mandatory=$true)]
    [string]$Organization,
    
    [Parameter(Mandatory=$true)]
    [string]$Project,
    
    [Parameter(Mandatory=$true)]
    [string]$Repository,
    
    [Parameter(Mandatory=$false)]
    [string]$ProjectPrefix = "platform-services",
    
    [Parameter(Mandatory=$false)]
    [int]$DaysToLookBack = 8,
    
    [Parameter(Mandatory=$false)]
    [string]$TeamsChannelWebUrl,
    
    [Parameter(Mandatory=$false)]
    [bool]$SendTeamsNotification = $false
)
```

### Main Execution Flow

```powershell
try {
    # 1. Set version and validate environment
    $version = "$ReleaseMajorVersion.$ReleaseMinorVersion.$ReleasePatchVersion"
    $Project = $Project.Trim()
    $Repository = $Repository.Trim()
    
    # Validate required environment variables
    $requiredEnvVars = @("ARM_CLIENT_ID", "ARM_CLIENT_SECRET", "ARM_CLIENT_OBJECT_ID", "ARM_TENANT_ID")
    foreach ($envVar in $requiredEnvVars) {
        if ([string]::IsNullOrEmpty((Get-Item "env:$envVar" -ErrorAction SilentlyContinue).Value)) {
            throw "Required environment variable $envVar is not set"
        }
    }
    
    # 2. Get authentication token and initialize Git
    $token = Get-DevOpsAuthToken
    Test-GitRepository
    Initialize-GitConfiguration -Token $token -Organization $Organization -Project $Project -Repository $Repository
    
    # 3. Look up Project and Repository IDs
    $projectId = Get-ProjectId -Organization $Organization -ProjectName $Project -Token $token
    $repositoryId = Get-RepositoryId -Organization $Organization -ProjectId $projectId -RepositoryName $Repository -Token $token
    
    # 4. Create release branch
    $branchInfo = New-ReleaseBranch -Version $version -SourceBranch $SourceBranch -Organization $Organization -ProjectId $projectId -RepositoryId $repositoryId
    $branchName = $branchInfo.BranchName
    $tempDir = $branchInfo.TempDir
    
    # 5. Get completed pull requests and process work items
    $pullRequests = Get-CompletedPullRequests -Organization $Organization -ProjectId $projectId -RepositoryId $repositoryId -DaysToLookBack $DaysToLookBack -Token $token
    
    $releaseNotes = @()
    foreach ($pr in $pullRequests) {
        $workItems = Get-WorkItemsForPullRequest -Organization $Organization -ProjectId $projectId -RepositoryId $repositoryId -PullRequestId $pr.pullRequestId -Token $token
        
        foreach ($workItem in $workItems) {
            $workItemDetails = Get-WorkItemDetails -Organization $Organization -ProjectId $projectId -WorkItemId $workItem.id -Token $token
            
            # Filter: Fluidity Request Form (all states) OR Bug (Resolved/Done/Closed)
            if ($workItemDetails.fields.'System.WorkItemType' -eq 'Fluidity Request Form') {
                $formattedInfo = Format-ReleaseNotes -PullRequestInfo $pr -WorkItemInfo $workItemDetails
                $releaseNotes += $formattedInfo
            }
            elseif ($workItemDetails.fields.'System.WorkItemType' -eq 'Bug' -and 
                   ($workItemDetails.fields.'System.State' -in @('Resolved', 'Done', 'Closed'))) {
                $formattedInfo = Format-ReleaseNotes -PullRequestInfo $pr -WorkItemInfo $workItemDetails
                $releaseNotes += $formattedInfo
            }
        }
    }
    
    # 6. Export changelog
    $changelogPath = Join-Path $tempDir "changelog.md"
    if ($releaseNotes.Count -gt 0) {
        $markdownContent = Export-ReleaseNotesToMarkdown -ReleaseNotes $releaseNotes -OutputPath $changelogPath -Organization $Organization -Project $Project
        Commit-ChangelogToReleaseBranch -ChangelogPath $changelogPath -BranchName $branchName -TempDir $tempDir
        
        # 7. Send Teams notification (optional)
        if ($SendTeamsNotification) {
            $token = Get-TeamsToken
            $channelInfo = Get-TeamsChannelInfo -TeamsUrl $TeamsChannelWebUrl
            Send-TeamsChannelMessage -TeamId $channelInfo.TeamId -ChannelId $channelInfo.ChannelId -MarkdownContent $markdownContent -Repository $Repository -ReleaseVersion $version -Token $token
        }
    }
    else {
        # Create empty changelog
        $emptyChangelogContent = "# Changelog`n`n## Version $version`nRelease Date: $(Get-Date -Format "yyyy-MM-dd")`n`nNo release notes available for this version."
        Set-Content -Path $changelogPath -Value $emptyChangelogContent -Encoding UTF8
        Commit-ChangelogToReleaseBranch -ChangelogPath $changelogPath -BranchName $branchName -TempDir $tempDir
    }
    
    # 8. Set output variables
    Write-Host "##vso[task.setvariable variable=ReleaseBranchName;isoutput=true]$branchName"
    Write-Host "##vso[task.setvariable variable=ReleaseVersion;isoutput=true]$version"
    Write-Host "##vso[task.setvariable variable=ReleaseNotesCount;isoutput=true]$($releaseNotes.Count)"
}
catch {
    Write-Error "Script execution failed: $_"
    exit 1
}
finally {
    # Cleanup Git credentials
    if (Test-Path "$HOME/.git-credentials") {
        Remove-Item "$HOME/.git-credentials" -Force
    }
}
```

---

## Authentication Functions

### Get-DevOpsAuthToken

Gets OAuth 2.0 access token for Azure DevOps API:

```powershell
function Get-DevOpsAuthToken {
    try {
        $resource = "499b84ac-1321-427f-aa17-267ca6975798"
        $authUrl = "https://login.microsoftonline.com/$env:ARM_TENANT_ID/oauth2/token"

        $body = @{
            grant_type    = "client_credentials"
            client_id     = $env:ARM_CLIENT_ID
            client_secret = $env:ARM_CLIENT_SECRET
            resource      = $resource
        }

        $response = Invoke-RestMethod -Method Post -Uri $authUrl -Body $body
        return $response.access_token
    }
    catch {
        Write-Error "Failed to get Azure DevOps token: $_"
        throw
    }
}
```

**OAuth Flow:**
1. Token endpoint: `https://login.microsoftonline.com/{tenant}/oauth2/token`
2. Grant type: `client_credentials` (service principal)
3. Resource: `499b84ac-1321-427f-aa17-267ca6975798` (Azure DevOps)
4. Returns bearer token valid for ~1 hour

### Get-TeamsToken

Gets OAuth 2.0 access token for Microsoft Graph API (Teams):

```powershell
function Get-TeamsToken {
    try {
        $tenantId = "$env:ARM_TENANT_ID"
        $clientId = "$env:TEAMS_CLIENT_ID"
        $username = "$env:TEAMS_NOTIFICATION_USERNAME"
        $password = "$env:TEAMS_NOTIFICATION_PASSWORD"
        $clientSecret = "$env:TEAMS_CLIENT_SECRET"

        $body = @{
            grant_type = "password"
            client_id = $clientId
            client_secret = $clientSecret
            resource = "https://graph.microsoft.com/"
            username = $username
            password = $password
            scope = "ChannelMessage.Send User.Read"
        }
       
        $uri = "https://login.microsoftonline.com/$tenantId/oauth2/token"
        $response = Invoke-RestMethod -Uri $uri -Method POST -Body $body
       
        return $response.access_token
    }
    catch {
        Write-Error "Failed to get Teams token: $_"
        throw
    }
}
```

**OAuth Flow:**
1. Token endpoint: `https://login.microsoftonline.com/{tenant}/oauth2/token`
2. Grant type: `password` (resource owner password credentials)
3. Resource: `https://graph.microsoft.com/`
4. Scopes: `ChannelMessage.Send`, `User.Read`
5. Returns bearer token valid for ~1 hour

**Why password grant?** Teams messages must be posted on behalf of a user (not service principal) to appear with proper identity.

---

## Git Operations

### Initialize-GitConfiguration

Configures Git for large repository operations:

```powershell
function Initialize-GitConfiguration {
    param (
        [string]$Token,
        [string]$Organization,
        [string]$Project,
        [string]$Repository
    )
    
    Write-Host "##[debug]Initializing Git configurations..."

    # Configure Git for large repositories
    git config --global core.longpaths true
    git config --global core.autocrlf false
    git config --global core.packedGitLimit 512m
    git config --global core.packedGitWindowSize 512m
    git config --global pack.windowMemory 512m
    git config --global pack.packSizeLimit 512m
    git config --global http.postBuffer 524288000

    # Set identity for commits
    git config --global user.email "azure-pipeline@bhg.com"
    git config --global user.name "Azure Pipeline"
}
```

**Configuration Explanations:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `core.longpaths` | `true` | Enable paths longer than 260 characters (Windows) |
| `core.autocrlf` | `false` | Disable automatic line ending conversion |
| `core.packedGitLimit` | `512m` | Increase packed Git object limit |
| `core.packedGitWindowSize` | `512m` | Increase pack window size |
| `pack.windowMemory` | `512m` | Increase pack memory |
| `pack.packSizeLimit` | `512m` | Increase pack size limit |
| `http.postBuffer` | `524288000` | Increase HTTP post buffer (500 MB) |
| `user.email` | `azure-pipeline@bhg.com` | Commit author email |
| `user.name` | `Azure Pipeline` | Commit author name |

**Why these settings?** Fabric repositories can be large with many files. Default Git settings may cause timeouts or failures.

### New-ReleaseBranch

Creates release branch from source branch:

```powershell
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
        # Get Azure AD token
        $tokenUrl = "https://login.microsoftonline.com/$env:ARM_TENANT_ID/oauth2/v2.0/token"
        $bodyParams = @{
            grant_type    = "client_credentials"
            client_id     = $env:ARM_CLIENT_ID
            client_secret = $env:ARM_CLIENT_SECRET
            scope         = "499b84ac-1321-427f-aa17-267ca6975798/.default"
        }

        $encodedBody = ($bodyParams.GetEnumerator() | ForEach-Object {
            "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
        }) -join "&"

        $authResult = Invoke-RestMethod -Method Post -Uri $tokenUrl -ContentType "application/x-www-form-urlencoded" -Body $encodedBody

        # Create temp directory
        $tempDir = Join-Path $env:TEMP "release_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        Set-Location $tempDir
        
        # Clone repository with inline token
        $repoUrl = "https://oauth2:$($authResult.access_token)@dev.azure.com/$Organization/$ProjectId/_git/$RepositoryId"
        git clone -b $SourceBranch --single-branch --depth=1 $repoUrl .
        if ($LASTEXITCODE -ne 0) { throw "Failed to clone repository" }
        
        # Create release branch
        $branchName = "release/$ProjectPrefix-v$Version"
        git checkout -b $branchName
        if ($LASTEXITCODE -ne 0) { throw "Failed to create branch $branchName" }
        
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
```

**Clone Options:**
- `-b $SourceBranch` → Clone specific branch only
- `--single-branch` → Don't fetch other branches
- `--depth=1` → Shallow clone (faster, only latest commit)

**Branch Naming:** `release/{ProjectPrefix}-v{Version}`
- Example: `release/platform-services-v1.0.0`

### Commit-ChangelogToReleaseBranch

Commits and pushes changelog to release branch:

```powershell
function Commit-ChangelogToReleaseBranch {
    param (
        [string]$ChangelogPath,
        [string]$BranchName,
        [string]$TempDir
    )
    
    Write-Host "##[section]Committing changelog to release branch"
    
    Set-Location $TempDir
    
    # Add changelog
    git add $ChangelogPath
    if ($LASTEXITCODE -ne 0) { throw "Failed to add changelog file" }
    
    # Commit
    git commit -m "docs: Add changelog for release $BranchName"
    if ($LASTEXITCODE -ne 0) { throw "Failed to commit changelog" }
    
    # Push
    git push origin $BranchName
    if ($LASTEXITCODE -ne 0) { throw "Failed to push changelog" }
    
    Write-Host "##[debug]Successfully committed and pushed changelog to $BranchName"
}
```

**Commit Message Format:** `docs: Add changelog for release {BranchName}`
- Prefix: `docs:` (Conventional Commits format)
- Descriptive message with branch name

---

## Pull Request and Work Item Processing

### Get-ProjectId

Retrieves project ID from project name:

```powershell
function Get-ProjectId {
    param (
        [string]$Organization,
        [string]$ProjectName,
        [string]$Token
    )
    
    $uri = "https://dev.azure.com/$Organization/_apis/projects?api-version=7.0"
    $response = Invoke-AzDevOpsApi -Uri $uri -Token $Token
    
    $project = $response.value | Where-Object { $_.name -eq $ProjectName }
    
    if (-not $project) {
        throw "Project '$ProjectName' not found"
    }
    
    return $project.id
}
```

### Get-RepositoryId

Retrieves repository ID from repository name:

```powershell
function Get-RepositoryId {
    param (
        [string]$Organization,
        [string]$ProjectId,
        [string]$RepositoryName,
        [string]$Token
    )
    
    $uri = "https://dev.azure.com/$Organization/$ProjectId/_apis/git/repositories?api-version=7.0"
    $response = Invoke-AzDevOpsApi -Uri $uri -Token $Token
    
    $repository = $response.value | Where-Object { $_.name -eq $RepositoryName }
    
    if (-not $repository) {
        throw "Repository '$RepositoryName' not found"
    }
    
    return $repository.id
}
```

### Get-CompletedPullRequests

Retrieves completed pull requests within date range:

```powershell
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
    
    $fromDate = $startDate.ToString("yyyy-MM-dd")
    $toDate = $endDate.ToString("yyyy-MM-dd")
    
    # Query completed PRs targeting main branch
    $uri = "https://dev.azure.com/$Organization/$ProjectId/_apis/git/repositories/$RepositoryId/pullrequests?searchCriteria.status=completed&searchCriteria.minTime=$fromDate&searchCriteria.targetRefName=refs/heads/main&api-version=7.1"
    
    $pullRequests = Invoke-AzDevOpsApi -Uri $uri -Token $Token
    
    if ($pullRequests -and $pullRequests.value) {
        # Filter by completion date
        $filteredPRs = $pullRequests.value | Where-Object {
            (Get-Date $_.closedDate) -ge $startDate -and (Get-Date $_.closedDate) -le $endDate
        }
        
        return $filteredPRs
    }
    
    return @()
}
```

**Query Parameters:**
- `searchCriteria.status=completed` → Only merged PRs
- `searchCriteria.minTime={fromDate}` → PRs completed after date
- `searchCriteria.targetRefName=refs/heads/main` → PRs merged to main only

**Why target main?** Release branches should only include changes already merged to main (tested code).

### Get-WorkItemsForPullRequest

Retrieves work items linked to pull request:

```powershell
function Get-WorkItemsForPullRequest {
    param (
        [string]$Organization,
        [string]$ProjectId,
        [string]$RepositoryId,
        [int]$PullRequestId,
        [string]$Token
    )
    
    $uri = "https://dev.azure.com/$Organization/$ProjectId/_apis/git/repositories/$RepositoryId/pullRequests/$PullRequestId/workitems?api-version=7.1"
    
    $workItems = Invoke-AzDevOpsApi -Uri $uri -Token $Token
    
    if ($workItems -and $workItems.value) {
        return $workItems.value
    }
    
    return @()
}
```

**Work Item Linking:**
- Developers link work items to PRs during code review
- Format: `#1234` in PR description or commits
- Azure DevOps automatically creates associations

### Get-WorkItemDetails

Retrieves full work item details including custom fields:

```powershell
function Get-WorkItemDetails {
    param (
        [string]$Organization,
        [string]$ProjectId,
        [int]$WorkItemId,
        [string]$Token
    )
    
    $uri = "https://dev.azure.com/$Organization/$ProjectId/_apis/wit/workitems/$WorkItemId`?`$expand=all&api-version=7.1"
    
    $workItem = Invoke-AzDevOpsApi -Uri $uri -Token $Token
    
    return $workItem
}
```

**Expand Parameter:**
- `$expand=all` → Include all fields, relations, and history
- Required to access custom fields (`Custom.ChangeType`, `Custom.ReleaseNotes`, etc.)

---

## Changelog Generation

### Format-ReleaseNotes

Extracts and formats release note information from work item:

```powershell
function Format-ReleaseNotes {
    param (
        [PSCustomObject]$PullRequestInfo,
        [PSCustomObject]$WorkItemInfo
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Extract custom fields
    $workItemType = $WorkItemInfo.fields.'System.WorkItemType'
    $changeType = $WorkItemInfo.fields.'Custom.ChangeType'
    $releaseNotes = $WorkItemInfo.fields.'Custom.ReleaseNotes'
    $deployedVersion = $WorkItemInfo.fields.'Custom.DeployedReleaseVersion'
    $releaseDate = $WorkItemInfo.fields.'Custom.ReleaseDate'
    
    # Use current version if not set
    if ([string]::IsNullOrEmpty($deployedVersion)) {
        $deployedVersion = "$ReleaseMajorVersion.$ReleaseMinorVersion.$ReleasePatchVersion"
    }
    
    # Use current date if not set
    if ([string]::IsNullOrEmpty($releaseDate)) {
        $releaseDate = Get-Date -Format "yyyy-MM-dd"
    }
    
    return [PSCustomObject]@{
        WorkItemId = $WorkItemInfo.id
        WorkItemType = $workItemType
        Title = $WorkItemInfo.fields.'System.Title'
        CommitId = $null
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
}
```

**Custom Fields Used:**
- `Custom.ChangeType` → Type of change (Breaking/Feature/Bug Fix/etc.)
- `Custom.ReleaseNotes` → User-written description of changes
- `Custom.DeployedReleaseVersion` → Version this change is included in
- `Custom.ReleaseDate` → Date of release

**Fallback Values:**
- If `DeployedReleaseVersion` is empty → Use current release version
- If `ReleaseDate` is empty → Use current date

### Export-ReleaseNotesToMarkdown

Generates markdown changelog file:

```powershell
function Export-ReleaseNotesToMarkdown {
    param (
        [Array]$ReleaseNotes,
        [string]$OutputPath = "changelog.md",
        [string]$Organization,
        [string]$Project
    )
    
    # Group by version
    $groupedNotes = $ReleaseNotes | Group-Object -Property DeployedVersion
    
    # Define emojis using Unicode
    $breakingEmoji = [char]::ConvertFromUtf32(0x1F4A5)  # 💥
    $featureEmoji = [char]::ConvertFromUtf32(0x2728)    # ✨
    $fixEmoji = [char]::ConvertFromUtf32(0x1F527)       # 🔧
    $docsEmoji = [char]::ConvertFromUtf32(0x1F4DD)      # 📝
    $internalEmoji = [char]::ConvertFromUtf32(0x26A1)   # ⚡
    $bulletEmoji = [char]::ConvertFromUtf32(0x2022)     # •
    $unknownEmoji = [char]::ConvertFromUtf32(0x2753)    # ❓
    
    # Create header
    $markdownContent = @"
# Changelog

The following contains all major, minor, and patch version release notes.

$breakingEmoji Breaking change!

$featureEmoji New Functionality

$fixEmoji Bug Fix

$docsEmoji Documentation Update

$internalEmoji Internal Optimization

$unknownEmoji Unspecified Change Type


"@
    
    # Sort versions descending
    $sortedGroups = $groupedNotes | Sort-Object -Property Name -Descending
    
    foreach ($versionGroup in $sortedGroups) {
        $version = $versionGroup.Name
        $releaseDate = ($versionGroup.Group | Select-Object -First 1).ReleaseDate
        
        # Add version header
        $markdownContent += @"

## Version $version

Release Date: $releaseDate


"@
        
        # Add release notes
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
            
            # Clean HTML from release notes
            $cleanNotes = $note.ReleaseNotes
            if ($cleanNotes) {
                # Remove HTML tags
                $cleanNotes = $cleanNotes -replace '<div>', '' -replace '</div>', ''
                $cleanNotes = $cleanNotes -replace '<ul>', "`n"
                $cleanNotes = $cleanNotes -replace '</ul>', "`n"
                $cleanNotes = $cleanNotes -replace '<li>', '  * ' -replace '</li>', "`n"
                $cleanNotes = $cleanNotes -replace '<br>', "`n  "
                $cleanNotes = $cleanNotes -replace '<[/]?(p|span|b|i|strong|em|h\d)[^>]*>', ''
                $cleanNotes = $cleanNotes -replace '&quot;', '"'
                $cleanNotes = $cleanNotes -replace '<[^>]+>', ''
                $cleanNotes = $cleanNotes.Trim()
                $cleanNotes = $cleanNotes -replace '(\r?\n){3,}', "`n`n"
            } else {
                $cleanNotes = "No details provided"
            }
            
            $encodedProject = Format-GitUrl -value $Project
            
            # Add release note with work item link
            $markdownContent += "$bulletEmoji $icon $cleanNotes ([#$($note.WorkItemId)](https://dev.azure.com/$Organization/$encodedProject/_workitems/edit/$($note.WorkItemId)))`n"
            $markdownContent += "`n"
        }
    }
    
    # Write file with UTF-8 BOM
    $utf8WithBom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($OutputPath, $markdownContent, $utf8WithBom)
    
    return $markdownContent
}
```

**HTML Cleaning Process:**
Release notes may contain HTML formatting from Azure DevOps rich text editor. The function performs extensive cleaning:

1. **Remove div tags:** `<div>`, `</div>`
2. **Convert lists:** `<ul>`, `</ul>`, `<li>`, `</li>` → Markdown bullets
3. **Convert breaks:** `<br>` → Newline with indentation
4. **Remove formatting tags:** `<p>`, `<span>`, `<b>`, `<i>`, `<strong>`, `<em>`, `<h1-6>`
5. **Replace HTML entities:** `&quot;` → `"`
6. **Remove remaining HTML:** Any `<...>` tags
7. **Normalize whitespace:** Multiple blank lines → Single blank line

**UTF-8 with BOM:**
```powershell
$utf8WithBom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($OutputPath, $markdownContent, $utf8WithBom)
```

**Why BOM (Byte Order Mark)?** Ensures proper emoji rendering in Git and text editors.

---

## Teams Notification System

### Get-TeamsChannelInfo

Parses Teams channel URL to extract Team ID and Channel ID:

```powershell
function Get-TeamsChannelInfo {
    param ([string]$TeamsUrl)
    
    try {
        $channelInfo = @{
            TeamId = $null
            ChannelId = $null
            IsValid = $false
            ErrorMessage = ""
        }
        
        $uri = [Uri]::new($TeamsUrl)
        $queryParams = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
        
        # Get Team ID from query parameters
        $teamIdFromQuery = $queryParams["groupId"]
        if ($teamIdFromQuery) {
            $channelInfo.TeamId = $teamIdFromQuery
        }
        
        # Extract Channel ID from URL path
        # Pattern: /l/channel/ENCODED_CHANNEL_ID/CHANNEL_NAME
        if ($uri.AbsolutePath -match "/l/channel/([^/]+)/") {
            $rawChannelId = $matches[1]
            $decodedChannelId = [System.Web.HttpUtility]::UrlDecode($rawChannelId)
            $channelInfo.ChannelId = $decodedChannelId
        }
        
        # Validate extracted IDs
        $validationErrors = @()
        
        # Team ID should be GUID
        if (-not $channelInfo.TeamId -or $channelInfo.TeamId -notmatch "^[0-9a-fA-F-]{36}$") {
            $validationErrors += "Team ID invalid"
            $channelInfo.IsValid = $false
        }
        
        # Channel ID should start with "19:" and end with "@thread"
        if (-not $channelInfo.ChannelId -or $channelInfo.ChannelId -notmatch "^19:.*@thread") {
            $validationErrors += "Channel ID invalid"
            $channelInfo.IsValid = $false
        }
        
        if ($validationErrors.Count -eq 0) {
            $channelInfo.IsValid = $true
        } else {
            $channelInfo.ErrorMessage = $validationErrors -join "; "
        }
        
        return $channelInfo
    }
    catch {
        return @{
            TeamId = $null
            ChannelId = $null
            IsValid = $false
            ErrorMessage = "Exception: $($_.Exception.Message)"
        }
    }
}
```

**Teams URL Format:**
```
https://teams.microsoft.com/l/channel/19%3A...%40thread.tacv2/General?groupId=12345678-1234-1234-1234-123456789012&tenantId=...
```

**Extracted Components:**
- **Team ID:** From `groupId` query parameter (GUID format)
- **Channel ID:** From URL path, URL-decoded (format: `19:...@thread.tacv2` or `19:...@thread.skype`)

**Validation Rules:**
- Team ID: Must be 36-character GUID
- Channel ID: Must start with `19:` and end with `@thread`

### Get-TeamsChannelTags

Retrieves team tags for user mentions:

```powershell
function Get-TeamsChannelTags {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TeamId,
        
        [Parameter(Mandatory=$true)]
        [string]$Token
    )
    
    try {
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
        
        $tagsUrl = "https://graph.microsoft.com/v1.0/teams/$TeamId/tags"
        $response = Invoke-RestMethod -Uri $tagsUrl -Headers $headers -Method GET
        
        $tags = @()
        if ($response.value) {
            foreach ($tag in $response.value) {
                $tagInfo = @{
                    id = $tag.id
                    displayName = $tag.displayName
                    description = $tag.description
                    memberCount = $tag.memberCount
                    tagType = $tag.tagType
                    teamId = $TeamId
                }
                $tags += $tagInfo
            }
        }
        
        return $tags
    } catch {
        Write-Error "Failed to get team tags: $($_.Exception.Message)"
        return @()
    }
}
```

**Tags Usage:**
- Tags are groups of users (e.g., "Platform Team", "On-Call Engineers")
- Mentioning a tag notifies all members
- Script filters tags based on `$env:TEAMS_TAGS` (comma-separated list)

### Format-MarkdownForTeams

Converts markdown changelog to HTML for Teams:

```powershell
function Format-MarkdownForTeams {
    param(
        [string]$MarkdownContent,
        [string]$Repository,
        [string]$ReleaseVersion,
        [hashtable]$Emojis
    )
    
    try {
        # Define HTML entities for emojis
        $breakingEmoji = "&#x1F4A5;"    # 💥
        $featureEmoji = "&#x2728;"      # ✨
        $fixEmoji = "&#x1F527;"         # 🔧
        $docsEmoji = "&#x1F4DD;"        # 📝
        $internalEmoji = "&#x26A1;"     # ⚡
        $bulletEmoji = "&#x2022;"       # •
        $unknownEmoji = "&#x2753;"      # ❓
        $rocketEmoji = "&#x1F680;"      # 🚀
        
        # Create header
        $teamsHeader = @"
<p><strong>$rocketEmoji Release Notification</strong></p>
<p><strong>Repository:</strong> $Repository<br/>
<strong>Version:</strong> $ReleaseVersion<br/>
<strong>Release Date:</strong> $(Get-Date -Format "yyyy-MM-dd")</p>
<p><strong>Changelog</strong></p>
<ul>
<li> $breakingEmoji Breaking change!</li>
<li> $featureEmoji New Functionality</li>
<li> $fixEmoji Bug Fix</li>
<li> $docsEmoji Documentation Update</li>
<li> $internalEmoji Internal Optimization</li>
<li> $unknownEmoji Unspecified Change Type</li>
</ul>
"@
        
        # Parse markdown and convert to HTML
        $lines = $MarkdownContent -split '\r?\n'
        $versionContent = ""
        
        foreach ($line in $lines) {
            # Version headers: ## Version 1.0.0
            if ($line -match '^## Version (.+)$') {
                $versionNumber = $matches[1]
                $versionContent += "<h3>Version $versionNumber</h3>`n"
                continue
            }
            
            # Release date: Release Date: 2026-01-07
            if ($line -match '^Release Date: (.+)$') {
                $releaseDate = $matches[1]
                $versionContent += "<p>Release Date: $releaseDate</p>`n"
                continue
            }
            
            # Release notes: • ✨ Note text ([#123](link))
            if ($line -match '^. (.+)$') {
                $noteContent = $matches[1]
                
                # Replace Unicode emojis with HTML entities
                $noteContent = $noteContent -replace [char]::ConvertFromUtf32(0x1F4A5), $breakingEmoji
                $noteContent = $noteContent -replace [char]::ConvertFromUtf32(0x2728), $featureEmoji
                $noteContent = $noteContent -replace [char]::ConvertFromUtf32(0x1F527), $fixEmoji
                $noteContent = $noteContent -replace [char]::ConvertFromUtf32(0x1F4DD), $docsEmoji
                $noteContent = $noteContent -replace [char]::ConvertFromUtf32(0x26A1), $internalEmoji
                $noteContent = $noteContent -replace [char]::ConvertFromUtf32(0x2753), $unknownEmoji
                
                # Convert markdown links to HTML
                $noteContent = Convert-MarkdownLinksToHtml -Text $noteContent
                
                # Selective HTML encoding (preserve entities)
                $noteContent = $noteContent -replace '&(?!#|[a-zA-Z]+;)', '&amp;'
                
                $versionContent += "<p>$noteContent</p>`n"
                continue
            }
        }
        
        # Combine header and content
        $finalContent = $teamsHeader + $versionContent
        
        return $finalContent
    }
    catch {
        Write-Warning "Error formatting markdown for Teams: $_"
        return "<p>Release Notification - $ReleaseVersion</p>"
    }
}
```

**Conversion Process:**

1. **Header:** Repository, version, date with emoji legend
2. **Version sections:** `##` → `<h3>`
3. **Release dates:** Plain text → `<p>`
4. **Release notes:** Bullet points → `<p>` with HTML emojis
5. **Markdown links:** `[text](url)` → `<a href="url">text</a>`
6. **HTML encoding:** Selective (preserve emoji entities)

### Convert-MarkdownLinksToHtml

Converts markdown-style links to HTML anchor tags:

```powershell
function Convert-MarkdownLinksToHtml {
    param([string]$Text)
    
    try {
        $linkPattern = '\[([^\[\]]+)\]\(([^()]+)\)'
        
        $result = $Text
        while ($result -match $linkPattern) {
            $fullMatch = $matches[0]
            $linkText = $matches[1]
            $linkUrl = $matches[2]
            
            $htmlLink = "<a href=`"$linkUrl`">$linkText</a>"
            $result = $result -replace [regex]::Escape($fullMatch), $htmlLink
        }
        
        return $result
    }
    catch {
        Write-Warning "Error converting markdown links: $_"
        return $Text
    }
}
```

**Example:**
- Input: `Add feature ([#1234](https://dev.azure.com/org/project/_workitems/edit/1234))`
- Output: `Add feature (<a href="https://dev.azure.com/org/project/_workitems/edit/1234">#1234</a>)`

### Send-TeamsChannelMessage

Sends formatted message to Teams channel:

```powershell
function Send-TeamsChannelMessage {
    param(
        [string]$TeamId,
        [string]$ChannelId,
        [Parameter(Mandatory=$true)]
        [string]$MarkdownContent,
        [string]$Repository,
        [string]$ReleaseVersion,
        [string]$Token
    )
    
    try {
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json; charset=utf-8"
        }
        
        # Get team tags
        $availableTags = Get-TeamsChannelTags -TeamId $TeamId -Token $Token
        
        # Format content
        $formattedContent = Format-MarkdownForTeams -MarkdownContent $MarkdownContent -Repository $Repository -ReleaseVersion $ReleaseVersion
        
        # Create mentions
        $mentions = @()
        $mentionId = 0
        $tagMentionsNotification = @()
        
        foreach ($tag in $availableTags) {
            # Check if tag is in TEAMS_TAGS environment variable
            if ($env:TEAMS_TAGS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $tag.displayName }) {
                $mention = @{
                    "id" = $mentionId
                    "mentionText" = $tag.displayName
                    "mentioned" = @{
                        "tag" = @{
                            "id" = $tag.id
                            "displayName" = $tag.displayName
                        }
                    }
                }
                
                $mentions += $mention
                $tagMentionsNotification += "<at id=`"$mentionId`">$($tag.displayName)</at>"
                $mentionId++
            }
        }
        
        # Convert mentions to JSON
        $mentionsJson = if ($mentions.Count -eq 0) {
            $null
        } elseif ($mentions.Count -eq 1) {
            "[$($mentions | ConvertTo-Json -Depth 10)]"
        } else {
            $mentions | ConvertTo-Json -Depth 10
        }
        
        # Create footer
        $ccEmoji = "&#x1F4E2;"  # 📢
        $robotEmoji = "&#x1F916;"  # 🤖
        
        $ccText = if ($tagMentionsNotification.Count -gt 0) {
            $tagMentionsNotification -join ", "
        } else {
            "No tags available"
        }
        
        $ccFooter = @"
<hr/>
<p><strong>$ccEmoji CC (Notifications):</strong> $ccText</p>
<hr/>
<p><em>$robotEmoji Automated release notification from Azure DevOps</em></p>
"@
        
        $formattedContent += $ccFooter
        
        # Escape quotes for JSON
        $escapedContent = $formattedContent -replace '"', '\"'
        
        # Create message payload
        $bodyJson = if ($mentions.Count -gt 0) {
            @"
{
    "subject": "Release Notification - $ReleaseVersion",
    "importance": "high",
    "body": {
        "contentType": "html",
        "content": "$escapedContent"
    },
    "mentions": $mentionsJson
}
"@
        } else {
            @"
{
    "subject": "Release Notification - $ReleaseVersion",
    "importance": "high",
    "body": {
        "contentType": "html",
        "content": "$escapedContent"
    }
}
"@
        }
        
        # Send message
        $messageUrl = "https://graph.microsoft.com/beta/teams/$TeamId/channels/$ChannelId/messages"
        $response = Invoke-RestMethod -Uri $messageUrl -Method POST -Headers $headers -Body $bodyJson
        
        Write-Host "Message sent successfully to Teams channel"
        return $true
    }
    catch {
        Write-Error "Failed to send Teams message: $($_.Exception.Message)"
        return $false
    }
}
```

**Message Structure:**

```json
{
  "subject": "Release Notification - 1.0.0",
  "importance": "high",
  "body": {
    "contentType": "html",
    "content": "<p>HTML content here</p>"
  },
  "mentions": [
    {
      "id": 0,
      "mentionText": "Platform Team",
      "mentioned": {
        "tag": {
          "id": "tag-guid",
          "displayName": "Platform Team"
        }
      }
    }
  ]
}
```

**API Endpoint:**
```
POST https://graph.microsoft.com/beta/teams/{teamId}/channels/{channelId}/messages
```

**Why beta endpoint?** Channel message posting with mentions requires beta API version.

---

## Work Item Filtering Strategy

### Filtered Work Item Types

Only specific work item types are included in changelog:

**1. Fluidity Request Form (All States)**
```powershell
if ($workItemDetails.fields.'System.WorkItemType' -eq 'Fluidity Request Form') {
    $formattedInfo = Format-ReleaseNotes -PullRequestInfo $pr -WorkItemInfo $workItemDetails
    $releaseNotes += $formattedInfo
}
```

**Why all states?** Fluidity Request Forms are feature requests that should always be documented, regardless of state.

**2. Bug (Resolved/Done/Closed Only)**
```powershell
elseif ($workItemDetails.fields.'System.WorkItemType' -eq 'Bug' -and 
       ($workItemDetails.fields.'System.State' -in @('Resolved', 'Done', 'Closed'))) {
    $formattedInfo = Format-ReleaseNotes -PullRequestInfo $pr -WorkItemInfo $workItemDetails
    $releaseNotes += $formattedInfo
}
```

**Why specific states?** Only completed bugs should be documented. Active/New bugs aren't ready for release.

### Excluded Work Item Types

The following work item types are **not** included in changelog:

- **Task:** Internal development tasks (not user-facing)
- **User Story:** Covered by Fluidity Request Forms
- **Epic:** Too high-level for changelog
- **Feature:** Covered by Fluidity Request Forms
- **Test Case:** Internal testing (not user-facing)
- **Bug (Active/New/In Progress):** Not yet resolved

### Work Item State Transitions

```
Bug Lifecycle:
New → Active → In Progress → Resolved → Closed
                                ↑           ↑
                        Included in changelog
```

**Why this approach?** Ensures only completed, tested work is documented in release notes.

---

## Markdown to HTML Conversion

### HTML Cleaning from Azure DevOps

Azure DevOps work items use rich text editor that generates HTML. This HTML must be cleaned for markdown:

```powershell
# Remove div tags
$cleanNotes = $cleanNotes -replace '<div>', '' -replace '</div>', ''

# Convert lists to markdown
$cleanNotes = $cleanNotes -replace '<ul>', "`n"
$cleanNotes = $cleanNotes -replace '</ul>', "`n"
$cleanNotes = $cleanNotes -replace '<li>', '  * ' -replace '</li>', "`n"

# Convert breaks to newlines with indentation
$cleanNotes = $cleanNotes -replace '<br>', "`n  "

# Remove formatting tags
$cleanNotes = $cleanNotes -replace '<[/]?(p|span|b|i|strong|em|h\d)[^>]*>', ''

# Replace HTML entities
$cleanNotes = $cleanNotes -replace '&quot;', '"'

# Remove remaining HTML tags
$cleanNotes = $cleanNotes -replace '<[^>]+>', ''

# Trim and normalize whitespace
$cleanNotes = $cleanNotes.Trim()
$cleanNotes = $cleanNotes -replace '(\r?\n){3,}', "`n`n"
```

**Example:**

**Input (from Azure DevOps):**
```html
<div>Add new feature for <b>data orchestration</b></div>
<ul>
  <li>Support for parallel execution</li>
  <li>Error handling with retries</li>
</ul>
```

**Output (cleaned markdown):**
```markdown
Add new feature for data orchestration

  * Support for parallel execution
  * Error handling with retries
```

### Emoji Encoding Strategies

**Three different contexts require different emoji encoding:**

**1. PowerShell Console/Logs:**
```powershell
$rocketEmoji = [char]::ConvertFromUtf32(0x1F680)  # 🚀
Write-Host "##[section]$rocketEmoji Creating release"
```

**2. Markdown Files (UTF-8 with BOM):**
```powershell
$markdownContent = "# Changelog`n`n🚀 Release v1.0.0"
$utf8WithBom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($OutputPath, $markdownContent, $utf8WithBom)
```

**3. Teams HTML Messages:**
```powershell
$rocketEmoji = "&#x1F680;"  # HTML entity
$htmlContent = "<p>$rocketEmoji Release Notification</p>"
```

**Why different approaches?**
- Console: PowerShell native emoji support
- Markdown: Git/text editor compatibility requires UTF-8 with BOM
- Teams: HTML entities ensure reliable rendering across clients

---

## Teams Message Formatting

### Message Structure

Teams channel messages use specific HTML structure:

```html
<p><strong>🚀 Release Notification</strong></p>
<p><strong>Repository:</strong> PlatformServices-Fabric<br/>
<strong>Version:</strong> 1.0.0<br/>
<strong>Release Date:</strong> 2026-01-07</p>

<p><strong>Changelog</strong></p>
<ul>
<li> 💥 Breaking change!</li>
<li> ✨ New Functionality</li>
<li> 🔧 Bug Fix</li>
<li> 📝 Documentation Update</li>
<li> ⚡ Internal Optimization</li>
<li> ❓ Unspecified Change Type</li>
</ul>

<h3>Version 1.0.0</h3>
<p>Release Date: 2026-01-07</p>

<p>✨ Add new data pipeline orchestration framework (<a href="...">work item link</a>)</p>
<p>🔧 Fix memory leak in lakehouse sync operation (<a href="...">work item link</a>)</p>

<hr/>
<p><strong>📢 CC (Notifications):</strong> <at id="0">Platform Team</at>, <at id="1">On-Call</at></p>
<hr/>
<p><em>🤖 Automated release notification from Azure DevOps</em></p>
```

### Tag Mentions

Tag mentions notify all members of a team tag:

```json
{
  "mentions": [
    {
      "id": 0,
      "mentionText": "Platform Team",
      "mentioned": {
        "tag": {
          "id": "19:...",
          "displayName": "Platform Team"
        }
      }
    }
  ]
}
```

**In HTML body:**
```html
<at id="0">Platform Team</at>
```

**Tag Filtering:**
Environment variable `TEAMS_TAGS` contains comma-separated list of tags to mention:
```
TEAMS_TAGS=Platform Team,On-Call Engineers,DevOps Team
```

Only tags matching this list will be mentioned in the message.

### Message Importance

```json
{
  "importance": "high"
}
```

**Options:**
- `low` → No special indication
- `normal` → Default importance
- `high` → Red exclamation mark in Teams

Release notifications use `high` to ensure visibility.

---

## Error Handling and Cleanup

### Try-Catch-Finally Pattern

Script uses comprehensive error handling:

```powershell
try {
    # Main execution
    $version = "$ReleaseMajorVersion.$ReleaseMinorVersion.$ReleasePatchVersion"
    
    # Validate environment variables
    $requiredEnvVars = @("ARM_CLIENT_ID", "ARM_CLIENT_SECRET", "ARM_CLIENT_OBJECT_ID", "ARM_TENANT_ID")
    foreach ($envVar in $requiredEnvVars) {
        if ([string]::IsNullOrEmpty((Get-Item "env:$envVar" -ErrorAction SilentlyContinue).Value)) {
            throw "Required environment variable $envVar is not set"
        }
    }
    
    # Perform operations
    $token = Get-DevOpsAuthToken
    $branchInfo = New-ReleaseBranch -Version $version -SourceBranch $SourceBranch ...
    $pullRequests = Get-CompletedPullRequests ...
    # ... more operations
    
    # Set output variables
    Write-Host "##vso[task.setvariable variable=ReleaseBranchName;isoutput=true]$branchName"
}
catch {
    # Error handling
    Write-Error "$crossEmoji Script execution failed: $_"
    Write-Error "Stack Trace: $($_.ScriptStackTrace)"
    exit 1
}
finally {
    # Cleanup (always executes)
    if (Test-Path "$HOME/.git-credentials") {
        Remove-Item "$HOME/.git-credentials" -Force
    }
    
    if (Get-Location -Stack -ErrorAction SilentlyContinue) {
        Pop-Location
    }
}
```

### Environment Variable Validation

Script validates required environment variables before proceeding:

```powershell
$requiredEnvVars = @("ARM_CLIENT_ID", "ARM_CLIENT_SECRET", "ARM_CLIENT_OBJECT_ID", "ARM_TENANT_ID")
foreach ($envVar in $requiredEnvVars) {
    if ([string]::IsNullOrEmpty((Get-Item "env:$envVar" -ErrorAction SilentlyContinue).Value)) {
        Write-Host "##[error]$crossEmoji Required environment variable $envVar is not set"
        throw "Required environment variable $envVar is not set"
    } else {
        Write-Host "##[debug]$checkEmoji $envVar is set"
    }
}
```

**Why validate?** Fail fast with clear error message instead of cryptic authentication failures later.

### Git Credential Cleanup

Git credentials must be cleaned up to prevent leakage:

```powershell
finally {
    if (Test-Path "$HOME/.git-credentials") {
        Remove-Item "$HOME/.git-credentials" -Force
        Write-Host "##[debug]$checkEmoji Removed git credentials"
    }
}
```

**Why in finally?** Ensures cleanup even if script fails partway through.

### API Error Handling

API wrapper returns null on error instead of throwing:

```powershell
function Invoke-AzDevOpsApi {
    # ... setup ...
    
    try {
        $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -Body $bodyJson
        return $response
    }
    catch {
        Write-Host "##[error]API call failed: $_"
        Write-Host "##[error]Status Code: $($_.Exception.Response.StatusCode.value__)"
        
        if ($_.ErrorDetails.Message) {
            Write-Host "##[error]Error Details: $($_.ErrorDetails.Message)"
        }
        
        return $null  # Return null instead of throwing
    }
}
```

**Why return null?** Allows script to continue with degraded functionality (e.g., empty changelog if API calls fail).

---

## Integration Workflows

### Complete Release Workflow

```
1. Developer completes feature/bug work
   └── Creates pull request targeting main

2. Code review and testing
   └── PR approved and merged to main

3. Work item linked to PR
   └── Fluidity Request Form or Bug associated

4. Release Manager decides to create release
   └── Runs Create-release-branch.yml pipeline
   └── Parameters: version numbers, source branch, days to look back

5. Pipeline executes:
   ├── Validates version numbers
   ├── Authenticates (Azure DevOps + Microsoft Graph)
   ├── Creates release branch from main
   ├── Queries completed PRs (last N days)
   ├── Extracts work items from PRs
   ├── Filters work items (Fluidity Request Forms, resolved Bugs)
   ├── Generates changelog.md
   ├── Commits changelog to release branch
   └── Sends Teams notification (optional)

6. Release branch available
   └── release/platform-services-v1.0.0

7. Deploy-release-subdomain.yml can now deploy this release
   └── Copies release branch to target subdomains
```

### Integration with Release Promotion

The create release branch workflow integrates with release promotion:

**Create Release Branch** → Creates versioned release branch with changelog
**↓**
**Deploy Release Subdomain** → Copies release branch to target subdomains

**Workflow:**
1. Create release branch: `release/platform-services-v1.0.0` (in PlatformServices-Fabric)
2. Deploy to subdomains: Copies branch to DnA Claims, DnA Distribution, etc. repositories
3. Each subdomain deploys independently from their local release branch copy

### Changelog Evolution

Changelog accumulates changes across versions:

**Version 1.0.0:**
```markdown
## Version 1.0.0
Release Date: 2026-01-07

• ✨ Initial data pipeline framework (#1234)
• 🔧 Fix authentication bug (#1235)
```

**Version 1.1.0 (adds to existing changelog):**
```markdown
## Version 1.1.0
Release Date: 2026-01-14

• ✨ Add parallel execution support (#1240)
• 📝 Update deployment documentation (#1241)

## Version 1.0.0
Release Date: 2026-01-07

• ✨ Initial data pipeline framework (#1234)
• 🔧 Fix authentication bug (#1235)
```

**Why append?** Changelog file maintains complete version history.

---

## Conclusion

The Create Release Branch workflow provides a comprehensive automated solution for release management with the following capabilities:

**Key Features:**

1. **Automated Branch Creation**: Creates versioned release branches from source branches
2. **Pull Request Analysis**: Queries completed PRs within configurable date range
3. **Work Item Extraction**: Automatically extracts and filters work items from PRs
4. **Changelog Generation**: Generates formatted markdown with emojis and work item links
5. **Teams Integration**: Sends formatted HTML notifications with user mentions
6. **Semantic Versioning**: Enforces semantic versioning (major.minor.patch)
7. **Work Item Filtering**: Includes only Fluidity Request Forms and resolved Bugs
8. **Custom Fields**: Extracts change type, release notes, version, and date from work items
9. **HTML Cleaning**: Cleans Azure DevOps rich text HTML for markdown compatibility
10. **Multi-Format Emojis**: Handles emojis across console, markdown, and HTML contexts

**Workflow Summary:**

```
Manual Pipeline Trigger
    └── Validate version parameters
        └── Authenticate (Azure DevOps + Microsoft Graph)
            └── Create release branch from main
                └── Query completed pull requests (last N days)
                    └── Extract associated work items
                        └── Filter work items (Fluidity Request Forms, Bugs)
                            └── Generate changelog.md with emojis and links
                                └── Commit changelog to release branch
                                    └── Send Teams notification with mentions
                                        └── Output: Release branch ready for deployment
```

**Integration Points:**

- **Azure DevOps API**: Pull requests, work items, repository operations
- **Microsoft Graph API**: Teams channel messaging, tag mentions
- **Git Operations**: Branch creation, commit, push
- **Release Promotion**: Release branch consumed by Deploy-release-subdomain.yml

**Technical Complexity:**

- **Total Functions:** 25+ PowerShell functions
- **API Endpoints:** 10+ Azure DevOps APIs, 2+ Microsoft Graph APIs
- **Authentication Flows:** 2 OAuth 2.0 grant types
- **Encoding Formats:** 3 emoji encoding strategies
- **HTML Processing:** 10+ regex patterns for cleaning
- **Error Handling:** Comprehensive try-catch-finally with cleanup

The workflow represents a sophisticated automation solution that bridges development (pull requests, work items), version control (Git branches), and communication (Teams notifications) to provide a seamless release management experience.

---

**Document Version:** 1.0  
**Last Updated:** January 2026  
**Author:** Platform Services Team
