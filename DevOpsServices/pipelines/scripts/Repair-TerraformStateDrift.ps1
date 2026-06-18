# Emoji definitions for better output readability
$script:Emoji = @{
    Success     = [char]::ConvertFromUtf32(0x2705)    # ✅ Check Mark
    Error       = [char]::ConvertFromUtf32(0x274C)    # ❌ Cross Mark
    Warning     = [char]::ConvertFromUtf32(0x26A0)    # ⚠️ Warning
    Info        = [char]::ConvertFromUtf32(0x2139)    # ℹ️ Information
    Lakehouse   = [char]::ConvertFromUtf32(0x1F3E0)   # 🏠 House
    Environment = [char]::ConvertFromUtf32(0x1F333)   # 🌳 Tree (Environment)
    Cloud       = [char]::ConvertFromUtf32(0x2601)    # ☁️ Cloud
    Gear        = [char]::ConvertFromUtf32(0x2699)    # ⚙️ Gear
    Magnify     = [char]::ConvertFromUtf32(0x1F50D)   # 🔍 Magnifying Glass
    Refresh     = [char]::ConvertFromUtf32(0x1F504)   # 🔄 Counterclockwise Arrows
    Stats       = [char]::ConvertFromUtf32(0x1F4CA)   # 📊 Bar Chart
    Globe       = [char]::ConvertFromUtf32(0x1F310)   # 🌐 Globe
    Download    = [char]::ConvertFromUtf32(0x1F4E5)   # 📥 Inbox Tray
    Extract     = [char]::ConvertFromUtf32(0x1F4C4)   # 📄 Document
}

# ===================================================================
# TERRAFORM VARIABLES EXTRACTION FUNCTIONS
# ===================================================================
function Get-WorkspaceNameFromTfvars {
    Write-Host "##[debug]$($script:Emoji.Extract) Extracting workspace name from terraform.tfvars"
   
    try {
        if (-not (Test-Path "terraform.tfvars")) {
            throw "terraform.tfvars file not found"
        }
       
        $tfvarsContent = Get-Content "terraform.tfvars" -Raw
       
        # Look for workspace_names line and extract the value
        if ($tfvarsContent -match 'workspace_names\s*=\s*\[?"?([^"\]]+)"?\]?') {
            $workspaceName = $matches[1].Trim()
           
            # Remove any remaining quotes
            $workspaceName = $workspaceName -replace '"', ''
           
            Write-Host "##[debug]$($script:Emoji.Success) Extracted workspace name: $workspaceName"
            return $workspaceName
        } else {
            throw "Could not find workspace_names in terraform.tfvars"
        }
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to extract workspace name: $($_.Exception.Message)"
        throw
    }
}

function Test-TerraformVariablesFile {
    Write-Host "##[debug]$($script:Emoji.Gear) Validating terraform.tfvars file"
   
    if (Test-Path "terraform.tfvars") {
        Write-Host "##[debug]$($script:Emoji.Success) Found terraform.tfvars file"
       
        # Show first few lines for debugging
        $tfvarsContent = Get-Content "terraform.tfvars" -TotalCount 5
        Write-Host "##[debug]terraform.tfvars preview:"
        $tfvarsContent | ForEach-Object { Write-Host "##[debug]  $_" }
       
        return $true
    } else {
        Write-Host "##[error]$($script:Emoji.Error) terraform.tfvars file not found"
        Write-Host "##[error]Make sure the Azure DevOps pipeline creates this file before calling this script"
        return $false
    }
}

