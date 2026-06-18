param (
    [Parameter(Mandatory=$true)]
    [string]$Organization,
    [Parameter(Mandatory=$true)]
    [string]$Project,
    [Parameter(Mandatory=$true)]
    [string]$Repository,
    [string]$Branch = "integration-platform-services",
    [string]$Directory = "src/fabric"
)

function Connect-FabricGit {
   param (
       [string]$Token,
       [string]$WorkspaceId,
       [string]$Organization,
       [string]$Project,
       [string]$Repository,
       [string]$Branch,
       [string]$Directory
   )
 
   $headers = @{
       "Authorization" = "Bearer $Token"
       "Content-Type" = "application/json"
   }
 
   $body = @{
       gitProviderDetails = @{
           organizationName = $Organization
           projectName = $Project
           gitProviderType = "AzureDevOps"
           repositoryName = $Repository
           branchName = $Branch
           directoryName = $Directory
       }
   }

   $bodyJson = ConvertTo-Json -InputObject $body -Depth 10 -Compress
   Write-Host "##[debug]Request body:"
   Write-Host $bodyJson

   try {
       $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git/connect"
       Write-Host "##[debug]Url: $url"
       
       $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $bodyJson -ContentType "application/json"
       return $response
   }
   catch {
       # Check if error is 409 WorkspaceAlreadyConnectedToGit
       if ($_.Exception.Response.StatusCode.value__ -eq 409) {
           $errorContent = $_.Exception.Response.GetResponseStream()
           $reader = New-Object System.IO.StreamReader($errorContent)
           $errorBody = $reader.ReadToEnd()
           $errorJson = $errorBody | ConvertFrom-Json
           
           if ($errorJson.errorCode -eq "WorkspaceAlreadyConnectedToGit") {
               Write-Host "##[debug]Workspace is already connected to Git. Proceeding..."
               return $errorJson  # Return error object to indicate already connected state
           }
       }
       
       # For other errors, throw the exception
       Write-Host "##[debug]Status Code: $($_.Exception.Response.StatusCode.value__)"
       Write-Host "##[debug]Status Description: $($_.Exception.Response.StatusDescription)"
       Write-Host "##[debug]Error Message: $($_.Exception.Message)"
       throw
   }
}

function Initialize-FabricGitConnection {
   param (
       [string]$Token,
       [string]$WorkspaceId,
       [ValidateSet('None', 'PreferRemote', 'PreferWorkspace')]
       [string]$InitializationStrategy = 'PreferWorkspace'  # Default to prefer workspace content
   )

   $headers = @{
       "Authorization" = "Bearer $Token"
       "Content-Type" = "application/json"
   }

   $body = @{
       initializationStrategy = $InitializationStrategy
   }

   $bodyJson = ConvertTo-Json -InputObject $body -Depth 10 -Compress
   Write-Host "##[debug]Request body:"
   Write-Host $bodyJson

   $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git/initializeConnection"
   Write-Host "##[debug]Initializing Fabric Git connection... (WorkspaceId: $WorkspaceId)"
   Write-Host "##[debug]Using initialization strategy: $InitializationStrategy"

   try {
       $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $bodyJson -ContentType "application/json"
       Write-Host "##[debug]Successfully initialized Git connection"
       return $response
   }
   catch {
       # Check if error is 409 WorkspaceGitConnectionAlreadyInitialized
       if ($_.Exception.Response.StatusCode.value__ -eq 409) {
           $errorContent = $_.Exception.Response.GetResponseStream()
           $reader = New-Object System.IO.StreamReader($errorContent)
           $errorBody = $reader.ReadToEnd()
           $errorJson = $errorBody | ConvertFrom-Json
           
           if ($errorJson.errorCode -eq "WorkspaceGitConnectionAlreadyInitialized") {
               Write-Host "##[debug]Connection between this workspace and Git has already been initialized. Proceeding..."
               return $errorJson  # Return error object to indicate already initialized state
           }
       }
       
       # For other errors, throw the exception
       Write-Host "##[debug]Status Code: $($_.Exception.Response.StatusCode.value__)"
       Write-Host "##[debug]Status Description: $($_.Exception.Response.StatusDescription)"
       Write-Host "##[debug]Error Message: $($_.Exception.Message)"
       throw
   }
}       

