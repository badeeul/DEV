
param (
    [Parameter(Mandatory=$true)]
    [string]$SourceBranch,
    [Parameter(Mandatory=$true)]
    [string]$SourceOrganization,
    [Parameter(Mandatory=$true)]
    [string]$SourceProject,
    [Parameter(Mandatory=$true)]
    [string]$SourceRepository,
    [Parameter(Mandatory=$true)]
    [string]$TargetOrganization,
    [Parameter(Mandatory=$true)]
    [string]$TargetProject,
    [Parameter(Mandatory=$true)]
    [string]$TargetRepository,
    [Parameter(Mandatory=$false)]
    [string]$WorkingDirectory = $PWD
)

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
        return $response.access_token
    }
    catch {
        Write-Error "Failed to get Azure DevOps token: $_"
        throw
    }
}

function Git-Cleanup {
  Write-Host "Resetting git configurations..."
     
    # Function to safely run git config commands
    function Set-GitConfig {
        param($Command)
        try {
            Invoke-Expression "git $Command" 2>&1 | Write-Host
            return $true
        }
        catch {
            Write-Host "Command failed but continuing: git $Command"
            return $true  # Continue despite errors
        }
    }
    
    # Reset configurations
    Set-GitConfig 'config --global --unset-all http.extraheader'
    Set-GitConfig 'config --global --unset-all http.https://dev.azure.com.extraheader'
    Set-GitConfig 'config --global credential.helper ""'
    Set-GitConfig 'config --global core.askPass ""'
    
    Write-Host "Git configurations reset complete"
}

function Deploy-ReleaseBranch {
    param (
        [string]$Token,
        [string]$SourceBranch,
        [string]$SourceOrg,
        [string]$SourceProj,
        [string]$SourceRepo,
        [string]$TargetOrg,
        [string]$TargetProj,
        [string]$TargetRepo,
        [string]$WorkDir = $PWD
    )

    # Extract version number from source branch name
    if ($SourceBranch -match 'v(\d+\.\d+\.\d+)') {
        $versionNumber = $matches[1]
    } else {
        throw "Could not extract version number from branch name: $SourceBranch"
    }

    $tempFolder = Join-Path $WorkDir "temp_$versionNumber"

    try {

        # Custom URL encoding function
        function Format-GitUrl {
            param ([string]$value)
            return $value.Replace(' ', '%20')  #.Replace('-', '%2D')
        }

        # Create temp directory
        New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
        Set-Location $tempFolder

        # Initialize git repo
        git init
        if ($LASTEXITCODE -ne 0) { throw "Failed to initialize git repository" }

        # Configure git with bearer token
        git config --global http.extraHeader "AUTHORIZATION: Bearer $Token"

        $encodedSourceRepo = Format-GitUrl $SourceRepo
        $encodedSourceProj = Format-GitUrl $SourceProj

        # Add source remote and fetch
        Write-Host "##[debug]Setting up source repository..."
        $sourceUrl = "https://dev.azure.com/$SourceOrg/$encodedSourceProj/_git/$encodedSourceRepo"
        git remote add source $sourceUrl
        if ($LASTEXITCODE -ne 0) { throw "Failed to add source remote" }

        Write-Host "##[debug]Fetching source branch..."
        git -c http.$sourceUrl.extraheader="AUTHORIZATION: Bearer $Token" fetch source $SourceBranch --progress
        if ($LASTEXITCODE -ne 0) { throw "Failed to fetch source branch" }

        Write-Host "##[debug]Checking out source branch..."
        git checkout -b local_branch source/$SourceBranch
        if ($LASTEXITCODE -ne 0) { throw "Failed to checkout source branch" }

        # Create properly encoded target URL
        $encodedTargetProj = Format-GitUrl $TargetProj
        $encodedTargetRepo = Format-GitUrl $TargetRepo

        # Add target remote
        Write-Host "##[debug]Setting up target repository..."
        $targetUrl = "https://dev.azure.com/$TargetOrg/$encodedTargetProj/_git/$encodedTargetRepo"
        git remote add target $targetUrl
        if ($LASTEXITCODE -ne 0) { throw "Failed to add target remote" }

        # Push to target with bearer token
        $targetBranch = "release/platform-services-monitor-v$versionNumber"
        Write-Host "##[debug]Pushing to target repository as $targetBranch..."
        git -c http.$targetUrl.extraheader="AUTHORIZATION: Bearer $Token" push target "local_branch:$targetBranch" --progress       
        if ($LASTEXITCODE -ne 0) { throw "Failed to push to target repository" }

        Write-Host "##[debug]Successfully deployed branch: $targetBranch"
        return $targetBranch
    }
    catch {
        Git-Cleanup
        Write-Error "Failed to deploy release branch: $_"
        throw
    }
    finally {
        Git-Cleanup
        Set-Location $WorkDir
        if (Test-Path $tempFolder) {
            Remove-Item -Path $tempFolder -Recurse -Force
        }
        exit 0
    }
}

try {
    # Get bearer token
    $token = Get-DevOpsAuthToken
   
    $deployParams = @{
        Token = $token
        SourceBranch = $SourceBranch
        SourceOrg = $SourceOrganization
        SourceProj = $SourceProject
        SourceRepo = $SourceRepository
        TargetOrg = $TargetOrganization
        TargetProj = $TargetProject
        TargetRepo = $TargetRepository
    }

    # Deploy branch
    $targetBranch = Deploy-ReleaseBranch @deployParams

    # Set output variable for pipeline
    Write-Host "##vso[task.setvariable variable=TargetBranch;isoutput=true]$targetBranch"
}
catch {
    Write-Error $_
    exit 1
}