# ===================================================================
# FABRIC API FUNCTIONS
# ===================================================================
function Get-FabricWorkspaceId {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceName,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[debug]$($script:Emoji.Globe) Getting workspace ID for: $WorkspaceName"
   
    $attemptCount = 0
    $success = $false
   
    while (-not $success -and $attemptCount -lt $MaxRetryAttempts) {
        $attemptCount++
       
        try {
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            $token = $env:FABRIC_TOKEN
            if (-not $token) {
                throw "FABRIC_TOKEN environment variable is not set"
            }
           
            $headers = @{
                'Authorization' = "Bearer $token"
                'Content-Type' = 'application/json'
            }
           
            $workspacesResponse = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Headers $headers -Method Get -TimeoutSec 30
            $targetWorkspace = $workspacesResponse.value | Where-Object { $_.displayName -eq $WorkspaceName }
           
            if ($targetWorkspace) {
                Write-Host "##[debug]$($script:Emoji.Success) Found workspace: $WorkspaceName (ID: $($targetWorkspace.id))"
                return $targetWorkspace.id
            } else {
                throw "Workspace '$WorkspaceName' not found in Fabric"
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host "##[warning]$($script:Emoji.Warning) Error getting workspace ID (Attempt $attemptCount of $MaxRetryAttempts): $errorMessage"
           
            if ($attemptCount -eq $MaxRetryAttempts) {
                Write-Host "##[error]$($script:Emoji.Error) Failed to get workspace ID after $MaxRetryAttempts attempts"
                throw $errorMessage
            }
        }
    }
}

function Get-FabricEnvironments {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[debug]$($script:Emoji.Globe) Getting environments from Fabric API for workspace: $WorkspaceId"
   
    $attemptCount = 0
    $success = $false
   
    while (-not $success -and $attemptCount -lt $MaxRetryAttempts) {
        $attemptCount++
       
        try {
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            $token = $env:FABRIC_TOKEN
            if (-not $token) {
                throw "FABRIC_TOKEN environment variable is not set"
            }
           
            $headers = @{
                'Authorization' = "Bearer $token"
                'Content-Type' = 'application/json'
            }
           
            $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments"
            $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get -TimeoutSec 30
           
            Write-Host "##[debug]$($script:Emoji.Success) Found $($response.value.Count) environments in Fabric"
           
            foreach ($environment in $response.value) {
                Write-Host "##[debug]  - $($environment.displayName) (ID: $($environment.id))"
            }
           
            return $response.value
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host "##[warning]$($script:Emoji.Warning) Error getting Fabric environments (Attempt $attemptCount of $MaxRetryAttempts): $errorMessage"
           
            if ($attemptCount -eq $MaxRetryAttempts) {
                Write-Host "##[error]$($script:Emoji.Error) Failed to get Fabric environments after $MaxRetryAttempts attempts"
                throw $errorMessage
            }
        }
    }
}

function Get-FabricLakehouses {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[debug]$($script:Emoji.Globe) Getting lakehouses from Fabric API for workspace: $WorkspaceId"
   
    $attemptCount = 0
    $success = $false
   
    while (-not $success -and $attemptCount -lt $MaxRetryAttempts) {
        $attemptCount++
       
        try {
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            $token = $env:FABRIC_TOKEN
            if (-not $token) {
                throw "FABRIC_TOKEN environment variable is not set"
            }
           
            $headers = @{
                'Authorization' = "Bearer $token"
                'Content-Type' = 'application/json'
            }
           
            $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses"
            $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get -TimeoutSec 30
           
            Write-Host "##[debug]$($script:Emoji.Success) Found $($response.value.Count) lakehouses in Fabric"
           
            foreach ($lakehouse in $response.value) {
                Write-Host "##[debug]  - $($lakehouse.displayName) (ID: $($lakehouse.id))"
            }
           
            return $response.value
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host "##[warning]$($script:Emoji.Warning) Error getting Fabric lakehouses (Attempt $attemptCount of $MaxRetryAttempts): $errorMessage"
           
            if ($attemptCount -eq $MaxRetryAttempts) {
                Write-Host "##[error]$($script:Emoji.Error) Failed to get Fabric lakehouses after $MaxRetryAttempts attempts"
                throw $errorMessage
            }
        }
    }
}

function Get-FabricNotebooks {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[debug]$($script:Emoji.Globe) Getting notebooks from Fabric API for workspace: $WorkspaceId"
   
    $attemptCount = 0
    $success = $false
   
    while (-not $success -and $attemptCount -lt $MaxRetryAttempts) {
        $attemptCount++
       
        try {
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            $token = $env:FABRIC_TOKEN
            if (-not $token) {
                throw "FABRIC_TOKEN environment variable is not set"
            }
           
            $headers = @{
                'Authorization' = "Bearer $token"
                'Content-Type' = 'application/json'
            }
           
            $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks"
            $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get -TimeoutSec 30
           
            Write-Host "##[debug]$($script:Emoji.Success) Found $($response.value.Count) notebooks in Fabric"
           
            foreach ($notebook in $response.value) {
                Write-Host "##[debug]  - $($notebook.displayName) (ID: $($notebook.id))"
            }
           
            return $response.value
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host "##[warning]$($script:Emoji.Warning) Error getting Fabric notebooks (Attempt $attemptCount of $MaxRetryAttempts): $errorMessage"
           
            if ($attemptCount -eq $MaxRetryAttempts) {
                Write-Host "##[error]$($script:Emoji.Error) Failed to get Fabric notebooks after $MaxRetryAttempts attempts"
                throw $errorMessage
            }
        }
    }
}

# ===================================================================
# TERRAFORM STATE FUNCTIONS
# ===================================================================
function Get-TerraformEnvironmentState {
    param(
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "environment",
       
        [Parameter(Mandatory=$false)]
        [string]$ResourceType = "fabric_environment"
    )
   
    Write-Host "##[debug]$($script:Emoji.Magnify) Getting current Terraform environment state"
   
    try {
        $stateList = terraform state list 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) Failed to get terraform state list: $stateList"
            return @()
        }
       
        # Filter for environment resources
        $environmentResources = $stateList | Where-Object {
            $_ -match "module\.$ModuleName\.$ResourceType"
        }
       
        Write-Host "##[debug]$($script:Emoji.Success) Found $($environmentResources.Count) environments in Terraform state"
       
        # Extract environment names from state addresses
        $stateEnvironments = @()
        foreach ($resource in $environmentResources) {
            if ($resource -match 'module\.environment\.fabric_environment\.this\["(.+)"\]') {
                $environmentName = $matches[1]
               
                $stateEnvironments += @{
                    StateAddress = $resource
                    EnvironmentName = $environmentName
                }
                Write-Host "##[debug]  - Found in state: $environmentName"
            }
        }
       
        return $stateEnvironments
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to get Terraform environment state: $($_.Exception.Message)"
        return @()
    }
}

function Get-TerraformLakehouseState {
    param(
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "lakehouse_names",
       
        [Parameter(Mandatory=$false)]
        [string]$ResourceType = "fabric_lakehouse"
    )
   
    Write-Host "##[debug]$($script:Emoji.Magnify) Getting current Terraform lakehouse state"
   
    try {
        $stateList = terraform state list 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) Failed to get terraform state list: $stateList"
            return @()
        }
       
        # Filter for lakehouse resources
        $lakehouseResources = $stateList | Where-Object {
            $_ -match "module\.$ModuleName\.$ResourceType"
        }
       
        Write-Host "##[debug]$($script:Emoji.Success) Found $($lakehouseResources.Count) lakehouses in Terraform state"
       
        # Extract lakehouse names from state addresses
        $stateLakehouses = @()
        foreach ($resource in $lakehouseResources) {
            if ($resource -match 'module\.lakehouse_names\.fabric_lakehouse\.this\["(.+)"\]') {
                $lakehouseName = $matches[1]
               
                # Extract just the lakehouse name part (after the last hyphen)
                if ($lakehouseName -match '^(.+)-(.+)$') {
                    $workspacePrefix = $matches[1]
                    $actualName = $matches[2]
                   
                    $stateLakehouses += @{
                        StateAddress = $resource
                        FullKey = $lakehouseName
                        WorkspacePrefix = $workspacePrefix
                        LakehouseName = $actualName
                    }
                    Write-Host "##[debug]  - Found in state: $actualName (Key: $lakehouseName)"
                } else {
                    Write-Host "##[warning]$($script:Emoji.Warning) Could not parse lakehouse name from: $lakehouseName"
                }
            }
        }
       
        return $stateLakehouses
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to get Terraform lakehouse state: $($_.Exception.Message)"
        return @()
    }
}

function Get-TerraformNotebookState {
    param(
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "notebooks",
       
        [Parameter(Mandatory=$false)]
        [string]$ResourceType = "fabric_notebook"
    )
   
    Write-Host "##[debug]$($script:Emoji.Magnify) Getting current Terraform notebook state"
   
    try {
        $stateList = terraform state list 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) Failed to get terraform state list: $stateList"
            return @()
        }
       
        # Filter for notebook resources
        $notebookResources = $stateList | Where-Object {
            $_ -match "module\.$ModuleName\.$ResourceType"
        }
       
        Write-Host "##[debug]$($script:Emoji.Success) Found $($notebookResources.Count) notebooks in Terraform state"
       
        # Extract notebook names from state addresses
        $stateNotebooks = @()
        foreach ($resource in $notebookResources) {
            if ($resource -match 'module\.notebooks\.fabric_notebook\.this\["(.+)"\]') {
                $notebookName = $matches[1]
               
                # Extract just the notebook name part (after the last hyphen, before .Notebook)
                if ($notebookName -match '^(.+)-(.+)\.Notebook$') {
                    $workspacePrefix = $matches[1]
                    $actualName = $matches[2]
                   
                    $stateNotebooks += @{
                        StateAddress = $resource
                        FullKey = $notebookName
                        WorkspacePrefix = $workspacePrefix
                        NotebookName = $actualName
                    }
                    Write-Host "##[debug]  - Found in state: $actualName (Key: $notebookName)"
                } else {
                    Write-Host "##[warning]$($script:Emoji.Warning) Could not parse notebook name from: $notebookName"
                }
            }
        }
       
        return $stateNotebooks
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to get Terraform notebook state: $($_.Exception.Message)"
        return @()
    }
}