function Invoke-FabricGitCommit {
    param (
        [string]$Token,
        [string]$WorkspaceId,   
        [string]$Comment = "Initial commit from Fabric workspace"
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }

    $body = @{
        mode = "All"
        comment = $Comment
    }
   
    $bodyJson = ConvertTo-Json -InputObject $body -Depth 10 -Compress
   
    $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git/commitToGit"
    Write-Host "##[debug]Committing to Git..."
   
    try {
        $response = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $bodyJson -UseBasicParsing
       
        if ($response.StatusCode -eq 202) {
            Write-Host "##[debug]Commit request accepted"
            return $response.Headers['x-ms-operation-id']
        }
       
        throw "Unexpected status code: $($response.StatusCode)"
    }
    catch {
        Write-Error "Failed to commit to Git: $_"
        throw
    }
}


function Update-FabricFromGit {
    param (
        [string]$Token,
        [string]$WorkspaceId,
        [string]$RemoteCommitHash,
        [string]$WorkspaceHead
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }

    $body = @{
        workspaceHead = $WorkspaceHead  
        remoteCommitHash = $RemoteCommitHash
        conflictResolution = @{
            conflictResolutionType = "Workspace"
            conflictResolutionPolicy = "PreferWorkspace"
        }
        options = @{
            allowOverrideItems = $true
        }
    }
    $bodyJson = ConvertTo-Json -InputObject $body -Depth 10 -Compress

    Write-Host "##[debug]Request body:"
    Write-Host $bodyJson


    $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git/updateFromGit"

    Write-Host "##[debug]Initiating update from Git... (WorkspaceId: $WorkspaceId, RemoteCommitHash: $RemoteCommitHash)"

    try {
        $response = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $bodyJson -UseBasicParsing
       
        if ($response.StatusCode -eq 202) {
            Write-Host "##[debug]Update workspace from git, request accepted"
            return $response.Headers['x-ms-operation-id']
        }
        Write-Host "##[debug]Successfully initiated update from Git"
        return $response
    }
    catch {
        Write-Error "Failed to update from Git: $_"
        throw
    }
}

function Wait-FabricOperation {
    param (
        [string]$Token,
        [string]$OperationId,
        [int]$RetryAfterSeconds = 30,
        [int]$MaxAttempts = 20
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }

    $url = "https://api.fabric.microsoft.com/v1/operations/$OperationId"

    Write-Host "##[debug]Waiting for operation to complete..."
    Write-Host "##[debug]OperationId: $OperationId"
    
    $attempts = 0

    do {
        $attempts++
        Start-Sleep -Seconds $RetryAfterSeconds

        try {
            $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
            if ($response.status -eq "Succeeded") {
                Write-Host "##[debug]Operation completed successfully"
                return $response
            }
            elseif ($response.status -eq "Failed") {
                throw "Operation failed: $($response.error.message)"
            }
            Write-Host "##[debug]Operation in progress... (Attempt $attempts of $MaxAttempts)"
        }
        catch {
            Write-Host "Failed to check operation status: $_"
            return $null
        }
    } while ($attempts -lt $MaxAttempts)

    throw "Operation timed out after $MaxAttempts attempts"
}

function Get-FabricGitStatus {
    param (
        [string]$Token,
        [string]$WorkspaceId
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }

    $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git/status"
    Write-Host "##[debug]Getting Git status for workspace: $WorkspaceId"

    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
        return $response
    }
    catch {
        Write-Error "Failed to get Git status: $_"
        throw
    }
}