function Get-TerraformWorkspaceState {
    param(
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "fabric_workspace",
       
        [Parameter(Mandatory=$false)]
        [string]$ResourceType = "fabric_workspace"
    )
   
    Write-Host "##[debug]$($script:Emoji.Magnify) Getting current Terraform workspace state"
   
    try {
        $stateList = terraform state list 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) Failed to get terraform state list: $stateList"
            return @()
        }
       
        # Filter for workspace resources
        $workspaceResources = $stateList | Where-Object {
            $_ -match "module\.$ModuleName\.$ResourceType"
        }
       
        Write-Host "##[debug]$($script:Emoji.Success) Found $($workspaceResources.Count) workspaces in Terraform state"
       
        # Extract workspace names from state addresses
        $stateWorkspaces = @()
        foreach ($resource in $workspaceResources) {
            if ($resource -match 'module\.fabric_workspace\.fabric_workspace\.this\["(.+)"\]') {
                $workspaceName = $matches[1]
               
                $stateWorkspaces += @{
                    StateAddress = $resource
                    WorkspaceName = $workspaceName
                }
                Write-Host "##[debug]  - Found in state: $workspaceName"
            }
        }
       
        return $stateWorkspaces
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to get Terraform workspace state: $($_.Exception.Message)"
        return @()
    }
}

# ===================================================================
# ENVIRONMENT COMPARISON AND IMPORT FUNCTIONS
# ===================================================================
function Compare-EnvironmentStates {
    param(
        [Parameter(Mandatory=$true)]
        [array]$FabricEnvironments,
       
        [Parameter(Mandatory=$false)]
        [array]$TerraformEnvironments,
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName
    )
   
    Write-Host "##[debug]$($script:Emoji.Stats) Comparing Fabric and Terraform environment states"
    # check erraformEnvironments is not null or empty
    if (-not $TerraformEnvironments -or $TerraformEnvironments.Count -eq 0) {
        Write-Host "##[warning]$($script:Emoji.Warning) No Terraform environments found in state"
    }
    Write-Host "##[debug]  Fabric environments: $($FabricEnvironments.Count)"
    Write-Host "##[debug]  Terraform environments: $($TerraformEnvironments.Count)"
    Write-Host "##[debug]  Workspace name: $WorkspaceName"
   
    $missingEnvironments = @()
   
    foreach ($fabricEnvironment in $FabricEnvironments) {
        $fabricName = $fabricEnvironment.displayName
       
        # Check if this environment exists in Terraform state
        # For environments, we typically use the workspace name as the key
        $existsInState = $TerraformEnvironments | Where-Object { $_.EnvironmentName -eq $WorkspaceName }
       
        if (-not $existsInState) {
            # Generate the expected key format for environments
            $expectedKey = $WorkspaceName
            $expectedAddress = "module.environment.fabric_environment.this[`"$expectedKey`"]"
           
            $missingEnvironments += @{
                FabricId = $fabricEnvironment.id
                DisplayName = $fabricName
                ExpectedKey = $expectedKey
                ExpectedAddress = $expectedAddress
            }
           
            Write-Host "##[debug]$($script:Emoji.Warning) Missing environment from state: $fabricName (Key: $expectedKey)"
        } else {
            Write-Host "##[debug]$($script:Emoji.Success) Environment already in state: $($existsInState.EnvironmentName)"
        }
    }
   
    Write-Host "##[debug]$($script:Emoji.Stats) Found $($missingEnvironments.Count) missing environments"
   
    return $missingEnvironments
}

function Import-MissingEnvironment {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$EnvironmentInfo,
       
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    $environmentName = $EnvironmentInfo.DisplayName
    $environmentId = $EnvironmentInfo.FabricId
    $expectedKey = $EnvironmentInfo.ExpectedKey
    $importId = "$WorkspaceId/$environmentId"
   
    # Build properly escaped resource address
    $resourceAddress = "module.environment.fabric_environment.this[\`"$expectedKey\`"]"
   
    Write-Host "##[section]$($script:Emoji.Download) Importing environment: $environmentName"
    Write-Host "##[debug]  Resource Address: $resourceAddress"
    Write-Host "##[debug]  Import ID: $importId"
   
    $attemptCount = 0
    $importSucceeded = $false
   
    while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
        $attemptCount++
       
        try {
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSecondsSuccessfully imported lakehouse:
            }
           
            Write-Host "##[debug]Executing terraform import with tfvars file"
           
            # Execute terraform import with proper escaping
            $result = terraform import -var-file="terraform.tfvars" `
                "$resourceAddress" `
                "$importId" 2>&1
           
            $exitCode = $LASTEXITCODE
           
            Write-Host "##[debug]Command: terraform import -var-file=`"terraform.tfvars`" `"$resourceAddress`" `"$importId`""
           
            if ($exitCode -eq 0) {
                $importSucceeded = $true
                Write-Host "##[section]$($script:Emoji.Success) Successfully imported environment: $environmentName"
                return $true
            } else {
                Write-Host "##[warning]$($script:Emoji.Warning) Environment import failed (attempt $attemptCount):"
                $result | ForEach-Object { Write-Host "##[warning]  $_" }
               
                # Check for already exists indicators
                $resultString = $result -join " "
                if ($resultString -match "Resource already managed by Terraform" -or
                    $resultString -match "already exists in state") {
                    Write-Host "##[info]$($script:Emoji.Info) Environment resource already managed - verifying state"
                   
                    $stateShow = terraform state show "$resourceAddress" 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "##[section]$($script:Emoji.Success) Environment resource confirmed in state: $environmentName"
                        return $true
                    }
                }
            }
        }
        catch {
            Write-Host "##[error]$($script:Emoji.Error) Exception during environment import attempt $attemptCount : $($_.Exception.Message)"
        }
    }
   
    Write-Host "##[error]$($script:Emoji.Error) Failed to import environment after $MaxRetryAttempts attempts: $environmentName"
    return $false
}

function Import-AllMissingEnvironments {
    param(
        [Parameter(Mandatory=$true)]
        [array]$MissingEnvironments,
       
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    if ($MissingEnvironments.Count -eq 0) {
        Write-Host "##[section]$($script:Emoji.Success) No missing environments to import"
        return $true
    }
   
    Write-Host "##[section]$($script:Emoji.Download) Starting import of $($MissingEnvironments.Count) missing environments"
   
    $successCount = 0
    $failedImports = @()
   
    foreach ($environment in $MissingEnvironments) {
        $importSuccess = Import-MissingEnvironment -EnvironmentInfo $environment -WorkspaceId $WorkspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        if ($importSuccess) {
            $successCount++
        } else {
            $failedImports += $environment
        }
       
        # Small delay between imports to avoid overwhelming the API
        if ($environment -ne $MissingEnvironments[-1]) {
            Start-Sleep -Seconds 2
        }
    }
   
    Write-Host ""
    Write-Host "##[section]$($script:Emoji.Stats) Environment Import Results:"
    Write-Host "##[debug]  Successful: $successCount"
    Write-Host "##[debug]  Failed: $($failedImports.Count)"
    Write-Host "##[debug]  Total: $($MissingEnvironments.Count)"
   
    if ($failedImports.Count -gt 0) {
        Write-Host "##[warning]$($script:Emoji.Warning) Failed environment imports:"
        foreach ($failed in $failedImports) {
            Write-Host "##[warning]  - $($failed.DisplayName)"
        }
    }
   
    return ($successCount -eq $MissingEnvironments.Count)
}

# ===================================================================
# LAKEHOUSE COMPARISON AND IMPORT FUNCTIONS
# ===================================================================
function Compare-LakehouseStates {
    param(
        [Parameter(Mandatory=$true)]
        [array]$FabricLakehouses,
       
        [Parameter(Mandatory=$false)]
        [array]$TerraformLakehouses,
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName
    )
   
    Write-Host "##[debug]$($script:Emoji.Stats) Comparing Fabric and Terraform lakehouse states"
    if (-not $TerraformLakehouses -or $TerraformLakehouses.Count -eq 0) {
        Write-Host "##[warning]$($script:Emoji.Warning) No Terraform lakehouses found in state"
    }
    Write-Host "##[debug]  Fabric lakehouses: $($FabricLakehouses.Count)"
    Write-Host "##[debug]  Terraform lakehouses: $($TerraformLakehouses.Count)"
    Write-Host "##[debug]  Workspace name: $WorkspaceName"
   
    $missingLakehouses = @()
   
    foreach ($fabricLakehouse in $FabricLakehouses) {
        $fabricName = $fabricLakehouse.displayName
       
        # Check if this lakehouse exists in Terraform state
        $existsInState = $TerraformLakehouses | Where-Object { $_.LakehouseName -eq $fabricName }
       
        if (-not $existsInState) {
            # Generate the expected key format
            $expectedKey = "$WorkspaceName-$fabricName"
            $expectedAddress = "module.lakehouse_names.fabric_lakehouse.this[`"$expectedKey`"]"
           
            $missingLakehouses += @{
                FabricId = $fabricLakehouse.id
                DisplayName = $fabricName
                ExpectedKey = $expectedKey
                ExpectedAddress = $expectedAddress
            }
           
            Write-Host "##[debug]$($script:Emoji.Warning) Missing lakehouse from state: $fabricName"
        } else {
            Write-Host "##[debug]$($script:Emoji.Success) Lakehouse already in state: $fabricName"
        }
    }
   
    Write-Host "##[debug]$($script:Emoji.Stats) Found $($missingLakehouses.Count) missing lakehouses"
   
    return $missingLakehouses
}