function Evaluate-GitActions {
    param (
        [PSCustomObject]$GitStatus
    )

    # Initialize action flags
    $actions = @{
        RequiresCommit = $false
        RequiresUpdate = $false
        HasConflicts = $false
        Message = ""
    }

    # Check if there are any changes
    if ($GitStatus.changes.Count -eq 0) {
        if ($GitStatus.workspaceHead -eq $GitStatus.remoteCommitHash) {
            $actions.Message = "No changes detected. Workspace and remote are in sync."
            return $actions
        }
        # Different hashes but no changes might indicate need for update
        $actions.RequiresUpdate = $true
        $actions.Message = "Different commit hashes detected. May need update from Git."
        return $actions
    }

    # Analyze changes
    $workspaceChanges = @($GitStatus.changes | Where-Object { $_.workspaceChange })
    $remoteChanges = @($GitStatus.changes | Where-Object { $_.remoteChange })
    $conflicts = @($GitStatus.changes | Where-Object { $_.conflictType -eq "Conflict" })

    if ($conflicts.Count -gt 0) {
        $actions.HasConflicts = $true
        $actions.Message = "Conflicts detected: $($conflicts.Count) items have conflicts."
        # List conflicted items
        $conflictDetails = $conflicts | ForEach-Object {
            "- $($_.itemMetadata.displayName) ($($_.itemMetadata.itemType))"
        }
        $actions.Message += "`nConflicted items:`n$($conflictDetails -join "`n")"
        return $actions
    }

    if ($workspaceChanges.Count -gt 0) {
        $actions.RequiresCommit = $true
        $changeTypes = $workspaceChanges | Group-Object workspaceChange | ForEach-Object {
            "$($_.Name): $($_.Count) items"
        }
        $actions.Message = "Workspace changes detected: $($changeTypes -join ', ')"
    }

    if ($remoteChanges.Count -gt 0 -and $GitStatus.workspaceHead -ne $GitStatus.remoteCommitHash) {
        $actions.RequiresUpdate = $true
        $actions.Message += "`nRemote changes detected. Update from Git recommended."
    }

    return $actions
}

function New-ReleaseBranch {
    param (
        [string]$Version,
        [string]$SourceBranch,
        [string]$Token,
        [string]$Organization,
        [string]$Project,
        [string]$Repository
    )
    Write-Host "##[debug]Creating release branch for version $Version from $SourceBranch"
    try {
        # Define variables
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

        # Set repo directory path
        $repoPath = Join-Path $PSScriptRoot $Repository
        if (!(Test-Path $repoPath)) {
            New-Item -ItemType Directory -Path $repoPath
            Write-Host "Created directory: $repoPath"
        }

        # Move to repo directory
        Set-Location $repoPath

        # Clone repository normally
        $repoUrl = "https://oauth2:$($authResult.access_token)@dev.azure.com/$Organization/$Project/_git/$Repository"
        Write-Host "##[debug]Cloning repository..."
        git clone -b $SourceBranch --single-branch --depth=1 $repoUrl .
        # git clone --depth=1 $repoUrl .
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone repository. Exit code: $LASTEXITCODE"
        }

        # Remove all folders except DevOpsServices
        Write-Host "##[debug]Removing unnecessary folders..."
        Get-ChildItem -Directory |
            Where-Object { $_.Name -ne "DevOpsServices" -and $_.Name -ne ".git" } |
            Remove-Item -Recurse -Force
       
        # Create and push branch
        $branchName = "release/$ProjectPrefix-v$Version"
        Write-Host "##[debug]Creating branch: $branchName"
        git checkout -b $branchName

        # Stage the deletions
        git add -A
       
        # Set git config for commits
        git config user.email "azure-pipeline@bhg.com"
        git config user.name "Azure Pipeline"

        # Commit the changes
        git commit -m "feat: Create release branch with DevOpsServices folder only"

        Write-Host "##[debug]Pushing branch..."
        git push origin $branchName

        Write-Host "##[debug]Successfully created release branch: $branchName"
        return $branchName
    }
    catch {
        Write-Error "Failed to create release branch: $_"
        throw
    }
}