function Import-MissingLakehouse {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$LakehouseInfo,
       
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    $lakehouseName = $LakehouseInfo.DisplayName
    $lakehouseId = $LakehouseInfo.FabricId
    $expectedKey = $LakehouseInfo.ExpectedKey
    $importId = "$WorkspaceId/$lakehouseId"
   
    # Build properly escaped resource address
    $resourceAddress = "module.lakehouse_names.fabric_lakehouse.this[\`"$expectedKey\`"]"
   
    Write-Host "##[section]$($script:Emoji.Download) Importing lakehouse: $lakehouseName"
    Write-Host "##[debug]  Resource Address: $resourceAddress"
    Write-Host "##[debug]  Import ID: $importId"
   
    $attemptCount = 0
    $importSucceeded = $false
   
    while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
        $attemptCount++
       
        try {
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            Write-Host "##[debug]Executing terraform import with tfvars file"
           
            # Execute terraform import with proper escaping
            $result = terraform import -var-file="terraform.tfvars" `
                "$resourceAddress" `
                "$importId" 2>&1
           
            $exitCode = $LASTEXITCODE
           
            Write-Host "##[debug]Command: terraform import -var-file=`"terraform.tfvars`" `"$resourceAddress`" `"$importId`""
           
            if ($exitCode -eq 0) {
                $importSucceeded = $true
                Write-Host "##[section]$($script:Emoji.Success) Successfully imported lakehouse: $lakehouseName"
                return $true
            } else {
                Write-Host "##[warning]$($script:Emoji.Warning) Lakehouse import failed (attempt $attemptCount):"
                $result | ForEach-Object { Write-Host "##[warning]  $_" }
               
                # Check for already exists indicators
                $resultString = $result -join " "
                if ($resultString -match "Resource already managed by Terraform" -or
                    $resultString -match "already exists in state") {
                    Write-Host "##[info]$($script:Emoji.Info) Lakehouse resource already managed - verifying state"
                   
                    $stateShow = terraform state show "$resourceAddress" 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "##[section]$($script:Emoji.Success) Lakehouse resource confirmed in state: $lakehouseName"
                        return $true
                    }
                }
            }
        }
        catch {
            Write-Host "##[error]$($script:Emoji.Error) Exception during lakehouse import attempt $attemptCount : $($_.Exception.Message)"
        }
    }
   
    Write-Host "##[error]$($script:Emoji.Error) Failed to import lakehouse after $MaxRetryAttempts attempts: $lakehouseName"
    return $false
}


function Import-AllMissingLakehouses {
    param(
        [Parameter(Mandatory=$true)]
        [array]$MissingLakehouses,
       
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    if ($MissingLakehouses.Count -eq 0) {
        Write-Host "##[section]$($script:Emoji.Success) No missing lakehouses to import"
        return $true
    }
   
    Write-Host "##[section]$($script:Emoji.Download) Starting import of $($MissingLakehouses.Count) missing lakehouses"
   
    $successCount = 0
    $failedImports = @()
   
    foreach ($lakehouse in $MissingLakehouses) {
        $importSuccess = Import-MissingLakehouse -LakehouseInfo $lakehouse -WorkspaceId $WorkspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        if ($importSuccess) {
            $successCount++
        } else {
            $failedImports += $lakehouse
        }
       
        # Small delay between imports to avoid overwhelming the API
        if ($lakehouse -ne $MissingLakehouses[-1]) {
            Start-Sleep -Seconds 2
        }
    }
   
    Write-Host ""
    Write-Host "##[section]$($script:Emoji.Stats) Lakehouse Import Results:"
    Write-Host "##[debug]  Successful: $successCount"
    Write-Host "##[debug]  Failed: $($failedImports.Count)"
    Write-Host "##[debug]  Total: $($MissingLakehouses.Count)"
   
    if ($failedImports.Count -gt 0) {
        Write-Host "##[warning]$($script:Emoji.Warning) Failed lakehouse imports:"
        foreach ($failed in $failedImports) {
            Write-Host "##[warning]  - $($failed.DisplayName)"
        }
    }
   
    return ($successCount -eq $MissingLakehouses.Count)
}

# ===================================================================
# NOTEBOOK COMPARISON AND IMPORT FUNCTIONS
# ===================================================================
function Compare-NotebookStates {
    param(
        [Parameter(Mandatory=$true)]
        [array]$FabricNotebooks,
       
        [Parameter(Mandatory=$false)]
        [array]$TerraformNotebooks,
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName
    )
   
    Write-Host "##[debug]$($script:Emoji.Stats) Comparing Fabric and Terraform notebook states"
    if (-not $TerraformNotebooks -or $TerraformNotebooks.Count -eq 0) {
        Write-Host "##[warning]$($script:Emoji.Warning) No Terraform notebooks found in state"
    }
    Write-Host "##[debug]  Fabric notebooks: $($FabricNotebooks.Count)"
    Write-Host "##[debug]  Terraform notebooks: $($TerraformNotebooks.Count)"
    Write-Host "##[debug]  Workspace name: $WorkspaceName"
   
    $missingNotebooks = @()
   
    foreach ($fabricNotebook in $FabricNotebooks) {
        $fabricName = $fabricNotebook.displayName
       
        # Check if this notebook exists in Terraform state
        $existsInState = $TerraformNotebooks | Where-Object { $_.NotebookName -eq $fabricName }
       
        if (-not $existsInState) {
            # Generate the expected key format for notebooks
            $expectedKey = "$WorkspaceName-$fabricName.Notebook"
            $expectedAddress = "module.notebooks.fabric_notebook.this[`"$expectedKey`"]"
           
            $missingNotebooks += @{
                FabricId = $fabricNotebook.id
                DisplayName = $fabricName
                ExpectedKey = $expectedKey
                ExpectedAddress = $expectedAddress
            }
           
            Write-Host "##[debug]$($script:Emoji.Warning) Missing notebook from state: $fabricName"
        } else {
            Write-Host "##[debug]$($script:Emoji.Success) Notebook already in state: $fabricName"
        }
    }
   
    Write-Host "##[debug]$($script:Emoji.Stats) Found $($missingNotebooks.Count) missing notebooks"
   
    return $missingNotebooks
}

function Import-MissingNotebook {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$NotebookInfo,
       
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    $notebookName = $NotebookInfo.DisplayName
    $notebookId = $NotebookInfo.FabricId
    $expectedKey = $NotebookInfo.ExpectedKey
    $importId = "$WorkspaceId/$notebookId"
   
    # Build properly escaped resource address
    $resourceAddress = "module.notebooks.fabric_notebook.this[\`"$expectedKey\`"]"
   
    Write-Host "##[section]$($script:Emoji.Download) Importing notebook: $notebookName"
    Write-Host "##[debug]  Resource Address: $resourceAddress"
    Write-Host "##[debug]  Import ID: $importId"
   
    $attemptCount = 0
    $importSucceeded = $false
   
    while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
        $attemptCount++
       
        try {
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            Write-Host "##[debug]Executing terraform import with tfvars file"
           
            # Execute terraform import with proper escaping
            $result = terraform import -var-file="terraform.tfvars" `
                "$resourceAddress" `
                "$importId" 2>&1
           
            $exitCode = $LASTEXITCODE
           
            Write-Host "##[debug]Command: terraform import -var-file=`"terraform.tfvars`" `"$resourceAddress`" `"$importId`""
           
            if ($exitCode -eq 0) {
                $importSucceeded = $true
                Write-Host "##[section]$($script:Emoji.Success) Successfully imported notebook: $notebookName"
                return $true
            } else {
                Write-Host "##[warning]$($script:Emoji.Warning) Notebook import failed (attempt $attemptCount):"
                $result | ForEach-Object { Write-Host "##[warning]  $_" }
               
                # Check for already exists indicators
                $resultString = $result -join " "
                if ($resultString -match "Resource already managed by Terraform" -or
                    $resultString -match "already exists in state") {
                    Write-Host "##[info]$($script:Emoji.Info) Notebook resource already managed - verifying state"
                   
                    $stateShow = terraform state show "$resourceAddress" 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "##[section]$($script:Emoji.Success) Notebook resource confirmed in state: $notebookName"
                        return $true
                    }
                }
            }
        }
        catch {
            Write-Host "##[error]$($script:Emoji.Error) Exception during notebook import attempt $attemptCount : $($_.Exception.Message)"
        }
    }
   
    Write-Host "##[error]$($script:Emoji.Error) Failed to import notebook after $MaxRetryAttempts attempts: $notebookName"
    return $false
}

function Import-AllMissingNotebooks {
    param(
        [Parameter(Mandatory=$true)]
        [array]$MissingNotebooks,
       
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    if ($MissingNotebooks.Count -eq 0) {
        Write-Host "##[section]$($script:Emoji.Success) No missing notebooks to import"
        return $true
    }
   
    Write-Host "##[section]$($script:Emoji.Download) Starting import of $($MissingNotebooks.Count) missing notebooks"
   
    $successCount = 0
    $failedImports = @()
   
    foreach ($notebook in $MissingNotebooks) {
        $importSuccess = Import-MissingNotebook -NotebookInfo $notebook -WorkspaceId $WorkspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        if ($importSuccess) {
            $successCount++
        } else {
            $failedImports += $notebook
        }
       
        # Small delay between imports to avoid overwhelming the API
        if ($notebook -ne $MissingNotebooks[-1]) {
            Start-Sleep -Seconds 2
        }
    }
   
    Write-Host ""
    Write-Host "##[section]$($script:Emoji.Stats) Notebook Import Results:"
    Write-Host "##[debug]  Successful: $successCount"
    Write-Host "##[debug]  Failed: $($failedImports.Count)"
    Write-Host "##[debug]  Total: $($MissingNotebooks.Count)"
   
    if ($failedImports.Count -gt 0) {
        Write-Host "##[warning]$($script:Emoji.Warning) Failed notebook imports:"
        foreach ($failed in $failedImports) {
            Write-Host "##[warning]  - $($failed.DisplayName)"
        }
    }
   
    return ($successCount -eq $MissingNotebooks.Count)
}

# ===================================================================
# WORKSPACE COMPARISON AND IMPORT FUNCTIONS
# ===================================================================

function Compare-WorkspaceStates {
    param(
        [Parameter(Mandatory=$true)]
        [array]$TerraformWorkspaces,
       
        [Parameter(Mandatory=$false)]
        [string]$TargetWorkspaceName,
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceId
    )
   
    Write-Host "##[debug]$($script:Emoji.Stats) Comparing Terraform workspace state with target workspace"
    if (-not $TerraformWorkspaces -or $TerraformWorkspaces.Count -eq 0) {
        Write-Host "##[warning]$($script:Emoji.Warning) No Terraform workspaces found in state"
    }
    Write-Host "##[debug]  Terraform workspaces: $($TerraformWorkspaces.Count)"
    Write-Host "##[debug]  Target workspace name: $TargetWorkspaceName"
    Write-Host "##[debug]  Target workspace ID: $WorkspaceId"
   
    $missingWorkspaces = @()
   
    # Check if target workspace exists in Terraform state
    $existsInState = $TerraformWorkspaces | Where-Object { $_.WorkspaceName -eq $TargetWorkspaceName }
   
    if (-not $existsInState) {
        # Generate the expected key format for workspaces
        $expectedKey = $TargetWorkspaceName
        $expectedAddress = "module.fabric_workspace.fabric_workspace.this[`"$expectedKey`"]"
       
        $missingWorkspaces += @{
            FabricId = $WorkspaceId
            DisplayName = $TargetWorkspaceName
            ExpectedKey = $expectedKey
            ExpectedAddress = $expectedAddress
        }
       
        Write-Host "##[debug]$($script:Emoji.Warning) Missing workspace from state: $TargetWorkspaceName"
    } else {
        Write-Host "##[debug]$($script:Emoji.Success) Workspace already in state: $TargetWorkspaceName"
    }
   
    Write-Host "##[debug]$($script:Emoji.Stats) Found $($missingWorkspaces.Count) missing workspaces"
   
    return $missingWorkspaces
}