function Sync-IntegrationBranch {
    param (
        [string]$Token,
        [string]$Organization,
        [string]$Project,
        [string]$Repository
    )
    Write-Host "##[section]Starting Integration Branch Synchronization"
   
    # Create a temporary directory outside the pipeline workspace
    $tempDir = Join-Path $env:TEMP "fabricsync_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
   
    try {
        # Custom URL encoding function
        function Format-GitUrl {
            param ([string]$value)
            return $value.Replace(' ', '%20')
        }
        $encodedProject = Format-GitUrl -value $Project        
        $encodedRepository = Format-GitUrl -value $Repository

        # Define variables
        $tenantId = $env:ARM_TENANT_ID
        $clientId = $env:ARM_CLIENT_ID
        $clientSecret = $env:ARM_CLIENT_SECRET
        $integrationBranch = "integration-platform-services"
       
        # Set default source branch if not available
        $sourceBranch = "main"
        if ($env:BUILD_SOURCEBRANCH) {
            if ($env:BUILD_SOURCEBRANCH -match "refs/heads/(.+)") {
                $sourceBranch = $Matches[1]
            }
        }
       
        Write-Host "##[debug]Source branch identified as: $sourceBranch"
       
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
       
        # Change to temp directory
        Set-Location $tempDir
       
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
       
        # Initialize new repository
        Write-Host "##[debug]Initializing git repository..."
        git init
       
        # Add remote
        $repoUrl = "https://oauth2:$($authResult.access_token)@dev.azure.com/$Organization/$encodedProject/_git/$encodedRepository"
        git remote add origin $repoUrl
       
        # Check if integration branch exists remotely
        Write-Host "##[debug]Checking if integration branch exists..."
        $remoteRefs = git ls-remote --heads origin $integrationBranch
        $integrationExists = $remoteRefs -match $integrationBranch
       
        if ($integrationExists) {
            Write-Host "##[debug]Integration branch exists. Fetching..."
            # Fix: Correct fetch command syntax
            git fetch origin $integrationBranch
           
            # Create local branch that tracks the remote
            git checkout -b $integrationBranch --track origin/$integrationBranch
           
            if ($LASTEXITCODE -ne 0) {
                Write-Host "##[debug]Standard checkout failed. Using alternative approach..."
                # Alternative approach
                git fetch origin ${integrationBranch}:$integrationBranch
                git checkout $integrationBranch
            }
        } else {
            Write-Host "##[debug]Integration branch does not exist. Creating new branch..."
            # Start with main branch content
            git fetch origin main:main
            git checkout -b $integrationBranch main
           
            if ($LASTEXITCODE -ne 0) {
                # If main doesn't exist or there's another issue, create empty branch
                Write-Host "##[debug]Creating empty integration branch..."
                git checkout --orphan $integrationBranch
                git rm -rf . 2>$null
            }
        }
       
        # Create/update directory structure
        Write-Host "##[debug]Creating required directories..."
       
        # Create src/fabric directory
        $srcFabricPath = Join-Path $tempDir "src/fabric"
        New-Item -ItemType Directory -Path $srcFabricPath -Force | Out-Null

        # Create src/ellie directory
        $srcFabricPath = Join-Path $tempDir "src/ellie"
        New-Item -ItemType Directory -Path $srcFabricPath -Force | Out-Null

        # Create src/Metadata directory
        $srcMetadataPath = Join-Path $tempDir "src/metadata"
        New-Item -ItemType Directory -Path $srcMetadataPath -Force | Out-Null

        # Create readme.md in src/fabric
        $readmeContent = @"
# Microsoft Fabric Assets

This directory contains Microsoft Fabric assets including:

- Notebooks
- KQL Dashboards
- Environments
- Data Pipelines
- Lakehouses

## Structure

Each asset is stored in its corresponding folder with a `.platform` configuration file.

## Deployment

Assets are deployed automatically via Azure DevOps pipelines using Terraform.

Last synchronized from '$sourceBranch' branch on $(Get-Date -Format "yyyy-MM-dd").
"@
       
        # Create readme.md in src/fabric
        $readmeMetadataContent = @"
# Microsoft Fabric Assets

This directory contains Microsoft Fabric Metadata assets including:

- data_product
- data_quality
- datasets
- feeds
- templates

## Deployment

Assets are deployed automatically via Azure DevOps pipelines.

Last synchronized from '$sourceBranch' branch on $(Get-Date -Format "yyyy-MM-dd").
"@       
        Set-Content -Path (Join-Path $srcFabricPath "readme.md") -Value $readmeContent

        Set-Content -Path (Join-Path $srcMetadataPath "readme.md") -Value $readmeMetadataContent
       
        # Now fetch the DevOpsServices and docs folders from source branch
        Write-Host "##[debug]Fetching DevOpsServices and docs folders from $sourceBranch..."
        git fetch origin $sourceBranch
       
        # Create directories if they don't exist
        New-Item -ItemType Directory -Path (Join-Path $tempDir "DevOpsServices") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tempDir "docs") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tempDir "src/metadata") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tempDir ".vscode") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tempDir "src/ellie") -Force | Out-Null
        
        # Try to extract specific folders
        try {
            # First, try to directly checkout the folders
            git checkout FETCH_HEAD -- DevOpsServices docs src/metadata src/ellie .vscode *.md 2>$null
           
            if ($LASTEXITCODE -ne 0) {
                Write-Host "##[debug]Direct checkout failed. Using archive approach..."
                # Alternative approach using git archive
                git archive --remote=$repoUrl $sourceBranch DevOpsServices docs src/metadata src/ellie .vscode README.md changelog.md | tar -x
            }
        }
        catch {
            Write-Host "##[warning]Failed to extract folders: $_"
            Write-Host "##[debug]Using manual copy approach..."
           
            # Clone source branch to a separate directory and copy folders
            $sourceTempDir = Join-Path $env:TEMP "source_$(Get-Random)"
            New-Item -ItemType Directory -Path $sourceTempDir -Force | Out-Null
            Set-Location $sourceTempDir
           
            git clone --depth 1 --branch $sourceBranch --no-checkout $repoUrl .
            git checkout $sourceBranch -- DevOpsServices docs src/metadata src/ellie .vscode README.md changelog.md

            # Copy the folders back to our working directory
            if (Test-Path "DevOpsServices") {
                Copy-Item -Path "DevOpsServices" -Destination $tempDir -Recurse -Force
            }
            if (Test-Path "docs") {
                Copy-Item -Path "docs" -Destination $tempDir -Recurse -Force
            }
            if (Test-Path "src/metadata") {
                Copy-Item -Path "src/metadata" -Destination $tempDir -Recurse -Force
            }
            if (Test-Path "src/ellie") {
                Copy-Item -Path "src/ellie" -Destination $tempDir -Recurse -Force
            }            
            if (Test-Path ".vscode") {
                Copy-Item -Path ".vscode" -Destination $tempDir -Recurse -Force
            }
            if (Test-Path "README.md") {
                Copy-Item -Path "README.md" -Destination $tempDir -Recurse -Force
            }
            if (Test-Path "changelog.md") {
                Copy-Item -Path "changelog.md" -Destination $tempDir -Recurse -Force
            }

            # Clean up the source temp dir
            Set-Location $tempDir
            Remove-Item -Path $sourceTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
       
        # Add all changes
        git add -A
       
        # Check if there are changes to commit
        $status = git status --porcelain
        if ($status) {
           git commit -m "feat: Sync DevOpsServices, docs, .vscode, src/ellie, src/metadata, readme.md changelog.md from $sourceBranch"
            
            # Push changes
            Write-Host "##[debug]Pushing changes to $integrationBranch branch..."
            git push -u origin $integrationBranch --force
            Write-Host "##[section]Successfully synchronized $integrationBranch branch"
        } else {
            Write-Host "##[debug]No changes to commit."
            Write-Host "##[section]No changes needed for $integrationBranch branch"
        }
       
        return $integrationBranch
    }
    catch {
        Write-Error "Failed to synchronize integration branch: $_"
        throw
    }
    finally {
        # Return to original location
        Set-Location $PSScriptRoot
       
        # Clean up temp directory
        if (Test-Path $tempDir) {
            try {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host "##[warning]Could not clean up temp directory: $tempDir"
            }
        }
    }
}