function Import-MissingWorkspace {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$WorkspaceInfo,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    $workspaceName = $WorkspaceInfo.DisplayName
    $workspaceId = $WorkspaceInfo.FabricId
    $expectedKey = $WorkspaceInfo.ExpectedKey
    $importId = $workspaceId
   
    # Build properly escaped resource address
    $resourceAddress = "module.fabric_workspace.fabric_workspace.this[\`"$expectedKey\`"]"
   
    Write-Host "##[section]$($script:Emoji.Download) Importing workspace: $workspaceName"
    Write-Host "##[debug]  Resource Address: $resourceAddress"
    Write-Host "##[debug]  Import ID: $importId"
   
    $attemptCount = 0
    $importSucceeded = $false
   
    while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
        $attemptCount++
       
        try {
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            Write-Host "##[debug]Executing terraform import with tfvars file"
           
            # Execute terraform import with proper escaping
            $result = terraform import -var-file="terraform.tfvars" `
                "$resourceAddress" `
                "$importId" 2>&1
           
            $exitCode = $LASTEXITCODE
           
            Write-Host "##[debug]Command: terraform import -var-file=`"terraform.tfvars`" `"$resourceAddress`" `"$importId`""
           
            if ($exitCode -eq 0) {
                $importSucceeded = $true
                Write-Host "##[section]$($script:Emoji.Success) Successfully imported workspace: $workspaceName"
                return $true
            } else {
                Write-Host "##[warning]$($script:Emoji.Warning) Workspace import failed (attempt $attemptCount):"
                $result | ForEach-Object { Write-Host "##[warning]  $_" }
               
                # Check for already exists indicators
                $resultString = $result -join " "
                if ($resultString -match "Resource already managed by Terraform" -or
                    $resultString -match "already exists in state") {
                    Write-Host "##[info]$($script:Emoji.Info) Workspace resource already managed - verifying state"
                   
                    $stateShow = terraform state show "$resourceAddress" 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "##[section]$($script:Emoji.Success) Workspace resource confirmed in state: $workspaceName"
                        return $true
                    }
                }
            }
        }
        catch {
            Write-Host "##[error]$($script:Emoji.Error) Exception during workspace import attempt $attemptCount : $($_.Exception.Message)"
        }
    }
   
    Write-Host "##[error]$($script:Emoji.Error) Failed to import workspace after $MaxRetryAttempts attempts: $workspaceName"
    return $false
}

function Import-AllMissingWorkspaces {
    param(
        [Parameter(Mandatory=$true)]
        [array]$MissingWorkspaces,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    if ($MissingWorkspaces.Count -eq 0) {
        Write-Host "##[section]$($script:Emoji.Success) No missing workspaces to import"
        return $true
    }
   
    Write-Host "##[section]$($script:Emoji.Download) Starting import of $($MissingWorkspaces.Count) missing workspaces"
   
    $successCount = 0
    $failedImports = @()
   
    foreach ($workspace in $MissingWorkspaces) {
        $importSuccess = Import-MissingWorkspace -WorkspaceInfo $workspace -MaxRetryAttempts $MaxRetryAttempts
       
        if ($importSuccess) {
            $successCount++
        } else {
            $failedImports += $workspace
        }
       
        # Small delay between imports to avoid overwhelming the API
        if ($workspace -ne $MissingWorkspaces[-1]) {
            Start-Sleep -Seconds 2
        }
    }
   
    Write-Host ""
    Write-Host "##[section]$($script:Emoji.Stats) Workspace Import Results:"
    Write-Host "##[debug]  Successful: $successCount"
    Write-Host "##[debug]  Failed: $($failedImports.Count)"
    Write-Host "##[debug]  Total: $($MissingWorkspaces.Count)"
   
    if ($failedImports.Count -gt 0) {
        Write-Host "##[warning]$($script:Emoji.Warning) Failed workspace imports:"
        foreach ($failed in $failedImports) {
            Write-Host "##[warning]  - $($failed.DisplayName)"
        }
    }
   
    return ($successCount -eq $MissingWorkspaces.Count)
}

# ===================================================================
# MAIN ORCHESTRATION FUNCTION
# ===================================================================
function Invoke-DynamicLakehouseStateDriftRecovery {
    param(
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1,
       
        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )
   
    Write-Host "==================================================================="
    Write-Host "  $($script:Emoji.Gear) DYNAMIC LAKEHOUSE STATE DRIFT RECOVERY"
    Write-Host "  Automatically detecting and importing missing environments and lakehouses"
    Write-Host "==================================================================="
    Write-Host "Max Retry Attempts: $MaxRetryAttempts"
    Write-Host "Dry Run: $($DryRun.IsPresent)"
    Write-Host "==================================================================="
    Write-Host ""
   
    try {
        # Step 1: Validate terraform.tfvars file exists
        Write-Host "##[section]$($script:Emoji.Gear) Step 1: Validate Terraform Variables File"
        $tfvarsExists = Test-TerraformVariablesFile
        if (-not $tfvarsExists) {
            throw "terraform.tfvars file is required but not found"
        }
       
        # Step 2: Extract workspace name from terraform.tfvars
        Write-Host "##[section]$($script:Emoji.Extract) Step 2: Extract Workspace Name from terraform.tfvars"
        $workspaceName = Get-WorkspaceNameFromTfvars
        Write-Host "##[debug]$($script:Emoji.Success) Using workspace name: $workspaceName"
       
        # Step 3: Get workspace ID from Fabric API
        Write-Host "##[section]$($script:Emoji.Globe) Step 3: Get Workspace ID from Fabric API"
        $workspaceId = Get-FabricWorkspaceId -WorkspaceName $workspaceName -MaxRetryAttempts $MaxRetryAttempts
        Write-Host "##[debug]$($script:Emoji.Success) Using workspace ID: $workspaceId"
       
        # Step 4: Process Workspaces (before environments)
        Write-Host "##[section]$($script:Emoji.Cloud) Step 4: Process Workspaces"
       
        # Get current Terraform workspace state
        Write-Host "##[section]$($script:Emoji.Magnify) Step 4a: Get Current Terraform Workspace State"
        $terraformWorkspaces = Get-TerraformWorkspaceState
       
        # Compare states and find missing workspaces (using already obtained workspace info)
        Write-Host "##[section]$($script:Emoji.Stats) Step 4b: Compare Workspace States and Identify Missing"
        $missingWorkspaces = Compare-WorkspaceStates -TerraformWorkspaces $terraformWorkspaces -TargetWorkspaceName $workspaceName -WorkspaceId $workspaceId
       
        # Import missing workspaces
        Write-Host "##[section]$($script:Emoji.Download) Step 4c: Import Missing Workspaces"
       
        if ($DryRun) {
            Write-Host "##[info]$($script:Emoji.Info) DRY RUN - Would import the following workspaces:"
            foreach ($workspace in $missingWorkspaces) {
                Write-Host "##[info]  - $($workspace.DisplayName) -> $($workspace.ExpectedAddress)"
            }
        } else {
            if ($missingWorkspaces.Count -eq 0) {
                Write-Host "##[section]$($script:Emoji.Success) No missing workspaces to import"
            } else {
                $workspaceImportSuccess = Import-AllMissingWorkspaces -MissingWorkspaces $missingWorkspaces -MaxRetryAttempts $MaxRetryAttempts
            }
        }

        # Step 5: Process Environments (after workspaces, before lakehouses)
        Write-Host "##[section]$($script:Emoji.Environment) Step 5: Process Environments"
       
        # Get environments from Fabric
        Write-Host "##[section]$($script:Emoji.Globe) Step 5a: Get Environments from Fabric API"
        $fabricEnvironments = Get-FabricEnvironments -WorkspaceId $workspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        # Get current Terraform environment state
        Write-Host "##[section]$($script:Emoji.Magnify) Step 5b: Get Current Terraform Environment State"
        $terraformEnvironments = Get-TerraformEnvironmentState
       
        # Compare states and find missing environments
        Write-Host "##[section]$($script:Emoji.Stats) Step 5c: Compare Environment States and Identify Missing"
        $missingEnvironments = Compare-EnvironmentStates -FabricEnvironments $fabricEnvironments -TerraformEnvironments $terraformEnvironments -WorkspaceName $workspaceName
       
        # Import missing environments
        Write-Host "##[section]$($script:Emoji.Download) Step 5d: Import Missing Environments"
       
        if ($DryRun) {
            Write-Host "##[info]$($script:Emoji.Info) DRY RUN - Would import the following environments:"
            foreach ($environment in $missingEnvironments) {
                Write-Host "##[info]  - $($environment.DisplayName) -> $($environment.ExpectedAddress)"
            }
        } else {
            if ($missingEnvironments.Count -eq 0) {
                Write-Host "##[section]$($script:Emoji.Success) No missing environments to import"
            } else {
                $environmentImportSuccess = Import-AllMissingEnvironments -MissingEnvironments $missingEnvironments -WorkspaceId $workspaceId -MaxRetryAttempts $MaxRetryAttempts
            }
        }
       
        # Step 6: Process Lakehouses (after environments)
        Write-Host "##[section]$($script:Emoji.Lakehouse) Step 6: Process Lakehouses"
       
        # Get lakehouses from Fabric
        Write-Host "##[section]$($script:Emoji.Globe) Step 6a: Get Lakehouses from Fabric API"
        $fabricLakehouses = Get-FabricLakehouses -WorkspaceId $workspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        # Get current Terraform lakehouse state
        Write-Host "##[section]$($script:Emoji.Magnify) Step 6b: Get Current Terraform Lakehouse State"
        $terraformLakehouses = Get-TerraformLakehouseState
       
        # Compare states and find missing lakehouses
        Write-Host "##[section]$($script:Emoji.Stats) Step 6c: Compare Lakehouse States and Identify Missing"
        $missingLakehouses = Compare-LakehouseStates -FabricLakehouses $fabricLakehouses -TerraformLakehouses $terraformLakehouses -WorkspaceName $workspaceName
       
        # Import missing lakehouses
        Write-Host "##[section]$($script:Emoji.Download) Step 6d: Import Missing Lakehouses"
       
        if ($DryRun) {
            Write-Host "##[info]$($script:Emoji.Info) DRY RUN - Would import the following lakehouses:"
            foreach ($lakehouse in $missingLakehouses) {
                Write-Host "##[info]  - $($lakehouse.DisplayName) -> $($lakehouse.ExpectedAddress)"
            }
        } else {
            if ($missingLakehouses.Count -eq 0) {
                Write-Host "##[section]$($script:Emoji.Success) No missing lakehouses to import"
            } else {
                $lakehouseImportSuccess = Import-AllMissingLakehouses -MissingLakehouses $missingLakehouses -WorkspaceId $workspaceId -MaxRetryAttempts $MaxRetryAttempts
            }
        }
       
        # Step 7: Process Notebooks (after lakehouses)
        Write-Host "##[section]$($script:Emoji.Notebook) Step 7: Process Notebooks"
       
        # Get notebooks from Fabric
        Write-Host "##[section]$($script:Emoji.Globe) Step 7a: Get Notebooks from Fabric API"
        $fabricNotebooks = Get-FabricNotebooks -WorkspaceId $workspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        # Get current Terraform notebook state
        Write-Host "##[section]$($script:Emoji.Magnify) Step 7b: Get Current Terraform Notebook State"
        $terraformNotebooks = Get-TerraformNotebookState
       
        # Compare states and find missing notebooks
        Write-Host "##[section]$($script:Emoji.Stats) Step 7c: Compare Notebook States and Identify Missing"
        $missingNotebooks = Compare-NotebookStates -FabricNotebooks $fabricNotebooks -TerraformNotebooks $terraformNotebooks -WorkspaceName $workspaceName
       
        # Import missing notebooks
        Write-Host "##[section]$($script:Emoji.Download) Step 7d: Import Missing Notebooks"
       
        if ($DryRun) {
            Write-Host "##[info]$($script:Emoji.Info) DRY RUN - Would import the following notebooks:"
            foreach ($notebook in $missingNotebooks) {
                Write-Host "##[info]  - $($notebook.DisplayName) -> $($notebook.ExpectedAddress)"
            }
        } else {
            if ($missingNotebooks.Count -eq 0) {
                Write-Host "##[section]$($script:Emoji.Success) No missing notebooks to import"
            } else {
                $notebookImportSuccess = Import-AllMissingNotebooks -MissingNotebooks $missingNotebooks -WorkspaceId $workspaceId -MaxRetryAttempts $MaxRetryAttempts
            }
        }

        # Step 8: Refresh Terraform state
        # if (-not $DryRun -and (($missingWorkspaces.Count -gt 0) -or ($missingEnvironments.Count -gt 0) -or ($missingLakehouses.Count -gt 0) -or ($missingNotebooks.Count -gt 0))) {
        #     Write-Host "##[section]$($script:Emoji.Refresh) Step 8: Refresh Terraform State"
        #     try {
        #         Write-Host "##[debug]Executing terraform refresh..."
        #         terraform refresh
        #         if ($LASTEXITCODE -eq 0) {
        #             Write-Host "##[section]$($script:Emoji.Success) Terraform state refreshed successfully"
        #         } else {
        #             Write-Host "##[warning]$($script:Emoji.Warning) Terraform refresh had issues but imports were successful"
        #         }
        #     }
        #     catch {
        #         Write-Host "##[warning]$($script:Emoji.Warning) Terraform refresh failed but imports were successful: $($_.Exception.Message)"
        #     }
        # }

        # Final result reporting section
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.Success) DYNAMIC ARTIFACTS STATE DRIFT RECOVERY COMPLETED SUCCESSFULLY"
        if ($DryRun) {
            Write-Host "##[section]$($script:Emoji.Info) DRY RUN completed - no actual changes made"
        } else {
            if ($missingWorkspaces.Count -gt 0) {
                Write-Host "##[section]$($script:Emoji.Success) Successfully processed $($missingWorkspaces.Count) missing workspaces"
            }
            if ($missingEnvironments.Count -gt 0) {
                Write-Host "##[section]$($script:Emoji.Success) Successfully processed $($missingEnvironments.Count) missing environments"
            }
            if ($missingLakehouses.Count -gt 0) {
                Write-Host "##[section]$($script:Emoji.Success) Successfully processed $($missingLakehouses.Count) missing lakehouses"
            }
            if ($missingNotebooks.Count -gt 0) {
                Write-Host "##[section]$($script:Emoji.Success) Successfully processed $($missingNotebooks.Count) missing notebooks"
            }
        }
        return $true
       
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Dynamic lakehouse state drift recovery failed: $($_.Exception.Message)"
        Write-Host "##[error]Stack trace: $($_.ScriptStackTrace)"
        return $false
    }
}


# ===================================================================
# MAIN FUNCTION FOR DIRECT SCRIPT EXECUTION
# ===================================================================
function Main {
    param(
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1,
       
        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )
   
    Write-Host "==================================================================="
    Write-Host "  MAIN EXECUTION - DYNAMIC LAKEHOUSE STATE DRIFT RECOVERY"
    Write-Host "==================================================================="
    Write-Host "Max Retry Attempts:  $MaxRetryAttempts"
    Write-Host "Dry Run:             $($DryRun.IsPresent)"
    Write-Host "==================================================================="
    Write-Host ""
   
    # Verify Terraform is available and backend is configured
    try {
        Write-Host "##[debug]$($script:Emoji.Magnify) Verifying Terraform setup..."
       
        $terraformVersion = terraform version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "##[error]$($script:Emoji.Error) Terraform is not available or not in PATH"
            exit 1
        }
       
        # Test if terraform state is accessible
        $stateTest = terraform state list 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "##[error]$($script:Emoji.Error) Cannot access Terraform state. Ensure 'terraform init' has been run."
            Write-Host "##[error]State test output: $stateTest"
            exit 1
        }
       
        Write-Host "##[debug]$($script:Emoji.Success) Terraform backend is configured and accessible"
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Error verifying Terraform setup: $($_.Exception.Message)"
        exit 1
    }
   
    try {
        # Call the main recovery function with parameters
        $params = @{
            MaxRetryAttempts = $MaxRetryAttempts
        }
       
        if ($DryRun) { $params.DryRun = $DryRun }
       
        Write-Host "##[section] Starting recovery process..."
        $result = Invoke-DynamicLakehouseStateDriftRecovery @params
       
        Write-Host ""
        if ($result) {
            Write-Host "$($script:Emoji.Success) Recovery completed successfully!" -ForegroundColor Green
            exit 0
        } else {
            Write-Host "$($script:Emoji.Error) Recovery completed with errors." -ForegroundColor Red
            exit 1
        }
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Error during recovery: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
        exit 1
    }
}

# Call Main function with parameters
Main