try {

    function Initialize-GitConfiguration {
        Write-Host "Initializing Git configurations for Windows..."

        # Clear Git proxy settings
        git config --global --unset http.proxy
        git config --global --unset https.proxy

        # Clear Windows environment variables
        [Environment]::SetEnvironmentVariable("http_proxy", $null, "Process")
        [Environment]::SetEnvironmentVariable("https_proxy", $null, "Process")
        [Environment]::SetEnvironmentVariable("HTTP_PROXY", $null, "Process")
        [Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "Process")

        # Optionally, check Windows system proxy
        $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        Set-ItemProperty -Path $regKey -Name ProxyEnable -Value 0
        Set-ItemProperty -Path $regKey -Name ProxyServer -Value ""

        # Configure git for Windows-specific settings
        git config --global core.autocrlf true  # Handle line endings
        git config --global core.longpaths true # Handle long paths
    }

    # Call it once at the beginning
    Initialize-GitConfiguration

    # Get auth token
    $token = $env:FABRIC_TOKEN
    
    $workspaceIds = ConvertFrom-Json -InputObject $env:WORKSPACE_IDS
    $workspaceId = $workspaceIds.PSObject.Properties.Value

    # Build integration platform services branch to hold DevOps pipeline scripts and docs
    $integrationResponse = Sync-IntegrationBranch -Token $token -Organization $Organization -Project $Project -Repository $Repository

    # Connect to Git
    $connectResult = Connect-FabricGit -Token $token -WorkspaceId $workspaceId `
        -Organization $Organization -Project $Project -Repository $Repository `
        -Branch $Branch -Directory $Directory

    # Initialize connection
    $initResult = Initialize-FabricGitConnection -Token $token -WorkspaceId $workspaceId -InitializationStrategy "PreferRemote"

    $status = Get-FabricGitStatus -Token $token -WorkspaceId $workspaceId
    $actions = Evaluate-GitActions -GitStatus $status

    Write-Host "##[debug]Git Status Evaluation:"
    Write-Host "##[debug]$($actions.Message)"

    if ($actions.HasConflicts) {
        Write-Host "##[warning]Conflicts detected. Manual resolution required."
        # Handle conflicts - might need manual intervention
    } elseif ($actions.RequiresCommit) {
        Write-Host "##[debug]Changes need to be committed."
        # Proceed with commit

        $operationId = Invoke-FabricGitCommit -Token $token -WorkspaceId $workspaceId
        
        Wait-FabricOperation -Token $token -OperationId $operationId
    } elseif ($actions.RequiresUpdate) {
        Write-Host "##[debug]Update from Git required."

        $operationId = Update-FabricFromGit -Token $token -WorkspaceId $workspaceId -RemoteCommitHash $status.remoteCommitHash -WorkspaceHead $status.workspaceHead
        Wait-FabricOperation -Token $token -OperationId $operationId
    }
    else {
        Write-Host "##[debug]No action required. Workspace is up to date."
    }

    exit 0
}
catch {
    Write-Error $_
    exit 1
}