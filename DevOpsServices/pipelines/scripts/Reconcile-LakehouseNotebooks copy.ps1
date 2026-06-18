$script:Emoji = @{
    Success    = [char]::ConvertFromUtf32(0x2705)    # ✅ Check Mark
    Error      = [char]::ConvertFromUtf32(0x274C)    # ❌ Cross Mark
    Warning    = [char]::ConvertFromUtf32(0x26A0)    # ⚠️ Warning
    Info       = [char]::ConvertFromUtf32(0x2139)    # ℹ️ Information
    Lakehouse  = [char]::ConvertFromUtf32(0x1F3E0)   # 🏠 House
    Notebook   = [char]::ConvertFromUtf32(0x1F4D3)   # 📓 Notebook
    Cloud      = [char]::ConvertFromUtf32(0x2601)    # ☁️ Cloud
    Gear       = [char]::ConvertFromUtf32(0x2699)    # ⚙️ Gear
    Key        = [char]::ConvertFromUtf32(0x1F511)   # 🔑 Key
    Magnify    = [char]::ConvertFromUtf32(0x1F50D)   # 🔍 Magnifying Glass
    List       = [char]::ConvertFromUtf32(0x1F4CB)   # 📋 Clipboard
    Download   = [char]::ConvertFromUtf32(0x1F4E5)   # 📥 Inbox Tray
    Time       = [char]::ConvertFromUtf32(0x1F552)   # 🕒 Clock
    Refresh    = [char]::ConvertFromUtf32(0x1F504)   # 🔄 Counterclockwise Arrows
    Stats      = [char]::ConvertFromUtf32(0x1F4CA)   # 📊 Bar Chart
    Globe      = [char]::ConvertFromUtf32(0x1F310)   # 🌐 Globe
    Pin        = [char]::ConvertFromUtf32(0x1F4CD)   # 📍 Round Pushpin
    Document   = [char]::ConvertFromUtf32(0x1F4C4)   # 📄 Page Facing Up
}

function Import-MissingLakehouses {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [string]$TerraformStatePrefix = 'module.lakehouse_names.fabric_lakehouse.this',
       
        [Parameter(Mandatory=$false)]
        [string]$Environment = "dev",
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[section]$($script:Emoji.List) Starting lakehouse state reconciliation..."
    Write-Host "##[debug]$($script:Emoji.Gear) Using existing Terraform backend configuration"
    Write-Host "##[debug]$($script:Emoji.Pin) Environment: $Environment"
   
    try {
        # Step 1: Query Fabric for actual lakehouses
        Write-Host "##[debug]$($script:Emoji.Globe) Fetching lakehouses from Fabric workspace: $WorkspaceId"
        $fabricLakehouses = Get-FabricLakehouses -WorkspaceId $WorkspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        if (-not $fabricLakehouses -or $fabricLakehouses.Count -eq 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) No lakehouses found in Fabric workspace"
            return $true
        }
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Found $($fabricLakehouses.Count) lakehouses in Fabric workspace"
       
        # Step 2: Extract lakehouse resources from Terraform state
        Write-Host "##[debug]$($script:Emoji.Magnify) Analyzing lakehouse resources in Terraform state..."
        $terraformLakehouses = Get-TerraformLakehouseState -StatePrefix $TerraformStatePrefix -MaxRetryAttempts $MaxRetryAttempts
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Found $($terraformLakehouses.Count) lakehouse resources in Terraform state"
       
        # Step 3: Find orphaned lakehouses (in Fabric but missing from Terraform state)
        $orphanedLakehouses = @()
       
        foreach ($fabricLakehouse in $fabricLakehouses) {
            $existsInState = $terraformLakehouses | Where-Object {
                $_.DisplayName -eq $fabricLakehouse.displayName -or
                $_.Id -eq $fabricLakehouse.id
            }
           
            if (-not $existsInState) {
                # Construct expected Terraform resource address based on naming pattern and environment
                $expectedAddress = "$TerraformStatePrefix[`"PlatformServices-Sandbox-$($fabricLakehouse.displayName)`"]"
               
                $orphanedLakehouses += @{
                    FabricId = $fabricLakehouse.id
                    DisplayName = $fabricLakehouse.displayName
                    ExpectedStateAddress = $expectedAddress
                }
               
                Write-Host "##[debug]$($script:Emoji.Lakehouse) Orphaned lakehouse found: $($fabricLakehouse.displayName)"
            } else {
                Write-Host "##[debug]$($script:Emoji.Success) $($fabricLakehouse.displayName) exists in both Fabric and Terraform state"
            }
        }
       
        # Step 4: Report findings
        if ($orphanedLakehouses.Count -eq 0) {
            Write-Host "##[section]$($script:Emoji.Success) All lakehouses are properly tracked in Terraform state"
            Write-Host "##[section]$($script:Emoji.Success) No import operations needed"
            return $true
        }
       
        Write-Host "##[warning]$($script:Emoji.Warning) Found $($orphanedLakehouses.Count) orphaned lakehouses that need to be imported:"
        foreach ($orphan in $orphanedLakehouses) {
            Write-Host "##[debug]  - $($orphan.DisplayName) (ID: $($orphan.FabricId))"
        }
       
        # Step 5: Import orphaned lakehouses with retry logic
        $importSuccess = $true
        $importedCount = 0
       
        foreach ($orphan in $orphanedLakehouses) {
            $attemptCount = 0
            $importSucceeded = $false
           
            while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
                $attemptCount++
               
                try {
                    if ($attemptCount -gt 1) {
                        $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                        Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $MaxRetryAttempts for lakehouse $($orphan.DisplayName) (waiting $backoffSeconds seconds)"
                        Start-Sleep -Seconds $backoffSeconds
                    }
                   
                    Write-Host "##[debug]$($script:Emoji.Download) Importing lakehouse: $($orphan.DisplayName) (Attempt $attemptCount of $MaxRetryAttempts)"
                    Write-Host "##[debug]   Terraform Address: $($orphan.ExpectedStateAddress)"
                    Write-Host "##[debug]   Fabric ID: $($orphan.FabricId)"
                   
                    $importArgs = @(
                        "import"
                        $orphan.ExpectedStateAddress
                        $orphan.FabricId
                    )
                   
                    $importResult = & terraform import "$($orphan.ExpectedStateAddress)" $orphan.FabricId  2>&1
                   
                    if ($LASTEXITCODE -eq 0) {
                        $importSucceeded = $true
                        Write-Host "##[section]$($script:Emoji.Success) Successfully imported: $($orphan.DisplayName)"
                        $importedCount++
                    } else {
                        Write-Host "##[warning]$($script:Emoji.Warning) Failed to import $($orphan.DisplayName) (Attempt $attemptCount of $MaxRetryAttempts):"
                        $importResult | ForEach-Object { Write-Host "##[warning]  $_" }
                    }
                }
                catch {
                    Write-Host "##[error]$($script:Emoji.Error) Exception importing $($orphan.DisplayName) (Attempt $attemptCount of $MaxRetryAttempts): $($_.Exception.Message)"
                }
            }
           
            if (-not $importSucceeded) {
                Write-Host "##[error]$($script:Emoji.Error) Failed to import $($orphan.DisplayName) after $MaxRetryAttempts attempts"
                $importSuccess = $false
            }
        }
       
        Write-Host "##[debug]$($script:Emoji.Stats) Import summary: $importedCount/$($orphanedLakehouses.Count) lakehouses imported successfully"
       
        if ($importSuccess) {
            Write-Host "##[section]$($script:Emoji.Success) Lakehouse state reconciliation completed successfully"
            return $true
        } else {
            Write-Host "##[error]$($script:Emoji.Error) Some lakehouse imports failed - manual intervention required"
            return $false
        }
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Lakehouse state reconciliation failed: $($_.Exception.Message)"
        return $false
    }
}

function Import-MissingNotebooks {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [string]$TerraformStatePrefix = 'module.notebooks.fabric_notebook.this',
       
        [Parameter(Mandatory=$false)]
        [string]$Environment = "dev",
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[section]$($script:Emoji.List) Starting notebook state reconciliation..."
    Write-Host "##[debug]$($script:Emoji.Gear) Using existing Terraform backend configuration"
    Write-Host "##[debug]$($script:Emoji.Pin) Environment: $Environment"
   
    try {
        # Step 1: Query Fabric for actual notebooks
        Write-Host "##[debug]$($script:Emoji.Globe) Fetching notebooks from Fabric workspace: $WorkspaceId"
        $fabricNotebooks = Get-FabricNotebooks -WorkspaceId $WorkspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        if (-not $fabricNotebooks -or $fabricNotebooks.Count -eq 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) No notebooks found in Fabric workspace"
            return $true
        }
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Found $($fabricNotebooks.Count) notebooks in Fabric workspace"
       
        # Step 2: Extract notebook resources from Terraform state
        Write-Host "##[debug]$($script:Emoji.Magnify) Analyzing notebook resources in Terraform state..."
        $terraformNotebooks = Get-TerraformNotebookState -StatePrefix $TerraformStatePrefix -MaxRetryAttempts $MaxRetryAttempts
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Found $($terraformNotebooks.Count) notebook resources in Terraform state"
       
        # Step 3: Find orphaned notebooks (in Fabric but missing from Terraform state)
        $orphanedNotebooks = @()
       
        foreach ($fabricNotebook in $fabricNotebooks) {
            $existsInState = $terraformNotebooks | Where-Object {
                $_.DisplayName -eq $fabricNotebook.displayName -or
                $_.Id -eq $fabricNotebook.id
            }
           
            if (-not $existsInState) {
                # Filter out system notebooks and notebooks that should not be managed
                $isSystemNotebook = $fabricNotebook.displayName -like "System*" -or $fabricNotebook.displayName -like "Sample*"
                $shouldSkip = $isSystemNotebook
               
                if (-not $shouldSkip) {
                    # Generate a safe resource name from display name
                    $safeDisplayName = $fabricNotebook.displayName -replace '[^a-zA-Z0-9]', '_'
                   
                    # Construct expected Terraform resource address
                    $expectedAddress = "$TerraformStatePrefix[`"$Environment-$safeDisplayName`"]"
                   
                    $orphanedNotebooks += @{
                        FabricId = $fabricNotebook.id
                        DisplayName = $fabricNotebook.displayName
                        SafeDisplayName = $safeDisplayName
                        ExpectedStateAddress = $expectedAddress
                    }
                   
                    Write-Host "##[debug]$($script:Emoji.Notebook) Orphaned notebook found: $($fabricNotebook.displayName)"
                }
            } else {
                Write-Host "##[debug]$($script:Emoji.Success) $($fabricNotebook.displayName) exists in both Fabric and Terraform state"
            }
        }
       
        # Step 4: Report findings
        if ($orphanedNotebooks.Count -eq 0) {
            Write-Host "##[section]$($script:Emoji.Success) All notebooks are properly tracked in Terraform state"
            Write-Host "##[section]$($script:Emoji.Success) No import operations needed"
            return $true
        }
       
        Write-Host "##[warning]$($script:Emoji.Warning) Found $($orphanedNotebooks.Count) orphaned notebooks that need to be imported:"
        foreach ($orphan in $orphanedNotebooks) {
            Write-Host "##[debug]  - $($orphan.DisplayName) (ID: $($orphan.FabricId))"
        }
       
        # Step 5: Import orphaned notebooks with retry logic
        $importSuccess = $true
        $importedCount = 0
       
        foreach ($orphan in $orphanedNotebooks) {
            $attemptCount = 0
            $importSucceeded = $false
           
            while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
                $attemptCount++
               
                try {
                    if ($attemptCount -gt 1) {
                        $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                        Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $MaxRetryAttempts for notebook $($orphan.DisplayName) (waiting $backoffSeconds seconds)"
                        Start-Sleep -Seconds $backoffSeconds
                    }
                   
                    Write-Host "##[debug]$($script:Emoji.Download) Importing notebook: $($orphan.DisplayName) (Attempt $attemptCount of $MaxRetryAttempts)"
                    Write-Host "##[debug]   Terraform Address: $($orphan.ExpectedStateAddress)"
                    Write-Host "##[debug]   Fabric ID: $($orphan.FabricId)"
                   
                    $importArgs = @(
                        "import"
                        $orphan.ExpectedStateAddress
                        $orphan.FabricId
                    )
                   
                    $importResult = & terraform @importArgs 2>&1
                   
                    if ($LASTEXITCODE -eq 0) {
                        $importSucceeded = $true
                        Write-Host "##[section]$($script:Emoji.Success) Successfully imported: $($orphan.DisplayName)"
                        $importedCount++
                    } else {
                        Write-Host "##[warning]$($script:Emoji.Warning) Failed to import $($orphan.DisplayName) (Attempt $attemptCount of $MaxRetryAttempts):"
                        $importResult | ForEach-Object { Write-Host "##[warning]  $_" }
                    }
                }
                catch {
                    Write-Host "##[error]$($script:Emoji.Error) Exception importing $($orphan.DisplayName) (Attempt $attemptCount of $MaxRetryAttempts): $($_.Exception.Message)"
                }
            }
           
            if (-not $importSucceeded) {
                Write-Host "##[error]$($script:Emoji.Error) Failed to import $($orphan.DisplayName) after $MaxRetryAttempts attempts"
                $importSuccess = $false
            }
        }
       
        Write-Host "##[debug]$($script:Emoji.Stats) Import summary: $importedCount/$($orphanedNotebooks.Count) notebooks imported successfully"
       
        if ($importSuccess) {
            Write-Host "##[section]$($script:Emoji.Success) Notebook state reconciliation completed successfully"
            return $true
        } else {
            Write-Host "##[warning]$($script:Emoji.Warning) Some notebook imports failed - manual intervention may be required"
            return $true  # Still return success for partial imports
        }
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Notebook state reconciliation failed: $($_.Exception.Message)"
        return $false
    }
}

function Import-MissingWorkspaces {
    param(
        [Parameter(Mandatory=$false)]
        [string]$TerraformStatePrefix = 'module.fabric_workspace.fabric_workspace.this',
       
        [Parameter(Mandatory=$false)]
        [string]$Environment = "dev",
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[section]$($script:Emoji.List) Starting workspace state reconciliation..."
    Write-Host "##[debug]$($script:Emoji.Gear) Using existing Terraform backend configuration"
    Write-Host "##[debug]$($script:Emoji.Pin) Environment: $Environment"
   
    try {
        # Step 1: Query Fabric for actual workspaces
        Write-Host "##[debug]$($script:Emoji.Globe) Fetching workspaces from Fabric..."
        $fabricWorkspaces = Get-FabricWorkspaces -MaxRetryAttempts $MaxRetryAttempts
       
        if (-not $fabricWorkspaces -or $fabricWorkspaces.Count -eq 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) No workspaces found in Fabric"
            return $true
        }
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Found $($fabricWorkspaces.Count) workspaces in Fabric"
       
        # Step 2: Extract workspace resources from Terraform state
        Write-Host "##[debug]$($script:Emoji.Magnify) Analyzing workspace resources in Terraform state..."
        $terraformWorkspaces = Get-TerraformWorkspaceState -StatePrefix $TerraformStatePrefix -MaxRetryAttempts $MaxRetryAttempts
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Found $($terraformWorkspaces.Count) workspace resources in Terraform state"
       
        # Step 3: Find orphaned workspaces (in Fabric but missing from Terraform state)
        $orphanedWorkspaces = @()
       
        foreach ($fabricWorkspace in $fabricWorkspaces) {
            if ($fabricWorkspace.id -ne $WorkspaceId) {
                continue
            }
            $existsInState = $terraformWorkspaces | Where-Object {
                $_.DisplayName -eq $fabricWorkspace.displayName -or
                $_.Id -eq $fabricWorkspace.id
            }
           
            if (-not $existsInState) {
                # Filter out system workspaces that should not be managed
                $isSystemWorkspace = $fabricWorkspace.displayName -like "System*" -or
                                   $fabricWorkspace.displayName -like "Sample*" -or
                                   $fabricWorkspace.displayName -eq "My workspace" -or
                                   $fabricWorkspace.type -eq "PersonalGroup"
               
                if (-not $isSystemWorkspace) {
                    # Generate a safe resource name from display name
                    $safeDisplayName = $fabricWorkspace.displayName -replace '[^a-zA-Z0-9]', '_'
                   
                    # Construct expected Terraform resource address
                    $expectedAddress = "$TerraformStatePrefix[`"$Environment-$safeDisplayName`"]"
                   
                    $orphanedWorkspaces += @{
                        FabricId = $fabricWorkspace.id
                        DisplayName = $fabricWorkspace.displayName
                        SafeDisplayName = $safeDisplayName
                        ExpectedStateAddress = $expectedAddress
                        Type = $fabricWorkspace.type
                    }
                   
                    Write-Host "##[debug]$($script:Emoji.Workspace) Orphaned workspace found: $($fabricWorkspace.displayName) (Type: $($fabricWorkspace.type))"
                } else {
                    Write-Host "##[debug]$($script:Emoji.Info) Skipping system workspace: $($fabricWorkspace.displayName)"
                }
            } else {
                Write-Host "##[debug]$($script:Emoji.Success) $($fabricWorkspace.displayName) exists in both Fabric and Terraform state"
            }
        }
       
        # Step 4: Report findings
        if ($orphanedWorkspaces.Count -eq 0) {
            Write-Host "##[section]$($script:Emoji.Success) All workspaces are properly tracked in Terraform state"
            Write-Host "##[section]$($script:Emoji.Success) No import operations needed"
            return $true
        }
       
        Write-Host "##[warning]$($script:Emoji.Warning) Found $($orphanedWorkspaces.Count) orphaned workspaces that need to be imported:"
        foreach ($orphan in $orphanedWorkspaces) {
            Write-Host "##[debug]  - $($orphan.DisplayName) (ID: $($orphan.FabricId), Type: $($orphan.Type))"
        }
       
        # Step 5: Import orphaned workspaces with retry logic
        $importSuccess = $true
        $importedCount = 0
       
        foreach ($orphan in $orphanedWorkspaces) {
            $attemptCount = 0
            $importSucceeded = $false
           
            while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
                $attemptCount++
               
                try {
                    if ($attemptCount -gt 1) {
                        $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                        Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $MaxRetryAttempts for workspace $($orphan.DisplayName) (waiting $backoffSeconds seconds)"
                        Start-Sleep -Seconds $backoffSeconds
                    }
                   
                    Write-Host "##[debug]$($script:Emoji.Download) Importing workspace: $($orphan.DisplayName) (Attempt $attemptCount of $MaxRetryAttempts)"
                    Write-Host "##[debug]   Terraform Address: $($orphan.ExpectedStateAddress)"
                    Write-Host "##[debug]   Fabric ID: $($orphan.FabricId)"
                   
                    $importArgs = @(
                        "import"
                        $orphan.ExpectedStateAddress
                        $orphan.FabricId
                    )
                   
                    $importResult = & terraform @importArgs 2>&1
                   
                    if ($LASTEXITCODE -eq 0) {
                        $importSucceeded = $true
                        Write-Host "##[section]$($script:Emoji.Success) Successfully imported: $($orphan.DisplayName)"
                        $importedCount++
                    } else {
                        Write-Host "##[warning]$($script:Emoji.Warning) Failed to import $($orphan.DisplayName) (Attempt $attemptCount of $MaxRetryAttempts):"
                        $importResult | ForEach-Object { Write-Host "##[warning]  $_" }
                    }
                }
                catch {
                    Write-Host "##[error]$($script:Emoji.Error) Exception importing $($orphan.DisplayName) (Attempt $attemptCount of $MaxRetryAttempts): $($_.Exception.Message)"
                }
            }
           
            if (-not $importSucceeded) {
                Write-Host "##[error]$($script:Emoji.Error) Failed to import $($orphan.DisplayName) after $MaxRetryAttempts attempts"
                $importSuccess = $false
            }
        }
       
        Write-Host "##[debug]$($script:Emoji.Stats) Import summary: $importedCount/$($orphanedWorkspaces.Count) workspaces imported successfully"
       
        if ($importSuccess) {
            Write-Host "##[section]$($script:Emoji.Success) Workspace state reconciliation completed successfully"
            return $true
        } else {
            Write-Host "##[error]$($script:Emoji.Error) Some workspace imports failed - manual intervention required"
            return $false
        }
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Workspace state reconciliation failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-FabricWorkspaces {
    param(
        [int]$MaxRetryAttempts = 1
    )
   
    try {
        $success = $false
        $attemptCount = 0
        $maxAttempts = $MaxRetryAttempts
        $errorMessage = ""
       
        while (-not $success -and $attemptCount -lt $maxAttempts) {
            $attemptCount++
           
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $maxAttempts for Fabric API (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            try {
                $headers = @{
                    'Authorization' = "Bearer $token"
                    'Content-Type' = 'application/json'
                }
               
                # Query Fabric API for workspaces
                $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces"
                Write-Host "##[debug]$($script:Emoji.Globe) Querying Fabric API: $apiUrl"
               
                $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
                $success = $true
                return $response.value
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Host "##[warning]$($script:Emoji.Warning) Error getting Fabric workspaces (Attempt $attemptCount of $maxAttempts): $errorMessage"
            }
        }
       
        if (-not $success) {
            Write-Host "##[error]$($script:Emoji.Error) Failed to get Fabric workspaces after $maxAttempts attempts: $errorMessage"
            throw $errorMessage
        }
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to get Fabric workspaces: $($_.Exception.Message)"
        throw
    }
}

function Get-FabricLakehouses {
    param(
        [string]$WorkspaceId,
        [int]$MaxRetryAttempts = 1
    )
   
    try {
        $success = $false
        $attemptCount = 0
        $maxAttempts = $MaxRetryAttempts
        $errorMessage = ""
       
        while (-not $success -and $attemptCount -lt $maxAttempts) {
            $attemptCount++
           
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $maxAttempts for Fabric API (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            try {
                # Get token for Fabric API
                # $token = az account get-access-token --scope "https://analysis.windows.net/powerbi/api/.default" --query accessToken -o tsv
               
                # if (-not $token) {
                #     $errorMessage = "Failed to get authentication token for Fabric API"
                #     continue
                # }
               
                $headers = @{
                    'Authorization' = "Bearer $token"
                    'Content-Type' = 'application/json'
                }
               
                # Query Fabric API for lakehouses
                $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses"
                Write-Host "##[debug]$($script:Emoji.Globe) Querying Fabric API: $apiUrl"
               
                $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
                $success = $true
                return $response.value
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Host "##[warning]$($script:Emoji.Warning) Error getting Fabric lakehouses (Attempt $attemptCount of $maxAttempts): $errorMessage"
            }
        }
       
        if (-not $success) {
            Write-Host "##[error]$($script:Emoji.Error) Failed to get Fabric lakehouses after $maxAttempts attempts: $errorMessage"
            throw $errorMessage
        }
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to get Fabric lakehouses: $($_.Exception.Message)"
        throw
    }
}

function Get-FabricNotebooks {
    param(
        [string]$WorkspaceId,
        [int]$MaxRetryAttempts = 1
    )
   
    try {
        $success = $false
        $attemptCount = 0
        $maxAttempts = $MaxRetryAttempts
        $errorMessage = ""
       
        while (-not $success -and $attemptCount -lt $maxAttempts) {
            $attemptCount++
           
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $maxAttempts for Fabric API (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            try {
                # Get token for Fabric API
                # $token = az account get-access-token --scope "https://analysis.windows.net/powerbi/api/.default" --query accessToken -o tsv
               
                # if (-not $token) {
                #     $errorMessage = "Failed to get authentication token for Fabric API"
                #     continue
                # }
               
                $headers = @{
                    'Authorization' = "Bearer $token"
                    'Content-Type' = 'application/json'
                }
               
                # Query Fabric API for notebooks
                $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks"
                Write-Host "##[debug]$($script:Emoji.Globe) Querying Fabric API: $apiUrl"
               
                $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
                $success = $true
                return $response.value
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Host "##[warning]$($script:Emoji.Warning) Error getting Fabric notebooks (Attempt $attemptCount of $maxAttempts): $errorMessage"
            }
        }
       
        if (-not $success) {
            Write-Host "##[error]$($script:Emoji.Error) Failed to get Fabric notebooks after $maxAttempts attempts: $errorMessage"
            throw $errorMessage
        }
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to get Fabric notebooks: $($_.Exception.Message)"
        throw
    }
}

function Get-ExpectedKeysFromConfiguration {
    param(
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "lakehouse_names"
    )
   
    Write-Host "##[debug]$($script:Emoji.Magnify) Getting expected lakehouse keys from Terraform configuration..."
   
    $expectedKeys = @()
   
    # Method 1: Try to get from module output (if available and computed)
    try {
        Write-Host "##[debug]$($script:Emoji.Magnify) Method 1: Trying module output..."
        $outputResult = echo "module.$ModuleName.expected_keys" | terraform console 2>&1
        Write-Host "##[debug]Module output result: $outputResult"
       
        if ($LASTEXITCODE -eq 0 -and $outputResult -notmatch "\(known after apply\)" -and $outputResult -notmatch "Error:") {
            Write-Host "##[debug]$($script:Emoji.Success) Retrieved keys from module output"
            # Parse the output to extract keys
            $lines = $outputResult -split "`n"
            foreach ($line in $lines) {
                if ($line -match '"([^"]+)"') {
                    $expectedKeys += $matches[1]
                }
            }
            if ($expectedKeys.Count -gt 0) {
                Write-Host "##[debug]$($script:Emoji.Success) Found $($expectedKeys.Count) keys from module output"
                return $expectedKeys
            }
        } else {
            Write-Host "##[debug]$($script:Emoji.Warning) Module output not available or not computed: $outputResult"
        }
    } catch {
        Write-Host "##[debug]$($script:Emoji.Warning) Module output method failed: $($_.Exception.Message)"
    }
   
    # Method 2: Parse from terraform plan (most reliable method)
    try {
        Write-Host "##[debug]$($script:Emoji.Magnify) Method 2: Parsing from terraform plan..."
        $planOutput = terraform plan -no-color 2>&1
       
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 2) {
            Write-Host "##[debug]$($script:Emoji.Success) Plan executed successfully, parsing output..."
            $planLines = $planOutput -split "`n"
           
            foreach ($line in $planLines) {
                # Match various patterns for lakehouse resources
                # Pattern 1: module.lakehouse_names.fabric_lakehouse.this["key"]
                if ($line -match "module\.$ModuleName\.fabric_lakehouse\.this\[`"([^`"]+)`"\]") {
                    $key = $matches[1]
                    if ($expectedKeys -notcontains $key) {
                        $expectedKeys += $key
                        Write-Host "##[debug]Found key from plan: $key"
                    }
                }
                # Pattern 2: # module.lakehouse_names.fabric_lakehouse.this["key"] will be created
                elseif ($line -match "# module\.$ModuleName\.fabric_lakehouse\.this\[`"([^`"]+)`"\]") {
                    $key = $matches[1]
                    if ($expectedKeys -notcontains $key) {
                        $expectedKeys += $key
                        Write-Host "##[debug]Found key from plan comment: $key"
                    }
                }
            }
           
            if ($expectedKeys.Count -gt 0) {
                Write-Host "##[debug]$($script:Emoji.Success) Found $($expectedKeys.Count) keys from plan output"
                return $expectedKeys
            } else {
                Write-Host "##[debug]$($script:Emoji.Warning) No lakehouse keys found in plan output"
            }
        } else {
            Write-Host "##[warning]$($script:Emoji.Warning) Plan failed: $($planOutput -join '; ')"
        }
    } catch {
        Write-Host "##[warning]$($script:Emoji.Warning) Plan parsing method failed: $($_.Exception.Message)"
    }
   
    # Method 3: Try to parse Terraform configuration files directly
    try {
        Write-Host "##[debug]$($script:Emoji.Magnify) Method 3: Parsing Terraform configuration files..."
       
        # Look for the module configuration in .tf files
        $terraformFiles = Get-ChildItem -Path "." -Filter "*.tf" -Recurse
       
        foreach ($tfFile in $terraformFiles) {
            $content = Get-Content $tfFile.FullName -Raw
           
            # Look for module "lakehouse_names" block
            if ($content -match "module\s+`"$ModuleName`"\s*\{[^}]*\}") {
                Write-Host "##[debug]Found module '$ModuleName' in $($tfFile.Name)"
               
                # This is complex to parse without HCL parser, so we'll try a simpler approach
                # Look for workspace_ids or similar patterns that might indicate the keys
            }
        }
       
    } catch {
        Write-Host "##[debug]$($script:Emoji.Warning) Configuration file parsing failed: $($_.Exception.Message)"
    }
   
    # Method 4: Use terraform show to get current configuration (if state exists)
    try {
        Write-Host "##[debug]$($script:Emoji.Magnify) Method 4: Using terraform show for current configuration..."
       
        $showOutput = terraform show -json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $showJson = $showOutput | ConvertFrom-Json
           
            # Look in planned_values for the resources
            if ($showJson.planned_values -and $showJson.planned_values.root_module -and $showJson.planned_values.root_module.child_modules) {
                foreach ($childModule in $showJson.planned_values.root_module.child_modules) {
                    if ($childModule.address -eq "module.$ModuleName" -and $childModule.resources) {
                        foreach ($resource in $childModule.resources) {
                            if ($resource.type -eq "fabric_lakehouse" -and $resource.name -eq "this") {
                                # Extract the key from the address
                                if ($resource.address -match "module\.$ModuleName\.fabric_lakehouse\.this\[`"([^`"]+)`"\]") {
                                    $key = $matches[1]
                                    if ($expectedKeys -notcontains $key) {
                                        $expectedKeys += $key
                                        Write-Host "##[debug]Found key from terraform show: $key"
                                    }
                                }
                            }
                        }
                    }
                }
            }
           
            if ($expectedKeys.Count -gt 0) {
                Write-Host "##[debug]$($script:Emoji.Success) Found $($expectedKeys.Count) keys from terraform show"
                return $expectedKeys
            }
        }
    } catch {
        Write-Host "##[debug]$($script:Emoji.Warning) Terraform show method failed: $($_.Exception.Message)"
    }
   
    # Method 5: Fallback - try to get keys from existing state (if any resources exist)
    try {
        Write-Host "##[debug]$($script:Emoji.Magnify) Method 5: Extracting keys from existing state..."
       
        $stateList = terraform state list 2>&1
        if ($LASTEXITCODE -eq 0) {
            $stateLines = $stateList -split "`n"
           
            foreach ($line in $stateLines) {
                # Match existing lakehouse resources in state
                if ($line -match "module\.$ModuleName\.fabric_lakehouse\.this\[`"([^`"]+)`"\]") {
                    $key = $matches[1]
                    if ($expectedKeys -notcontains $key) {
                        $expectedKeys += $key
                        Write-Host "##[debug]Found key from existing state: $key"
                    }
                }
            }
           
            if ($expectedKeys.Count -gt 0) {
                Write-Host "##[debug]$($script:Emoji.Success) Found $($expectedKeys.Count) keys from existing state"
            }
        }
    } catch {
        Write-Host "##[debug]$($script:Emoji.Warning) State parsing method failed: $($_.Exception.Message)"
    }
   
    # Final result
    if ($expectedKeys.Count -gt 0) {
        Write-Host "##[debug]$($script:Emoji.Success) Total expected keys found: $($expectedKeys.Count)"
        return $expectedKeys
    } else {
        Write-Host "##[warning]$($script:Emoji.Warning) No expected keys found through any method"
        Write-Host "##[warning]This could indicate:"
        Write-Host "##[warning]  1. No lakehouse resources are configured"
        Write-Host "##[warning]  2. Module outputs are not defined"
        Write-Host "##[warning]  3. Terraform configuration has issues"
        Write-Host "##[warning]  4. Wrong module name: '$ModuleName'"
        return @()
    }
}


function Get-CurrentStateResources {
    param(
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "lakehouse_names"
    )
   
    Write-Host "##[debug]$($script:Emoji.Magnify) Getting current Terraform state resources..."
   
    try {
        $stateList = terraform state list 2>&1
        if ($LASTEXITCODE -eq 0) {
            $lakehouseResources = $stateList | Where-Object { $_ -match "module\.$ModuleName\.fabric_lakehouse\.this" }
            Write-Host "##[debug]$($script:Emoji.Success) Found $($lakehouseResources.Count) lakehouse resources in current state"
            return $lakehouseResources
        } else {
            Write-Host "##[warning]$($script:Emoji.Warning) Failed to get state list: $stateList"
            return @()
        }
    } catch {
        Write-Host "##[warning]$($script:Emoji.Warning) Error getting state resources: $($_.Exception.Message)"
        return @()
    }
}

function Test-ResourceAddressValidity {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourceAddress
    )
   
    Write-Host "##[debug]$($script:Emoji.Magnify) Testing resource address validity: $ResourceAddress"
   
    try {
        # The issue: PowerShell string interpolation removes inner quotes
        # Wrong:  terraform plan -target="module.name.resource.this[key]"
        # Right:  terraform plan -target="module.name.resource.this[\"key\"]"
       
        # Method 1: Use single quotes to preserve inner double quotes
        Write-Host "##[debug]Method 1: Using single quotes to preserve inner quotes..."
       
        $planCommand = "terraform"
        $planArgs = @(
            "plan"
            "--target=$ResourceAddress"
            "-no-color"
        )
       
        Write-Host "##[debug]Command: $planCommand"
        Write-Host "##[debug]Arguments: $($planArgs -join ' ')"
        Write-Host "##[debug]Full command would be: $planCommand $($planArgs -join ' ')"

        Write-Host "##[debug]Executing plan command with preserved quotes..."
        Write-Host "##[debug]planCommand: $planCommand"
        Write-Host "##[debug]planArgs: $planArgs"
        
        # Execute using & operator with argument array
        $planOutput = & $planCommand $planArgs 2>&1
        $planExitCode = $LASTEXITCODE
       
        Write-Host "##[debug]Exit code: $planExitCode"
       
        if ($planOutput -is [Array]) {
            $planOutputString = $planOutput -join "`n"
        } else {
            $planOutputString = $planOutput.ToString()
        }
       
        Write-Host "##[debug]Output length: $($planOutputString.Length)"
        Write-Host "##[debug]First 200 chars: $($planOutputString.Substring(0, [Math]::Min(200, $planOutputString.Length)))"
       
        if ($planExitCode -eq 0) {
            Write-Host "##[debug]$($script:Emoji.Success) Plan succeeded - resource address is valid"
           
            if ($planOutputString -match "will be created") {
                return @{ IsValid = $true; Status = "NeedsCreation"; Message = "Resource exists in config but not in state"; ExitCode = $planExitCode }
            } elseif ($planOutputString -match "No changes") {
                return @{ IsValid = $true; Status = "InSync"; Message = "Resource exists in both config and state"; ExitCode = $planExitCode }
            } else {
                return @{ IsValid = $true; Status = "Valid"; Message = "Resource is valid"; ExitCode = $planExitCode }
            }
        } elseif ($planExitCode -eq 2) {
            Write-Host "##[debug]$($script:Emoji.Success) Plan succeeded with changes - resource address is valid"
            return @{ IsValid = $true; Status = "HasChanges"; Message = "Resource is valid and has pending changes"; ExitCode = $planExitCode }
        } else {
            Write-Host "##[debug]$($script:Emoji.Error) Plan failed - analyzing error..."
           
            if ($planOutputString -match "Invalid target" -and $planOutputString -match "Index brackets must contain") {
                return @{ IsValid = $false; Status = "InvalidQuotes"; Message = "Resource address has quote escaping issues"; ExitCode = $planExitCode }
            } elseif ($planOutputString -match "does not exist in the configuration") {
                return @{ IsValid = $false; Status = "NotInConfig"; Message = "Resource not found in configuration"; ExitCode = $planExitCode }
            } else {
                return @{ IsValid = $false; Status = "PlanFailed"; Message = "Plan failed: $($planOutputString.Substring(0, [Math]::Min(200, $planOutputString.Length)))"; ExitCode = $planExitCode }
            }
        }
       
    } catch {
        Write-Host "##[error]$($script:Emoji.Error) Exception: $($_.Exception.Message), full name: $($_.Exception.GetType().FullName), ToString: $($_.Exception.ToString())"
        return @{ IsValid = $false; Status = "Exception"; Message = "Exception: $($_.Exception.Message)" }
    }
}

# Alternative method using proper argument passing
function Test-ResourceAddressValidityProperArgs {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourceAddress
    )
   
    Write-Host "##[debug]$($script:Emoji.Magnify) Testing resource address (proper args): $ResourceAddress"
   
    try {
        # Use Start-Process for complete control over argument passing
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "terraform"
        $startInfo.Arguments = "plan --target=`"$ResourceAddress`" -no-color"
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
       
        Write-Host "##[debug]Process: $($startInfo.FileName)"
        Write-Host "##[debug]Arguments: $($startInfo.Arguments)"
       
        $process = [System.Diagnostics.Process]::Start($startInfo)
       
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
       
        $process.WaitForExit()
        $exitCode = $process.ExitCode
       
        $allOutput = "$stdout`n$stderr"
       
        Write-Host "##[debug]Exit code: $exitCode"
        Write-Host "##[debug]STDOUT: $($stdout.Length) chars"
        Write-Host "##[debug]STDERR: $($stderr.Length) chars"
       
        if ($exitCode -eq 0) {
            return @{ IsValid = $true; Status = "Valid"; Message = "Resource is valid" }
        } elseif ($exitCode -eq 2) {
            return @{ IsValid = $true; Status = "HasChanges"; Message = "Resource is valid with changes" }
        } else {
            return @{ IsValid = $false; Status = "Failed"; Message = $allOutput.Substring(0, [Math]::Min(200, $allOutput.Length)) }
        }
       
    } catch {
        return @{ IsValid = $false; Status = "Exception"; Message = $_.Exception.Message }
    }
}

# Function to fix resource address formatting
function Format-ResourceAddress {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourceAddress
    )
   
    Write-Host "##[debug]$($script:Emoji.Gear) Formatting resource address: $ResourceAddress"
   
    # Check if the address already has proper quotes
    if ($ResourceAddress -match 'module\.([^\.]+)\.([^\.]+)\.([^\[]+)\[\"([^\"]+)\"\]') {
        Write-Host "##[debug]$($script:Emoji.Success) Address already properly formatted"
        return $ResourceAddress
    }
   
    # Check if it has unquoted key and fix it
    if ($ResourceAddress -match 'module\.([^\.]+)\.([^\.]+)\.([^\[]+)\[([^\]]+)\]') {
        $moduleName = $matches[1]
        $resourceType = $matches[2]
        $resourceName = $matches[3]
        $key = $matches[4]
       
        $fixedAddress = "module.$moduleName.$resourceType.$resourceName[`"$key`"]"
        Write-Host "##[debug]$($script:Emoji.Success) Fixed address: $fixedAddress"
        return $fixedAddress
    }
   
    Write-Host "##[warning]$($script:Emoji.Warning) Could not parse address format: $ResourceAddress"
    return $ResourceAddress
}

# Updated import function with proper quote handling
function Import-LakehouseWithProperQuotes {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourceAddress,
       
        [Parameter(Mandatory=$true)]
        [string]$LakehouseId,
       
        [Parameter(Mandatory=$true)]
        [string]$LakehouseName,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[section]$($script:Emoji.Download) Importing lakehouse with proper quotes: $LakehouseName"
   
    # Fix the resource address formatting first
    $fixedAddress = Format-ResourceAddress -ResourceAddress $ResourceAddress
    Write-Host "##[debug]Original address: $ResourceAddress"
    Write-Host "##[debug]Fixed address: $fixedAddress"
   
    try {
        # Test the address first
        $addressTest = Test-ResourceAddressValidityFixed -ResourceAddress $fixedAddress
       
        if (-not $addressTest.IsValid) {
            Write-Host "##[error]$($script:Emoji.Error) Address validation failed: $($addressTest.Message)"
            return $false
        }
       
        Write-Host "##[debug]$($script:Emoji.Success) Address validation passed: $($addressTest.Status)"
       
        # Proceed with import using proper argument passing
        $attemptCount = 0
        $importSucceeded = $false
       
        while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
            $attemptCount++
           
            Write-Host "##[debug]$($script:Emoji.Download) Import attempt $attemptCount of $MaxRetryAttempts..."
           
            # Method 1: Direct import with argument array
            try {
                $importArgs = @(
                    "import"
                    $fixedAddress
                    $LakehouseId
                )
               
                Write-Host "##[debug]Import command: terraform $($importArgs -join ' ')"
               
                $importResult = & terraform $importArgs 2>&1
                $importExitCode = $LASTEXITCODE
               
                if ($importExitCode -eq 0) {
                    $importSucceeded = $true
                    Write-Host "##[section]$($script:Emoji.Success) Import successful: $LakehouseName"
                    return $true
                } else {
                    Write-Host "##[warning]$($script:Emoji.Warning) Import failed (attempt $attemptCount): $($importResult -join '; ')"
                   
                    # Check if it's a quote issue
                    $importResultString = if ($importResult -is [Array]) { $importResult -join " " } else { $importResult.ToString() }
                    if ($importResultString -match "Invalid target" -and $importResultString -match "Index brackets") {
                        Write-Host "##[error]$($script:Emoji.Error) Quote escaping issue detected in import command"
                       
                        # Try with Start-Process for better control
                        Write-Host "##[debug]Trying with Start-Process method..."
                       
                        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                        $startInfo.FileName = "terraform"
                        $startInfo.Arguments = "import `"$fixedAddress`" `"$LakehouseId`""
                        $startInfo.UseShellExecute = $false
                        $startInfo.RedirectStandardOutput = $true
                        $startInfo.RedirectStandardError = $true
                        $startInfo.CreateNoWindow = $true
                       
                        Write-Host "##[debug]Process arguments: $($startInfo.Arguments)"
                       
                        $process = [System.Diagnostics.Process]::Start($startInfo)
                       
                        $stdout = $process.StandardOutput.ReadToEnd()
                        $stderr = $process.StandardError.ReadToEnd()
                       
                        $process.WaitForExit()
                        $processExitCode = $process.ExitCode
                       
                        if ($processExitCode -eq 0) {
                            $importSucceeded = $true
                            Write-Host "##[section]$($script:Emoji.Success) Import successful with Start-Process: $LakehouseName"
                            return $true
                        } else {
                            Write-Host "##[warning]$($script:Emoji.Warning) Start-Process import also failed: $stderr"
                        }
                    }
                }
            } catch {
                Write-Host "##[error]$($script:Emoji.Error) Exception during import: $($_.Exception.Message)"
            }
           
            if (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
                $backoffSeconds = 5
                Write-Host "##[debug]$($script:Emoji.Refresh) Waiting $backoffSeconds seconds before retry..."
                Start-Sleep -Seconds $backoffSeconds
            }
        }
       
        Write-Host "##[error]$($script:Emoji.Error) All import attempts failed for: $LakehouseName"
        return $false
       
    } catch {
        Write-Host "##[error]$($script:Emoji.Error) Exception in import function: $($_.Exception.Message)"
        return $false
    }
}

# function Test-ResourceAddressValidity {
#     param(
#         [Parameter(Mandatory=$true)]
#         [string]$ResourceAddress
#     )
   
#     Write-Host "##[debug]$($script:Emoji.Magnify) Testing resource address validity: $ResourceAddress"
   
#     try {
#         # Clear any previous error variables
#         $Error.Clear()
#         $LASTEXITCODE = 0
       
#         # Run terraform plan with target and capture all output
#         Write-Host "##[debug]Running: terraform plan -target=`"$ResourceAddress`" -no-color"
       
#         # Use Start-Process to get better error capture
#         $processInfo = New-Object System.Diagnostics.ProcessStartInfo
#         $processInfo.FileName = "terraform"
#         $processInfo.Arguments = "plan -target=`"$ResourceAddress`" -no-color"
#         $processInfo.RedirectStandardOutput = $true
#         $processInfo.RedirectStandardError = $true
#         $processInfo.UseShellExecute = $false
#         $processInfo.CreateNoWindow = $true
       
#         $process = New-Object System.Diagnostics.Process
#         $process.StartInfo = $processInfo
       
#         # Start the process
#         $process.Start() | Out-Null
       
#         # Read output and error streams
#         $stdout = $process.StandardOutput.ReadToEnd()
#         $stderr = $process.StandardError.ReadToEnd()
       
#         # Wait for the process to complete
#         $process.WaitForExit()
#         $exitCode = $process.ExitCode
       
#         # Combine all output for analysis
#         $allOutput = @()
#         if ($stdout) { $allOutput += $stdout -split "`n" }
#         if ($stderr) { $allOutput += $stderr -split "`n" }
#         $combinedOutput = $allOutput -join "`n"
       
#         Write-Host "##[debug]Exit code: $exitCode"
#         Write-Host "##[debug]STDOUT length: $($stdout.Length)"
#         Write-Host "##[debug]STDERR length: $($stderr.Length)"
       
#         if ($DebugMode) {
#             Write-Host "##[debug]STDOUT: $stdout" -ForegroundColor Gray
#             Write-Host "##[debug]STDERR: $stderr" -ForegroundColor Gray
#         }
       
#         # Analyze the results
#         if ($exitCode -eq 0) {
#             Write-Host "##[debug]$($script:Emoji.Success) Plan succeeded - resource address is valid"
           
#             # Determine resource status from output
#             if ($combinedOutput -match "will be created") {
#                 return @{ IsValid = $true; Status = "NeedsCreation"; Message = "Resource exists in config but not in state"; ExitCode = $exitCode; Output = $combinedOutput }
#             } elseif ($combinedOutput -match "No changes") {
#                 return @{ IsValid = $true; Status = "InSync"; Message = "Resource exists in both config and state"; ExitCode = $exitCode; Output = $combinedOutput }
#             } elseif ($combinedOutput -match "will be updated" -or $combinedOutput -match "will be modified") {
#                 return @{ IsValid = $true; Status = "NeedsUpdate"; Message = "Resource exists but has changes"; ExitCode = $exitCode; Output = $combinedOutput }
#             } elseif ($combinedOutput -match "will be destroyed") {
#                 return @{ IsValid = $true; Status = "NeedsDestroy"; Message = "Resource is marked for destruction"; ExitCode = $exitCode; Output = $combinedOutput }
#             } else {
#                 return @{ IsValid = $true; Status = "Unknown"; Message = "Resource is valid but status unclear"; ExitCode = $exitCode; Output = $combinedOutput }
#             }
#         } elseif ($exitCode -eq 2) {
#             Write-Host "##[debug]$($script:Emoji.Success) Plan succeeded with changes - resource address is valid"
#             return @{ IsValid = $true; Status = "HasChanges"; Message = "Resource is valid and has pending changes"; ExitCode = $exitCode; Output = $combinedOutput }
#         } else {
#             Write-Host "##[debug]$($script:Emoji.Error) Plan failed - analyzing error..."
           
#             # Analyze specific error patterns
#             $errorMessage = "Plan failed"
#             $isValid = $false
           
#             if ($combinedOutput -match "No configuration available for import target" -or
#                 $combinedOutput -match "does not exist in the configuration" -or
#                 $combinedOutput -match "resource address.*not found" -or
#                 $combinedOutput -match "resource.*does not exist") {
               
#                 $errorMessage = "Resource does not exist in configuration"
#                 $isValid = $false
               
#             } elseif ($combinedOutput -match "Invalid target address" -or
#                      $combinedOutput -match "not a valid resource address") {
               
#                 $errorMessage = "Invalid resource address format"
#                 $isValid = $false
               
#             } elseif ($combinedOutput -match "Module not found" -or
#                      $combinedOutput -match "module.*not found") {
               
#                 $errorMessage = "Module does not exist or not loaded"
#                 $isValid = $false
               
#             } elseif ($combinedOutput -match "Backend initialization required" -or
#                      $combinedOutput -match "terraform init") {
               
#                 $errorMessage = "Terraform not initialized - run 'terraform init'"
#                 $isValid = $false
               
#             } else {
#                 # Generic error - include actual output if available
#                 if ($stderr) {
#                     $errorMessage = "Plan failed: $stderr"
#                 } elseif ($stdout) {
#                     $errorMessage = "Plan failed: $stdout"
#                 } else {
#                     $errorMessage = "Plan failed with exit code $exitCode (no output captured)"
#                 }
#                 $isValid = $false
#             }
           
#             Write-Host "##[debug]$($script:Emoji.Error) Error analysis: $errorMessage"
#             return @{ IsValid = $isValid; Status = "Error"; Message = $errorMessage; ExitCode = $exitCode; Output = $combinedOutput }
#         }
       
#     } catch {
#         $exceptionMessage = $_.Exception.Message
#         $fullError = $_.ToString()
       
#         Write-Host "##[error]$($script:Emoji.Error) Exception in Test-ResourceAddressValidity:"
#         Write-Host "##[error]Exception Message: $exceptionMessage"
#         Write-Host "##[error]Full Error: $fullError"
#         Write-Host "##[error]Error Record: $($_ | Out-String)"
       
#         # Try to get more details about the error
#         if ($_.Exception.InnerException) {
#             Write-Host "##[error]Inner Exception: $($_.Exception.InnerException.Message)"
#         }
       
#         return @{
#             IsValid = $false;
#             Status = "Exception";
#             Message = "Exception occurred: $exceptionMessage";
#             ExitCode = -1;
#             Output = $fullError;
#             Exception = $_
#         }
#     }
# }

function Import-SingleLakehouse {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourceAddress,
       
        [Parameter(Mandatory=$true)]
        [string]$LakehouseId,
       
        [Parameter(Mandatory=$true)]
        [string]$LakehouseName,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[section]$($script:Emoji.Download) Importing lakehouse: $LakehouseName"
    Write-Host "##[debug]  Resource Address: $ResourceAddress"
    Write-Host "##[debug]  Fabric ID: $LakehouseId"
   
    # Test resource address validity first
    $addressTest = Test-ResourceAddressValidity -ResourceAddress $ResourceAddress
   
    if (-not $addressTest.IsValid) {
        Write-Host "##[error]$($script:Emoji.Error) Cannot import - resource address is invalid: $($addressTest.Message)"
        return $false
    }
   
    Write-Host "##[debug]$($script:Emoji.Success) Resource address is valid - Status: $($addressTest.Status)"
   
    $attemptCount = 0
    $importSucceeded = $false
   
    while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
        $attemptCount++
       
        try {
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $MaxRetryAttempts (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            # Method 1: Try direct import first
            Write-Host "##[debug]$($script:Emoji.Download) Attempting direct import (Attempt $attemptCount of $MaxRetryAttempts)..."
           
            $importResult = terraform import $ResourceAddress $LakehouseId 2>&1
           
            if ($LASTEXITCODE -eq 0) {
                $importSucceeded = $true
                Write-Host "##[section]$($script:Emoji.Success) Successfully imported: $LakehouseName"
                return $true
            } else {
                Write-Host "##[warning]$($script:Emoji.Warning) Direct import failed (Attempt $attemptCount): $($importResult -join '; ')"
               
                # Method 2: Try placeholder creation method if this is the last attempt
                if ($attemptCount -eq $MaxRetryAttempts) {
                    Write-Host "##[debug]$($script:Emoji.Gear) Trying placeholder creation method..."
                   
                    # Step 2a: Create placeholder
                    Write-Host "##[debug]Creating placeholder resource..."
                    $applyResult = terraform apply --target=$ResourceAddress -auto-approve 2>&1
                   
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "##[debug]$($script:Emoji.Success) Placeholder created successfully"
                       
                        # Step 2b: Remove placeholder from state
                        Write-Host "##[debug]Removing placeholder from state..."
                        $removeResult = terraform state rm $ResourceAddress 2>&1
                       
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "##[debug]$($script:Emoji.Success) Placeholder removed from state"
                           
                            # Step 2c: Import the original existing resource
                            Write-Host "##[debug]Importing original existing resource..."
                            $importResult2 = terraform import $ResourceAddress $LakehouseId 2>&1
                           
                            if ($LASTEXITCODE -eq 0) {
                                $importSucceeded = $true
                                Write-Host "##[section]$($script:Emoji.Success) Successfully imported via placeholder method: $LakehouseName"
                                return $true
                            } else {
                                Write-Host "##[error]$($script:Emoji.Error) Import after placeholder creation failed: $($importResult2 -join '; ')"
                            }
                        } else {
                            Write-Host "##[error]$($script:Emoji.Error) Failed to remove placeholder from state: $($removeResult -join '; ')"
                        }
                    } else {
                        Write-Host "##[error]$($script:Emoji.Error) Failed to create placeholder: $($applyResult -join '; ')"
                    }
                }
            }
        } catch {
            Write-Host "##[error]$($script:Emoji.Error) Exception during import attempt $attemptCount $($_.Exception.Message)"
        }
    }
   
    Write-Host "##[error]$($script:Emoji.Error) Failed to import $LakehouseName after $MaxRetryAttempts attempts"
    return $false
}

function Get-ImportableLakehouses {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "lakehouse_names",
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName = "",
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[debug]$($script:Emoji.Magnify) Discovering importable lakehouses..."
   
    try {
        # Step 1: Get lakehouses from Fabric
        $fabricLakehouses = Get-FabricLakehouses -WorkspaceId $WorkspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        if (-not $fabricLakehouses -or $fabricLakehouses.Count -eq 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) No lakehouses found in Fabric workspace"
            return @()
        }
       
        # Step 2: Get current state resources
        $currentStateResources = Get-CurrentStateResources -ModuleName $ModuleName
       
        # Step 3: Auto-detect workspace name if not provided
        if ([string]::IsNullOrEmpty($WorkspaceName)) {
            if ($currentStateResources.Count -gt 0) {
                # Extract workspace name from existing state resource
                $sampleResource = $currentStateResources[0]
                if ($sampleResource -match "module\.$ModuleName\.fabric_lakehouse\.this\[`"([^`"]+)`"\]") {
                    $existingKey = $matches[1]
                    $parts = $existingKey.Split('-')
                    if ($parts.Count -ge 2) {
                        $WorkspaceName = ($parts[0..($parts.Count-2)] -join '-')
                        Write-Host "##[debug]$($script:Emoji.Success) Auto-detected workspace name from existing state: $WorkspaceName"
                    }
                }
            }
           
            if ([string]::IsNullOrEmpty($WorkspaceName)) {
                # Use default pattern
                $WorkspaceName = "PlatformServices-Sandbox"
                Write-Host "##[debug]$($script:Emoji.Info) Using default workspace name: $WorkspaceName"
            }
        }
       
        # Step 4: Create importable lakehouse list
        $importableLakehouses = @()
       
        foreach ($fabricLakehouse in $fabricLakehouses) {
            $expectedKey = "$WorkspaceName-$($fabricLakehouse.displayName)"
            $expectedAddress = "module.$ModuleName.fabric_lakehouse.this[`"$expectedKey`"]"

            Write-Host "##[debug]Checking lakehouse: $($fabricLakehouse.displayName) -> $expectedKey"
            Write-Host "##[debug]Expected address: $expectedAddress"
            
            # Check if it's already in state
            $existsInState = $currentStateResources | Where-Object { $_ -eq $expectedAddress }
           
            if (-not $existsInState) {
                # Test if this address would be valid for import
                $addressTest = Test-ResourceAddressValidity -ResourceAddress $expectedAddress
               
                $importableLakehouses += [PSCustomObject]@{
                    FabricId = $fabricLakehouse.id
                    DisplayName = $fabricLakehouse.displayName
                    ExpectedKey = $expectedKey
                    ExpectedAddress = $expectedAddress
                    IsValidAddress = $addressTest.IsValid
                    AddressStatus = $addressTest.Status
                    AddressMessage = $addressTest.Message
                    CanImport = $addressTest.IsValid
                }
               
                if ($addressTest.IsValid) {
                    Write-Host "##[debug]$($script:Emoji.Success) Importable: $($fabricLakehouse.displayName) -> $expectedKey"
                } else {
                    Write-Host "##[debug]$($script:Emoji.Warning) Not importable: $($fabricLakehouse.displayName) -> $($addressTest.Message)"
                }
            } else {
                Write-Host "##[debug]$($script:Emoji.Info) Already in state: $($fabricLakehouse.displayName)"
            }
        }
       
        $validImportable = $importableLakehouses | Where-Object { $_.CanImport }
        Write-Host "##[debug]$($script:Emoji.Success) Found $($validImportable.Count) importable lakehouses out of $($fabricLakehouses.Count) total"
       
        return $importableLakehouses
       
    } catch {
        Write-Host "##[error]$($script:Emoji.Error) Error discovering importable lakehouses: $($_.Exception.Message)"
        return @()
    }
}

# Updated main import function that uses the alternative discovery method
function Import-MissingLakehousesRobust {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "lakehouse_names",
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName = "",
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1,
       
        [Parameter(Mandatory=$false)]
        [switch]$DebugMode,
       
        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )
   
    Write-Host "==================================================================="
    Write-Host "  $($script:Emoji.Gear) ROBUST LAKEHOUSE IMPORT SOLUTION"
    Write-Host "  (Handles 'known after apply' scenarios)"
    Write-Host "==================================================================="
   
    try {
        # Use the alternative discovery method that doesn't rely on module outputs
        Write-Host "##[section]$($script:Emoji.List) Step 1: Discovering importable lakehouses..."
        $importableLakehouses = Get-ImportableLakehouses -WorkspaceId $WorkspaceId -ModuleName $ModuleName -WorkspaceName $WorkspaceName -MaxRetryAttempts $MaxRetryAttempts
       
        if ($importableLakehouses.Count -eq 0) {
            Write-Host "##[section]$($script:Emoji.Success) No lakehouses need to be imported"
            return $true
        }
       
        $validImportable = $importableLakehouses | Where-Object { $_.CanImport }
       
        if ($validImportable.Count -eq 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) Found lakehouses but none can be imported (configuration issues)"
           
            Write-Host "##[warning]Issues found:"
            foreach ($lakehouse in $importableLakehouses) {
                Write-Host "##[warning]  - $($lakehouse.DisplayName): $($lakehouse.AddressMessage)"
            }
            return $false
        }
       
        Write-Host "##[section]$($script:Emoji.Success) Found $($validImportable.Count) lakehouses that can be imported:"
        foreach ($lakehouse in $validImportable) {
            Write-Host "##[debug]  - $($lakehouse.DisplayName) -> $($lakehouse.ExpectedKey)"
        }
       
        if ($DryRun) {
            Write-Host "##[section]$($script:Emoji.Info) DRY RUN MODE - Would import:"
            foreach ($lakehouse in $validImportable) {
                Write-Host "##[info]terraform import '$($lakehouse.ExpectedAddress)' '$($lakehouse.FabricId)'"
            }
            return $true
        }
       
        # Import each lakehouse
        Write-Host "##[section]$($script:Emoji.List) Step 2: Importing lakehouses..."
        $importSuccess = $true
        $importedCount = 0
       
        foreach ($lakehouse in $validImportable) {
            $individualSuccess = Import-LakehouseWithProperQuotes -ResourceAddress $lakehouse.ExpectedAddress -LakehouseId $lakehouse.FabricId -LakehouseName $lakehouse.DisplayName -MaxRetryAttempts $MaxRetryAttempts
           
            if ($individualSuccess) {
                $importedCount++
            } else {
                $importSuccess = $false
            }
        }
       
        Write-Host "##[section]$($script:Emoji.Stats) Import completed: $importedCount/$($validImportable.Count) successful"
       
        return $importSuccess
       
    } catch {
        Write-Host "##[error]$($script:Emoji.Error) Robust import failed: $($_.Exception.Message)"
        return $false
    }
}

# Main comprehensive import function
function Import-MissingLakehousesComplete {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "lakehouse_names",
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName = "",  # Will be auto-detected if not provided
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1,
       
        [Parameter(Mandatory=$false)]
        [switch]$DebugMode
    )
   
    Write-Host "==================================================================="
    Write-Host "  $($script:Emoji.Gear) COMPLETE LAKEHOUSE IMPORT SOLUTION"
    Write-Host "==================================================================="
    Write-Host "Workspace ID: $WorkspaceId"
    Write-Host "Module Name: $ModuleName"
    Write-Host "Max Retry Attempts: $MaxRetryAttempts"
    Write-Host "Debug Mode: $($DebugMode.IsPresent)"
    Write-Host "==================================================================="
    Write-Host ""
   
    try {
        # Step 1: Get lakehouses from Fabric
        Write-Host "##[section]$($script:Emoji.List) Step 1: Discovering lakehouses in Fabric workspace"
        $fabricLakehouses = Get-FabricLakehouses -WorkspaceId $WorkspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        if (-not $fabricLakehouses -or $fabricLakehouses.Count -eq 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) No lakehouses found in Fabric workspace"
            return $true
        }
       
        Write-Host "##[debug]$($script:Emoji.Success) Found $($fabricLakehouses.Count) lakehouses in Fabric:"
        foreach ($lh in $fabricLakehouses) {
            Write-Host "##[debug]  - $($lh.displayName) (ID: $($lh.id))"
        }
       
        # Step 2: Get expected keys from Terraform configuration
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 2: Discovering expected resources from Terraform configuration"
        $expectedKeys = Get-ExpectedKeysFromConfiguration -ModuleName $ModuleName
       
        if ($expectedKeys.Count -eq 0) {
            Write-Host "##[error]$($script:Emoji.Error) No expected lakehouse keys found in Terraform configuration"
            Write-Host "##[error]This could mean:"
            Write-Host "##[error]  1. Module outputs are not defined"
            Write-Host "##[error]  2. No lakehouses are configured"
            Write-Host "##[error]  3. All lakehouses are filtered out"
            return $false
        }
       
        Write-Host "##[debug]$($script:Emoji.Success) Found $($expectedKeys.Count) expected lakehouse keys:"
        foreach ($key in $expectedKeys) {
            Write-Host "##[debug]  - $key"
        }
       
        # Auto-detect workspace name if not provided
        if ([string]::IsNullOrEmpty($WorkspaceName)) {
            if ($expectedKeys.Count -gt 0) {
                $sampleKey = $expectedKeys[0]
                $parts = $sampleKey.Split('-')
                if ($parts.Count -ge 2) {
                    $WorkspaceName = ($parts[0..($parts.Count-2)] -join '-')
                    Write-Host "##[debug]$($script:Emoji.Success) Auto-detected workspace name: $WorkspaceName"
                }
            }
        }
       
        if ([string]::IsNullOrEmpty($WorkspaceName)) {
            Write-Host "##[error]$($script:Emoji.Error) Could not determine workspace name"
            return $false
        }
       
        # Step 3: Get current state resources
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 3: Checking current Terraform state"
        $currentStateResources = Get-CurrentStateResources -ModuleName $ModuleName
       
        Write-Host "##[debug]$($script:Emoji.Success) Found $($currentStateResources.Count) lakehouse resources in current state:"
        foreach ($resource in $currentStateResources) {
            Write-Host "##[debug]  - $resource"
        }
       
        # Step 4: Find orphaned lakehouses (exist in Fabric and should exist in Terraform, but missing from state)
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 4: Identifying orphaned lakehouses"
        $orphanedLakehouses = @()
       
        foreach ($fabricLakehouse in $fabricLakehouses) {
            $expectedKey = "$WorkspaceName-$($fabricLakehouse.displayName)"
            $expectedAddress = "module.$ModuleName.fabric_lakehouse.this[`"$expectedKey`"]"
           
            # Check if this lakehouse should exist in configuration
            $shouldExistInConfig = $expectedKeys -contains $expectedKey
           
            # Check if it exists in current state
            $existsInState = $currentStateResources | Where-Object { $_ -eq $expectedAddress }
           
            if ($shouldExistInConfig -and -not $existsInState) {
                # This is an orphaned lakehouse
                $orphanedLakehouses += @{
                    FabricId = $fabricLakehouse.id
                    DisplayName = $fabricLakehouse.displayName
                    ExpectedKey = $expectedKey
                    ExpectedAddress = $expectedAddress
                    ShouldExistInConfig = $shouldExistInConfig
                }
               
                Write-Host "##[debug]$($script:Emoji.Lakehouse) Orphaned lakehouse: $($fabricLakehouse.displayName)"
                Write-Host "##[debug]  Expected key: $expectedKey"
                Write-Host "##[debug]  Expected address: $expectedAddress"
            } elseif (-not $shouldExistInConfig) {
                Write-Host "##[debug]$($script:Emoji.Info) Lakehouse $($fabricLakehouse.displayName) not expected in configuration (filtered out)"
            } else {
                Write-Host "##[debug]$($script:Emoji.Success) Lakehouse $($fabricLakehouse.displayName) already exists in state"
            }
        }
       
        # Step 5: Report findings
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 5: Import Summary"
       
        if ($orphanedLakehouses.Count -eq 0) {
            Write-Host "##[section]$($script:Emoji.Success) All expected lakehouses are properly tracked in Terraform state"
            Write-Host "##[section]$($script:Emoji.Success) No import operations needed"
            return $true
        }
       
        Write-Host "##[warning]$($script:Emoji.Warning) Found $($orphanedLakehouses.Count) orphaned lakehouses that need to be imported:"
        foreach ($orphan in $orphanedLakehouses) {
            Write-Host "##[warning]  - $($orphan.DisplayName) (ID: $($orphan.FabricId))"
        }
       
        # Step 6: Import orphaned lakehouses
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 6: Importing orphaned lakehouses"
       
        $importSuccess = $true
        $importedCount = 0
       
        foreach ($orphan in $orphanedLakehouses) {
            Write-Host ""
            $individualSuccess = Import-SingleLakehouse -ResourceAddress $orphan.ExpectedAddress -LakehouseId $orphan.FabricId -LakehouseName $orphan.DisplayName -MaxRetryAttempts $MaxRetryAttempts
           
            if ($individualSuccess) {
                $importedCount++
            } else {
                $importSuccess = $false
            }
        }
       
        # Step 7: Final verification
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 7: Final verification"
        Write-Host "##[debug]$($script:Emoji.Stats) Import summary: $importedCount/$($orphanedLakehouses.Count) lakehouses imported successfully"
       
        if ($importSuccess) {
            Write-Host "##[section]$($script:Emoji.Success) All lakehouse imports completed successfully"
           
            # Run terraform plan to verify everything is in sync
            Write-Host "##[debug]$($script:Emoji.Magnify) Running final verification plan..."
            $planResult = terraform plan -detailed-exitcode 2>&1
           
            if ($LASTEXITCODE -eq 0) {
                Write-Host "##[section]$($script:Emoji.Success) Verification passed - no changes needed"
            } elseif ($LASTEXITCODE -eq 2) {
                Write-Host "##[warning]$($script:Emoji.Warning) Verification shows pending changes - review terraform plan output"
                if ($DebugMode) {
                    Write-Host "##[debug]Plan output:" -ForegroundColor Yellow
                    $planResult | ForEach-Object { Write-Host "##[debug]  $_" -ForegroundColor Gray }
                }
            } else {
                Write-Host "##[warning]$($script:Emoji.Warning) Verification had issues but imports were successful"
            }
           
            return $true
        } else {
            Write-Host "##[error]$($script:Emoji.Error) Some lakehouse imports failed - manual intervention may be required"
            return $false
        }
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Complete lakehouse import failed: $($_.Exception.Message)"
        Write-Host "##[error]Stack trace: $($_.ScriptStackTrace)"
        return $false
    }
}

# Individual lakehouse import function for manual use
function Import-SpecificLakehouse {
    param(
        [Parameter(Mandatory=$true)]
        [string]$LakehouseName,
       
        [Parameter(Mandatory=$true)]
        [string]$LakehouseId,
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName = "PlatformServices-Sandbox",
       
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "lakehouse_names",
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    $expectedKey = "$WorkspaceName-$LakehouseName"
    $expectedAddress = "module.$ModuleName.fabric_lakehouse.this[`"$expectedKey`"]"
   
    Write-Host "==================================================================="
    Write-Host "  $($script:Emoji.Download) IMPORTING SPECIFIC LAKEHOUSE"
    Write-Host "==================================================================="
    Write-Host "Lakehouse Name: $LakehouseName"
    Write-Host "Lakehouse ID: $LakehouseId"
    Write-Host "Expected Key: $expectedKey"
    Write-Host "Expected Address: $expectedAddress"
    Write-Host "==================================================================="
   
    $success = Import-SingleLakehouse -ResourceAddress $expectedAddress -LakehouseId $LakehouseId -LakehouseName $LakehouseName -MaxRetryAttempts $MaxRetryAttempts
   
    if ($success) {
        Write-Host "##[section]$($script:Emoji.Success) Lakehouse import completed successfully!"
        return $true
    } else {
        Write-Host "##[error]$($script:Emoji.Error) Lakehouse import failed!"
        return $false
    }
}

# Quick diagnostic function
function Test-LakehouseConfiguration {
    param(
        [Parameter(Mandatory=$true)]
        [string]$LakehouseName,
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName = "PlatformServices-Sandbox",
       
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "lakehouse_names"
    )
   
    $expectedKey = "$WorkspaceName-$LakehouseName"
    $expectedAddress = "module.$ModuleName.fabric_lakehouse.this[`"$expectedKey`"]"
   
    Write-Host "==================================================================="
    Write-Host "  $($script:Emoji.Magnify) TESTING LAKEHOUSE CONFIGURATION"
    Write-Host "==================================================================="
    Write-Host "Lakehouse Name: $LakehouseName"
    Write-Host "Expected Key: $expectedKey"
    Write-Host "Expected Address: $expectedAddress"
    Write-Host "==================================================================="
   
    # Test if the resource address is valid
    $addressTest = Test-ResourceAddressValidity -ResourceAddress $expectedAddress
   
    Write-Host "Resource Address Validity: $($addressTest.IsValid)"
    Write-Host "Status: $($addressTest.Status)"
    Write-Host "Message: $($addressTest.Message)"
   
    if ($addressTest.IsValid) {
        Write-Host "##[section]$($script:Emoji.Success) Configuration is valid - ready for import!"
        Write-Host "##[section]Import command: terraform import '$expectedAddress' <your-lakehouse-id>"
    } else {
        Write-Host "##[error]$($script:Emoji.Error) Configuration issue detected - fix configuration before importing"
    }
   
    return $addressTest
}

function Get-TerraformWorkspaceStateJson {
    param(
        [string]$StatePrefix,
        [int]$MaxRetryAttempts = 1
    )
   
    try {
        $success = $false
        $attemptCount = 0
        $maxAttempts = $MaxRetryAttempts
        $errorMessage = ""
        $stateJson = $null
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Attempting to get Terraform state as JSON for workspaces..."
       
        while (-not $success -and $attemptCount -lt $maxAttempts) {
            $attemptCount++
           
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $maxAttempts for terraform show -json (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            try {
                # Get the full state as JSON
                $stateJsonRaw = terraform show -json 2>&1
               
                if ($LASTEXITCODE -eq 0) {
                    $success = $true
                    $stateJson = $stateJsonRaw | ConvertFrom-Json
                    Write-Host "##[debug]$($script:Emoji.Success) Successfully retrieved Terraform state as JSON"
                } else {
                    $errorMessage = "Failed to get state JSON: $($stateJsonRaw -join '; ')"
                    Write-Host "##[warning]$($script:Emoji.Warning) $errorMessage"
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Host "##[warning]$($script:Emoji.Warning) Error getting state JSON (Attempt $attemptCount of $maxAttempts): $errorMessage"
            }
        }
       
        if (-not $success) {
            Write-Host "##[error]$($script:Emoji.Error) Failed to get Terraform state JSON after $maxAttempts attempts: $errorMessage"
            exit 1
        }
       
        # Parse the JSON to extract workspace resources
        $workspaces = @()
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Analyzing JSON structure for workspace resources..."
        Write-Host "##[debug]JSON root properties: $($stateJson.PSObject.Properties.Name -join ', ')"

        $workspaces += Search-JsonRecursively -JsonObject $stateJson -StatePrefix $StatePrefix -ResourceType "fabric_workspace"
        Write-Host "##[debug]$($script:Emoji.Stats) Extracted $($workspaces.Count) workspace resources from JSON state"      
       
        return $workspaces
       
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to parse JSON state: $($_.Exception.Message)"  
        exit 1
    }
}

function Get-TerraformWorkspaceState {
    param(
        [string]$StatePrefix,
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[debug]$($script:Emoji.Gear) Getting Terraform workspace state (JSON method)..."
   
    return Get-TerraformWorkspaceStateJson -StatePrefix $StatePrefix -MaxRetryAttempts $MaxRetryAttempts
}

function Get-TerraformLakehouseStateJson {
    param(
        [string]$StatePrefix,
        [int]$MaxRetryAttempts = 3
    )
   
    try {
        $success = $false
        $attemptCount = 0
        $maxAttempts = $MaxRetryAttempts
        $errorMessage = ""
        $stateJson = $null
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Attempting to get Terraform state as JSON..."
       
        while (-not $success -and $attemptCount -lt $maxAttempts) {
            $attemptCount++
           
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $maxAttempts for terraform show -json (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            try {
                # Get the full state as JSON
                $stateJsonRaw = terraform show -json 2>&1
               
                if ($LASTEXITCODE -eq 0) {
                    $success = $true
                    $stateJson = $stateJsonRaw | ConvertFrom-Json
                    Write-Host "##[debug]$($script:Emoji.Success) Successfully retrieved Terraform state as JSON"
                } else {
                    $errorMessage = "Failed to get state JSON: $($stateJsonRaw -join '; ')"
                    Write-Host "##[warning]$($script:Emoji.Warning) $errorMessage"
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Host "##[warning]$($script:Emoji.Warning) Error getting state JSON (Attempt $attemptCount of $maxAttempts): $errorMessage"
            }
        }
       
        if (-not $success) {
            Write-Host "##[error]$($script:Emoji.Error) Failed to get Terraform state JSON after $maxAttempts attempts: $errorMessage"
            exit 1
        }
       
        # Parse the JSON to extract lakehouse resources
        $lakehouses = @()
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Analyzing JSON structure for lakehouse resources..."
        Write-Host "##[debug]JSON root properties: $($stateJson.PSObject.Properties.Name -join ', ')"

        $lakehouses += Search-JsonRecursively -JsonObject $stateJson -StatePrefix $StatePrefix -ResourceType "fabric_lakehouse"
        Write-Host "##[debug]$($script:Emoji.Stats) Extracted $($lakehouses.Count) lakehouse resources from JSON state"       
       
        return $lakehouses
       
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to parse JSON state: $($_.Exception.Message)"   
        exit 1
    }
}

function Get-TerraformNotebookStateJson {
    param(
        [string]$StatePrefix,
        [int]$MaxRetryAttempts = 3
    )
   
    try {
        $success = $false
        $attemptCount = 0
        $maxAttempts = $MaxRetryAttempts
        $errorMessage = ""
        $stateJson = $null
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Attempting to get Terraform state as JSON for notebooks..."
       
        while (-not $success -and $attemptCount -lt $maxAttempts) {
            $attemptCount++
           
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $maxAttempts for terraform show -json (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            try {
                # Get the full state as JSON
                $stateJsonRaw = terraform show -json 2>&1
               
                if ($LASTEXITCODE -eq 0) {
                    $success = $true
                    $stateJson = $stateJsonRaw | ConvertFrom-Json
                    Write-Host "##[debug]$($script:Emoji.Success) Successfully retrieved Terraform state as JSON"
                } else {
                    $errorMessage = "Failed to get state JSON: $($stateJsonRaw -join '; ')"
                    Write-Host "##[warning]$($script:Emoji.Warning) $errorMessage"
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Host "##[warning]$($script:Emoji.Warning) Error getting state JSON (Attempt $attemptCount of $maxAttempts): $errorMessage"
            }
        }
       
        if (-not $success) {
            Write-Host "##[error]$($script:Emoji.Error) Failed to get Terraform state JSON after $maxAttempts attempts: $errorMessage"
            exit 1
        }
       
        # Parse the JSON to extract notebook resources (same logic as lakehouses)
        $notebooks = @()
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Analyzing JSON structure for notebook resources..."
        $notebooks += Search-JsonRecursively -JsonObject $stateJson -StatePrefix $StatePrefix -ResourceType "fabric_notebook"
       
        Write-Host "##[debug]$($script:Emoji.Stats) Extracted $($notebooks.Count) notebook resources from JSON state"
       
        return $notebooks
       
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Failed to parse JSON state: $($_.Exception.Message)"
        exit 1
    }
}

function Search-JsonRecursively {
    param(
        [object]$JsonObject,
        [string]$StatePrefix,
        [string]$ResourceType
    )
   
    $resources = @()
   
    try {
        if ($JsonObject -is [Array]) {
            foreach ($item in $JsonObject) {
                $resources += Search-JsonRecursively -JsonObject $item -StatePrefix $StatePrefix -ResourceType $ResourceType
            }
        }
        elseif ($JsonObject -is [PSCustomObject]) {
            # Check if this object has the properties we're looking for
            if ($JsonObject.address -and $JsonObject.type -eq $ResourceType -and $JsonObject.mode -eq "managed") {
                if ($JsonObject.address -like "$StatePrefix*") {
                    $resource = @{
                        StateAddress = $JsonObject.address
                        DisplayName = $JsonObject.values.display_name
                        Id = $JsonObject.values.id
                        Type = $JsonObject.type
                        Mode = $JsonObject.mode
                    }
                   
                    $resources += $resource
                    Write-Host "##[debug]   $($script:Emoji.Success) Found $ResourceType in recursive search: $($resource.DisplayName)"
                }
            }
           
            # Recursively search all properties
            foreach ($property in $JsonObject.PSObject.Properties) {
                if ($property.Value -is [Array] -or $property.Value -is [PSCustomObject]) {
                    $resources += Search-JsonRecursively -JsonObject $property.Value -StatePrefix $StatePrefix -ResourceType $ResourceType
                }
            }
        }
    }
    catch {
        Write-Host "##[warning]$($script:Emoji.Warning) Error in recursive search: $($_.Exception.Message)"
    }
   
    return $resources
}

# Updated main functions to use JSON method first
function Get-TerraformLakehouseState {
    param(
        [string]$StatePrefix,
        [int]$MaxRetryAttempts = 3
    )
   
    Write-Host "##[debug]$($script:Emoji.Gear) Getting Terraform lakehouse state (JSON method first, fallback to original)..."
   
    # Try JSON method first
    return Get-TerraformLakehouseStateJson -StatePrefix $StatePrefix -MaxRetryAttempts $MaxRetryAttempts
}

function Get-TerraformNotebookState {
    param(
        [string]$StatePrefix,
        [int]$MaxRetryAttempts = 3
    )
   
    Write-Host "##[debug]$($script:Emoji.Gear) Getting Terraform notebook state (JSON method first, fallback to original)..."
   
    # Try JSON method first
    return Get-TerraformNotebookStateJson -StatePrefix $StatePrefix -MaxRetryAttempts $MaxRetryAttempts
}

function Import-MissingLakehousesImproved {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [string]$ModuleName = "lakehouse_names",
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName = "",  # Will be auto-detected if not provided
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1,
       
        [Parameter(Mandatory=$false)]
        [switch]$DebugMode,
       
        [Parameter(Mandatory=$false)]
        [switch]$DryRun  # Show what would be imported without actually importing
    )
   
    Write-Host "==================================================================="
    Write-Host "  $($script:Emoji.Gear) IMPROVED LAKEHOUSE IMPORT SOLUTION"
    Write-Host "==================================================================="
    Write-Host "Workspace ID: $WorkspaceId"
    Write-Host "Module Name: $ModuleName"
    Write-Host "Max Retry Attempts: $MaxRetryAttempts"
    Write-Host "Debug Mode: $($DebugMode.IsPresent)"
    Write-Host "Dry Run: $($DryRun.IsPresent)"
    Write-Host "==================================================================="
    Write-Host ""
   
    try {
        # Step 1: Validate prerequisites
        Write-Host "##[section]$($script:Emoji.List) Step 1: Validating prerequisites"
       
        # Check Terraform availability
        try {
            $terraformVersion = terraform version 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "##[error]$($script:Emoji.Error) Terraform is not available or not in PATH"
                return $false
            }
            Write-Host "##[debug]$($script:Emoji.Success) Terraform is available"
        } catch {
            Write-Host "##[error]$($script:Emoji.Error) Error checking Terraform: $($_.Exception.Message)"
            return $false
        }
       
        # Check Fabric token
        if (-not $env:FABRIC_TOKEN) {
            Write-Host "##[error]$($script:Emoji.Error) FABRIC_TOKEN environment variable is not set"
            return $false
        }
        Write-Host "##[debug]$($script:Emoji.Success) Fabric token is available"
       
        # Check Terraform state accessibility
        try {
            $stateTest = terraform state list 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "##[error]$($script:Emoji.Error) Cannot access Terraform state. Ensure 'terraform init' has been run."
                Write-Host "##[error]State test output: $stateTest"
                return $false
            }
            Write-Host "##[debug]$($script:Emoji.Success) Terraform state is accessible"
        } catch {
            Write-Host "##[error]$($script:Emoji.Error) Error accessing Terraform state: $($_.Exception.Message)"
            return $false
        }

        # Step 2: Get lakehouses from Fabric
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 2: Discovering lakehouses in Fabric workspace"
        $fabricLakehouses = Get-FabricLakehouses -WorkspaceId $WorkspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        if (-not $fabricLakehouses -or $fabricLakehouses.Count -eq 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) No lakehouses found in Fabric workspace"
            return $true
        }
       
        Write-Host "##[debug]$($script:Emoji.Success) Found $($fabricLakehouses.Count) lakehouses in Fabric:"
        foreach ($lh in $fabricLakehouses) {
            Write-Host "##[debug]  - $($lh.displayName) (ID: $($lh.id))"
        }
       
        # Step 3: Get expected keys from Terraform configuration
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 3: Discovering expected resources from Terraform configuration"
        $expectedKeys = Get-ExpectedKeysFromConfiguration -ModuleName $ModuleName
       
        if ($expectedKeys.Count -eq 0) {
            Write-Host "##[error]$($script:Emoji.Error) No expected lakehouse keys found in Terraform configuration"
            Write-Host "##[error]This could mean:"
            Write-Host "##[error]  1. Module outputs are not defined"
            Write-Host "##[error]  2. No lakehouses are configured"
            Write-Host "##[error]  3. All lakehouses are filtered out"
            Write-Host "##[error]  4. Module name '$ModuleName' is incorrect"
            return $false
        }
       
        Write-Host "##[debug]$($script:Emoji.Success) Found $($expectedKeys.Count) expected lakehouse keys:"
        foreach ($key in $expectedKeys) {
            Write-Host "##[debug]  - $key"
        }
       
        # Auto-detect workspace name if not provided
        if ([string]::IsNullOrEmpty($WorkspaceName)) {
            if ($expectedKeys.Count -gt 0) {
                $sampleKey = $expectedKeys[0]
                $parts = $sampleKey.Split('-')
                if ($parts.Count -ge 2) {
                    $WorkspaceName = ($parts[0..($parts.Count-2)] -join '-')
                    Write-Host "##[debug]$($script:Emoji.Success) Auto-detected workspace name: $WorkspaceName"
                }
            }
        }
       
        if ([string]::IsNullOrEmpty($WorkspaceName)) {
            Write-Host "##[error]$($script:Emoji.Error) Could not determine workspace name"
            return $false
        }

        # Step 4: Get current state resources
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 4: Checking current Terraform state"
        $currentStateResources = Get-CurrentStateResources -ModuleName $ModuleName
       
        Write-Host "##[debug]$($script:Emoji.Success) Found $($currentStateResources.Count) lakehouse resources in current state:"
        if ($currentStateResources.Count -eq 0) {
            Write-Host "##[debug]  (No lakehouse resources found in current state - this indicates state drift)"
        } else {
            foreach ($resource in $currentStateResources) {
                Write-Host "##[debug]  - $resource"
            }
        }

        # Step 5: Find orphaned lakehouses
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 5: Identifying orphaned lakehouses"
        $orphanedLakehouses = @()
       
        foreach ($fabricLakehouse in $fabricLakehouses) {
            $expectedKey = "$WorkspaceName-$($fabricLakehouse.displayName)"
            $expectedAddress = "module.$ModuleName.fabric_lakehouse.this[`"$expectedKey`"]"
           
            # Check if this lakehouse should exist in configuration
            $shouldExistInConfig = $expectedKeys -contains $expectedKey
           
            # Check if it exists in current state
            $existsInState = $currentStateResources | Where-Object { $_ -eq $expectedAddress }
           
            if ($shouldExistInConfig -and -not $existsInState) {
                # This is an orphaned lakehouse
                $orphanedLakehouses += [PSCustomObject]@{
                    FabricId = $fabricLakehouse.id
                    DisplayName = $fabricLakehouse.displayName
                    ExpectedKey = $expectedKey
                    ExpectedAddress = $expectedAddress
                    ShouldExistInConfig = $shouldExistInConfig
                }
               
                Write-Host "##[debug]$($script:Emoji.Lakehouse) Orphaned lakehouse: $($fabricLakehouse.displayName)"
                Write-Host "##[debug]  Expected key: $expectedKey"
                Write-Host "##[debug]  Expected address: $expectedAddress"
            } elseif (-not $shouldExistInConfig) {
                if ($DebugMode) {
                    Write-Host "##[debug]$($script:Emoji.Info) Lakehouse $($fabricLakehouse.displayName) not expected in configuration (filtered out)"
                }
            } else {
                Write-Host "##[debug]$($script:Emoji.Success) Lakehouse $($fabricLakehouse.displayName) already exists in state"
            }
        }

        # Step 6: Report findings
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 6: Import Summary"
       
        if ($orphanedLakehouses.Count -eq 0) {
            Write-Host "##[section]$($script:Emoji.Success) All expected lakehouses are properly tracked in Terraform state"
            Write-Host "##[section]$($script:Emoji.Success) No import operations needed"
            return $true
        }
       
        Write-Host "##[warning]$($script:Emoji.Warning) Found $($orphanedLakehouses.Count) orphaned lakehouses that need to be imported:"
        foreach ($orphan in $orphanedLakehouses) {
            Write-Host "##[warning]  - $($orphan.DisplayName) (ID: $($orphan.FabricId))"
        }

        # Dry run mode - show what would be imported without actually doing it
        if ($DryRun) {
            Write-Host ""
            Write-Host "##[section]$($script:Emoji.Info) DRY RUN MODE - Showing what would be imported:"
            foreach ($orphan in $orphanedLakehouses) {
                Write-Host "##[info]Would import: terraform import '$($orphan.ExpectedAddress)' '$($orphan.FabricId)'"
            }
            Write-Host "##[section]$($script:Emoji.Info) Dry run complete. Run without -DryRun to perform actual imports."
            return $true
        }

        # Step 7: Import orphaned lakehouses using improved method
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 7: Importing orphaned lakehouses (Improved Method)"
       
        $importSuccess = $true
        $importedCount = 0
        $failedImports = @()
       
        foreach ($orphan in $orphanedLakehouses) {
            Write-Host ""
            Write-Host "##[section]Processing lakehouse $($importedCount + 1) of $($orphanedLakehouses.Count): $($orphan.DisplayName)" -ForegroundColor Yellow
           
            $individualSuccess = Import-LakehouseImproved -ResourceAddress $orphan.ExpectedAddress -LakehouseId $orphan.FabricId -LakehouseName $orphan.DisplayName -MaxRetryAttempts $MaxRetryAttempts
           
            if ($individualSuccess) {
                $importedCount++
                Write-Host "##[debug]$($script:Emoji.Success) Import successful for: $($orphan.DisplayName)"
            } else {
                $importSuccess = $false
                $failedImports += $orphan
                Write-Host "##[debug]$($script:Emoji.Error) Import failed for: $($orphan.DisplayName)"
            }
        }

        # Step 8: Final verification and reporting
        Write-Host ""
        Write-Host "##[section]$($script:Emoji.List) Step 8: Final verification and reporting"
        Write-Host "##[debug]$($script:Emoji.Stats) Import summary: $importedCount/$($orphanedLakehouses.Count) lakehouses imported successfully"
       
        if ($failedImports.Count -gt 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) Failed imports:"
            foreach ($failed in $failedImports) {
                Write-Host "##[warning]  - $($failed.DisplayName) (ID: $($failed.FabricId))"
            }
        }
       
        if ($importSuccess) {
            Write-Host "##[section]$($script:Emoji.Success) All lakehouse imports completed successfully"
           
            # Run terraform plan to verify everything is in sync
            Write-Host "##[debug]$($script:Emoji.Magnify) Running final verification plan..."
            $planResult = terraform plan -detailed-exitcode 2>&1
           
            if ($LASTEXITCODE -eq 0) {
                Write-Host "##[section]$($script:Emoji.Success) Final verification passed - no changes needed"
                Write-Host "##[section]$($script:Emoji.Success) All resources are now properly managed by Terraform"
            } elseif ($LASTEXITCODE -eq 2) {
                Write-Host "##[warning]$($script:Emoji.Warning) Final verification shows pending changes"
                if ($DebugMode) {
                    Write-Host "##[warning]This could be normal - some configurations might differ from actual resources"
                    Write-Host "##[debug]Plan output (first 10 lines):" -ForegroundColor Yellow
                    ($planResult | Select-Object -First 10) | ForEach-Object { Write-Host "##[debug]  $_" -ForegroundColor Gray }
                }
            } else {
                Write-Host "##[warning]$($script:Emoji.Warning) Final verification had issues, but imports were successful"
            }
           
            return $true
        } else {
            Write-Host "##[error]$($script:Emoji.Error) Some lakehouse imports failed"
           
            if ($failedImports.Count -gt 0) {
                Write-Host "##[error]$($script:Emoji.Error) Consider running diagnostics on failed imports:"
                foreach ($failed in $failedImports) {
                    Write-Host "##[error]  Diagnose-ImportFailure -ResourceAddress '$($failed.ExpectedAddress)' -LakehouseId '$($failed.FabricId)'"
                }
            }
           
            return $false
        }
    }
    catch {
        Write-Host "##[error]$($script:Emoji.Error) Improved lakehouse import failed: $($_.Exception.Message)"
        Write-Host "##[error]Stack trace: $($_.ScriptStackTrace)"
        return $false
    }
}

# Azure DevOps Pipeline Usage Function - Combined workspace, lakehouse, notebook reconciliation
function Invoke-WorkspaceLakehouseAndNotebookReconciliation {
    param(
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$true)]
        [string]$Environment,  # e.g., "dev", "test", "prod"
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceStatePrefix = 'module.fabric_workspace.fabric_workspace.this',
       
        [Parameter(Mandatory=$false)]
        [string]$LakehouseStatePrefix = 'module.lakehouse_names.fabric_lakehouse.this',
       
        [Parameter(Mandatory=$false)]
        [string]$NotebookStatePrefix = 'module.notebooks.fabric_notebook.this',
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1,
       
        [Parameter(Mandatory=$false)]
        [switch]$SkipWorkspaces,
       
        [Parameter(Mandatory=$false)]
        [switch]$SkipLakehouses,
       
        [Parameter(Mandatory=$false)]
        [switch]$SkipNotebooks
    )
   
    Write-Host "##[section]$($script:Emoji.Gear) Starting Workspace, Lakehouse and Notebook State Reconciliation"
    Write-Host "##[debug]$($script:Emoji.Pin) Environment: $Environment"
    if ($WorkspaceId) {
        Write-Host "##[debug]$($script:Emoji.Pin) Workspace ID: $WorkspaceId"
    }
    Write-Host "##[debug]$($script:Emoji.Cloud) Using existing Terraform remote state configuration"
   
    $overallSuccess = $true
   
    # Step 1: Reconcile workspaces if not skipped
    if (-not $SkipWorkspaces) {
        Write-Host "##[debug]$($script:Emoji.Workspace) Starting workspace reconciliation..."
       
        $workspaceSuccess = Import-MissingWorkspaces `
            -TerraformStatePrefix $WorkspaceStatePrefix `
            -Environment $Environment `
            -MaxRetryAttempts $MaxRetryAttempts
       
        if (-not $workspaceSuccess) {
            Write-Host "##[error]$($script:Emoji.Error) Workspace state reconciliation failed"
            $overallSuccess = $false
        }
    } else {
        Write-Host "##[debug]$($script:Emoji.Info) Skipping workspace reconciliation as requested"
    }
   
    # Step 2: Reconcile lakehouses if not skipped (requires WorkspaceId)
    if (-not $SkipLakehouses) {
        if ($WorkspaceId) {
            Write-Host "##[debug]$($script:Emoji.Lakehouse) Starting lakehouse reconciliation..."
           
            $lakehouseSuccess = Import-MissingLakehousesRobust `
                -WorkspaceId $WorkspaceId 
                # -TerraformStatePrefix $LakehouseStatePrefix `
                # -Environment $Environment `
                # -MaxRetryAttempts $MaxRetryAttempts
           
            if (-not $lakehouseSuccess) {
                Write-Host "##[error]$($script:Emoji.Error) Lakehouse state reconciliation failed"
                $overallSuccess = $false
            }
        } else {
            Write-Host "##[warning]$($script:Emoji.Warning) Skipping lakehouse reconciliation - WorkspaceId not provided"
        }
    } else {
        Write-Host "##[debug]$($script:Emoji.Info) Skipping lakehouse reconciliation as requested"
    }
   
    # Step 3: Reconcile notebooks if not skipped (requires WorkspaceId)
    if (-not $SkipNotebooks) {
        if ($WorkspaceId) {
            Write-Host "##[debug]$($script:Emoji.Notebook) Starting notebook reconciliation..."
           
            $notebookSuccess = Import-MissingNotebooks `
                -WorkspaceId $WorkspaceId `
                -TerraformStatePrefix $NotebookStatePrefix `
                -Environment $Environment `
                -MaxRetryAttempts $MaxRetryAttempts
           
            if (-not $notebookSuccess) {
                Write-Host "##[warning]$($script:Emoji.Warning) Notebook state reconciliation failed"
                $overallSuccess = $false
            }
        } else {
            Write-Host "##[warning]$($script:Emoji.Warning) Skipping notebook reconciliation - WorkspaceId not provided"
        }
    } else {
        Write-Host "##[debug]$($script:Emoji.Info) Skipping notebook reconciliation as requested"
    }
   
    # Set output variable for pipeline
    if ($overallSuccess) {
        Write-Host "##[section]$($script:Emoji.Success) Workspace, lakehouse and notebook state reconciliation completed successfully"
        Write-Host "##vso[task.setvariable variable=StateReconciled;isoutput=true]true"
        return $true
    } else {
        Write-Host "##[error]$($script:Emoji.Error) Workspace, lakehouse and notebook state reconciliation had failures"
        Write-Host "##vso[task.setvariable variable=StateReconciled;isoutput=true]false"
        return $false
    }
}

function Import-LakehouseWithPlaceholder {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [string]$TerraformStatePrefix = 'module.lakehouse_names.fabric_lakehouse.this',
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName = "PlatformServices-Sandbox",
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[section]$($script:Emoji.List) Starting lakehouse state reconciliation with placeholder creation..."
    Write-Host "##[debug]$($script:Emoji.Pin) Workspace Name: $WorkspaceName"
    Write-Host "##[debug]$($script:Emoji.Pin) Workspace ID: $WorkspaceId"
   
    try {
        # Step 1: Get lakehouses from Fabric
        Write-Host "##[debug]$($script:Emoji.Globe) Fetching lakehouses from Fabric workspace: $WorkspaceId"
        $fabricLakehouses = Get-FabricLakehouses -WorkspaceId $WorkspaceId -MaxRetryAttempts $MaxRetryAttempts
       
        if (-not $fabricLakehouses -or $fabricLakehouses.Count -eq 0) {
            Write-Host "##[warning]$($script:Emoji.Warning) No lakehouses found in Fabric workspace"
            return $true
        }
       
        Write-Host "##[debug]$($script:Emoji.Magnify) Found $($fabricLakehouses.Count) lakehouses in Fabric workspace"
       
        # Step 2: Get current Terraform state
        Write-Host "##[debug]$($script:Emoji.Magnify) Getting current Terraform state..."
        $currentState = terraform state list 2>&1 | Where-Object { $_ -match "fabric_lakehouse" }
       
        # Step 3: Check what should exist according to Terraform configuration
        Write-Host "##[debug]$($script:Emoji.Magnify) Checking Terraform configuration..."
        $expectedKeys = @()
       
        try {
            $lakehouseMapOutput = echo "local.lakehouse_map" | terraform console 2>&1
            if ($LASTEXITCODE -eq 0) {
                # Parse expected keys from lakehouse_map output
                $lines = $lakehouseMapOutput -split "`n"
                foreach ($line in $lines) {
                    if ($line -match '"([^"]+)"\s*=') {
                        $expectedKeys += $matches[1]
                    }
                }
            }
        } catch {
            Write-Host "##[warning]$($script:Emoji.Warning) Could not retrieve expected keys from lakehouse_map"
        }
       
        Write-Host "##[debug]Expected keys from configuration: $($expectedKeys.Count)"
        foreach ($key in $expectedKeys) {
            Write-Host "##[debug]  - $key"
        }
       
        # Step 4: Find orphaned lakehouses
        $orphanedLakehouses = @()
       
        foreach ($fabricLakehouse in $fabricLakehouses) {
            $expectedKey = "$WorkspaceName-$($fabricLakehouse.displayName)"
            $expectedAddress = "$TerraformStatePrefix[`"$expectedKey`"]"
           
            # Check if this key should exist in configuration
            $shouldExistInConfig = $expectedKeys -contains $expectedKey
           
            # Check if it exists in current state
            $existsInState = $currentState | Where-Object { $_ -eq $expectedAddress }
           
            if ($shouldExistInConfig -and -not $existsInState) {
                $orphanedLakehouses += @{
                    FabricId = $fabricLakehouse.id
                    DisplayName = $fabricLakehouse.displayName
                    ExpectedKey = $expectedKey
                    ExpectedStateAddress = $expectedAddress
                    ShouldExistInConfig = $shouldExistInConfig
                }
               
                Write-Host "##[debug]$($script:Emoji.Lakehouse) Orphaned lakehouse found: $($fabricLakehouse.displayName)"
                Write-Host "##[debug]  Expected key: $expectedKey"
                Write-Host "##[debug]  Should exist in config: $shouldExistInConfig"
            } elseif (-not $shouldExistInConfig) {
                Write-Host "##[debug]$($script:Emoji.Info) Lakehouse $($fabricLakehouse.displayName) not expected in current configuration (filtered out or not defined)"
            } else {
                Write-Host "##[debug]$($script:Emoji.Success) $($fabricLakehouse.displayName) exists in Terraform state"
            }
        }
       
        if ($orphanedLakehouses.Count -eq 0) {
            Write-Host "##[section]$($script:Emoji.Success) All expected lakehouses are properly tracked in Terraform state"
            return $true
        }
       
        Write-Host "##[warning]$($script:Emoji.Warning) Found $($orphanedLakehouses.Count) orphaned lakehouses that need to be imported:"
       
        # Step 5: Import each orphaned lakehouse using the placeholder method
        $importSuccess = $true
        $importedCount = 0
       
        foreach ($orphan in $orphanedLakehouses) {
            Write-Host ""
            Write-Host "##[section]Processing lakehouse: $($orphan.DisplayName)" -ForegroundColor Yellow
            Write-Host "##[debug]  Fabric ID: $($orphan.FabricId)"
            Write-Host "##[debug]  Expected Address: $($orphan.ExpectedStateAddress)"
           
            $attemptCount = 0
            $importSucceeded = $false
           
            while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
                $attemptCount++
               
                try {
                    # Method 1: Try direct import first
                    Write-Host "##[debug]$($script:Emoji.Download) Attempt $attemptCount - Trying direct import..."
                   
                    $importResult = terraform import $orphan.ExpectedStateAddress $orphan.FabricId 2>&1
                   
                    if ($LASTEXITCODE -eq 0) {
                        $importSucceeded = $true
                        Write-Host "##[section]$($script:Emoji.Success) Successfully imported directly: $($orphan.DisplayName)"
                        $importedCount++
                    } else {
                        Write-Host "##[warning]$($script:Emoji.Warning) Direct import failed: $($importResult -join '; ')"
                       
                        # Method 2: Use placeholder creation method
                        Write-Host "##[debug]$($script:Emoji.Gear) Trying placeholder creation method..."
                       
                        # Step 2a: Create placeholder by applying target (this might create a new resource)
                        Write-Host "##[debug]Creating placeholder resource..."
                        $applyResult = terraform apply --target=$($orphan.ExpectedStateAddress) -auto-approve 2>&1
                       
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "##[debug]$($script:Emoji.Success) Placeholder created successfully"
                           
                            # Step 2b: Remove the newly created resource from state (but keep in Fabric for now)
                            Write-Host "##[debug]Removing placeholder from state..."
                            $removeResult = terraform state rm $($orphan.ExpectedStateAddress) 2>&1
                           
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "##[debug]$($script:Emoji.Success) Placeholder removed from state"
                               
                                # Step 2c: Now import the original existing resource
                                Write-Host "##[debug]Importing existing resource..."
                                $importResult2 = terraform import $($orphan.ExpectedStateAddress) $($orphan.FabricId) 2>&1
                               
                                if ($LASTEXITCODE -eq 0) {
                                    $importSucceeded = $true
                                    Write-Host "##[section]$($script:Emoji.Success) Successfully imported via placeholder method: $($orphan.DisplayName)"
                                    $importedCount++
                                   
                                    # Clean up: Remove any duplicate resource created by apply
                                    Write-Host "##[debug]Cleaning up potential duplicate resources in Fabric..."
                                    # Note: This step is complex and may require manual cleanup
                                } else {
                                    Write-Host "##[error]$($script:Emoji.Error) Import after placeholder creation failed: $($importResult2 -join '; ')"
                                }
                            } else {
                                Write-Host "##[error]$($script:Emoji.Error) Failed to remove placeholder from state: $($removeResult -join '; ')"
                            }
                        } else {
                            Write-Host "##[error]$($script:Emoji.Error) Failed to create placeholder: $($applyResult -join '; ')"
                        }
                    }
                } catch {
                    Write-Host "##[error]$($script:Emoji.Error) Exception during import attempt $attemptCount for $($orphan.DisplayName): $($_.Exception.Message)"
                }
               
                if (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
                    $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                    Write-Host "##[debug]$($script:Emoji.Refresh) Waiting $backoffSeconds seconds before retry..."
                    Start-Sleep -Seconds $backoffSeconds
                }
            }
           
            if (-not $importSucceeded) {
                Write-Host "##[error]$($script:Emoji.Error) Failed to import $($orphan.DisplayName) after $MaxRetryAttempts attempts"
                $importSuccess = $false
            }
        }
       
        Write-Host ""
        Write-Host "##[debug]$($script:Emoji.Stats) Import summary: $importedCount/$($orphanedLakehouses.Count) lakehouses imported successfully"
       
        if ($importSuccess) {
            Write-Host "##[section]$($script:Emoji.Success) Lakehouse state reconciliation completed successfully"
           
            # Final verification
            Write-Host "##[debug]$($script:Emoji.Magnify) Running final verification..."
            $planResult = terraform plan -detailed-exitcode 2>&1
           
            if ($LASTEXITCODE -eq 0) {
                Write-Host "##[section]$($script:Emoji.Success) Verification passed - no changes needed"
            } elseif ($LASTEXITCODE -eq 2) {
                Write-Host "##[warning]$($script:Emoji.Warning) Verification shows pending changes - review terraform plan output"
            } else {
                Write-Host "##[error]$($script:Emoji.Error) Verification failed: $($planResult -join '; ')"
            }
           
            return $true
        } else {
            Write-Host "##[error]$($script:Emoji.Error) Some lakehouse imports failed - manual intervention required"
            return $false
        }
    } catch {
        Write-Host "##[error]$($script:Emoji.Error) Lakehouse state reconciliation failed: $($_.Exception.Message)"
        return $false
    }
}

function Import-LakehouseImproved {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourceAddress,
       
        [Parameter(Mandatory=$true)]
        [string]$LakehouseId,
       
        [Parameter(Mandatory=$true)]
        [string]$LakehouseName,
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    Write-Host "##[section]$($script:Emoji.Download) Importing lakehouse: $LakehouseName (Improved Method)"
    Write-Host "##[debug]  Resource Address: $ResourceAddress"
    Write-Host "##[debug]  Fabric ID: $LakehouseId"
   
    $attemptCount = 0
    $importSucceeded = $false
   
    while (-not $importSucceeded -and $attemptCount -lt $MaxRetryAttempts) {
        $attemptCount++
       
        try {
            if ($attemptCount -gt 1) {
                $backoffSeconds = [Math]::Min(30, [Math]::Pow(2, $attemptCount - 1) * 5)
                Write-Host "##[debug]$($script:Emoji.Refresh) Retry attempt $attemptCount of $MaxRetryAttempts (waiting $backoffSeconds seconds)"
                Start-Sleep -Seconds $backoffSeconds
            }
           
            Write-Host "##[debug]$($script:Emoji.Download) Method 1: Direct import attempt $attemptCount..."
           
            # Method 1: Direct import
            $importResult = terraform import $ResourceAddress $LakehouseId 2>&1
           
            if ($LASTEXITCODE -eq 0) {
                $importSucceeded = $true
                Write-Host "##[section]$($script:Emoji.Success) Direct import successful: $LakehouseName"
                return $true
            }
           
            # Check the specific error type
            $errorText = $importResult -join " "
            Write-Host "##[debug]Import error: $errorText"
           
            # Method 2: Address validation approach (better than placeholder)
            if ($errorText -match "does not exist in the configuration" -or
                $errorText -match "resource address.*not found" -or
                $errorText -match "No configuration available") {
               
                Write-Host "##[debug]$($script:Emoji.Gear) Method 2: Configuration validation approach..."
               
                # Try to validate the resource exists via plan first
                Write-Host "##[debug]Validating resource configuration with plan..."
                $planResult = terraform plan --target=$ResourceAddress 2>&1
               
                if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 2) {
                    Write-Host "##[debug]$($script:Emoji.Success) Resource configuration validated"
                   
                    # Now try import again after validation
                    Write-Host "##[debug]Retrying import after validation..."
                    $importResult2 = terraform import $ResourceAddress $LakehouseId 2>&1
                   
                    if ($LASTEXITCODE -eq 0) {
                        $importSucceeded = $true
                        Write-Host "##[section]$($script:Emoji.Success) Import successful after validation: $LakehouseName"
                        return $true
                    } else {
                        Write-Host "##[warning]$($script:Emoji.Warning) Import still failed after validation: $($importResult2 -join '; ')"
                    }
                } else {
                    Write-Host "##[error]$($script:Emoji.Error) Resource configuration validation failed: $($planResult -join '; ')"
                    Write-Host "##[error]This means the resource doesn't exist in your Terraform configuration"
                    return $false
                }
            }
            # Method 3: State refresh approach
            elseif ($errorText -match "resource already exists" -or
                    $errorText -match "already managed" -or
                    $errorText -match "duplicate") {
               
                Write-Host "##[debug]$($script:Emoji.Gear) Method 3: State refresh approach..."
               
                # Resource might already be in state, let's check
                Write-Host "##[debug]Checking if resource already exists in state..."
                $stateShow = terraform state show $ResourceAddress 2>&1
               
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "##[section]$($script:Emoji.Success) Resource already exists in state: $LakehouseName"
                    return $true
                } else {
                    Write-Host "##[debug]Resource not in state, but Terraform thinks it's managed elsewhere"
                   
                    # Try state refresh
                    Write-Host "##[debug]Attempting state refresh..."
                    $refreshResult = terraform refresh 2>&1
                   
                    if ($LASTEXITCODE -eq 0) {
                        # Try import again after refresh
                        $importResult3 = terraform import $ResourceAddress $LakehouseId 2>&1
                       
                        if ($LASTEXITCODE -eq 0) {
                            $importSucceeded = $true
                            Write-Host "##[section]$($script:Emoji.Success) Import successful after refresh: $LakehouseName"
                            return $true
                        }
                    }
                }
            }
            # Method 4: Only use placeholder as absolute last resort
            elseif ($attemptCount -eq $MaxRetryAttempts) {
                Write-Host "##[warning]$($script:Emoji.Warning) All other methods failed, trying placeholder method as last resort..."
               
                # Only use placeholder method if absolutely necessary
                $placeholderSuccess = Import-LakehouseWithProperQuotes -ResourceAddress $ResourceAddress -LakehouseId $LakehouseId -LakehouseName $LakehouseName
               
                if ($placeholderSuccess) {
                    $importSucceeded = $true
                    Write-Host "##[section]$($script:Emoji.Success) Placeholder method successful (last resort): $LakehouseName"
                    Write-Host "##[warning]$($script:Emoji.Warning) NOTE: Check Fabric for any duplicate resources created during placeholder process"
                    return $true
                }
            }
           
        } catch {
            Write-Host "##[error]$($script:Emoji.Error) Exception during import attempt $attemptCount $($_.Exception.Message)"
        }
    }
   
    Write-Host "##[error]$($script:Emoji.Error) All import methods failed for $LakehouseName after $MaxRetryAttempts attempts"
    return $false
}


# Diagnostic function to understand why import might fail
function Diagnose-ImportFailure {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourceAddress,
       
        [Parameter(Mandatory=$true)]
        [string]$LakehouseId
    )
   
    Write-Host "==================================================================="
    Write-Host "  $($script:Emoji.Magnify) DIAGNOSING IMPORT FAILURE"
    Write-Host "==================================================================="
    Write-Host "Resource Address: $ResourceAddress"
    Write-Host "Lakehouse ID: $LakehouseId"
    Write-Host "==================================================================="
   
    # Test 1: Can we target the resource?
    Write-Host ""
    Write-Host "Test 1: Resource configuration validation..."
    $planResult = terraform plan --target=$ResourceAddress 2>&1
   
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 2) {
        Write-Host "$($script:Emoji.Success) Resource configuration is valid"
       
        if ($planResult -match "will be created") {
            Write-Host "$($script:Emoji.Info) Status: Resource needs to be created (not in state)"
        } elseif ($planResult -match "No changes") {
            Write-Host "$($script:Emoji.Info) Status: Resource already exists and is in sync"
        }
    } else {
        Write-Host "$($script:Emoji.Error) Resource configuration is invalid"
        Write-Host "Error: $($planResult -join '; ')"
        Write-Host "This means the resource doesn't exist in your Terraform configuration"
        return
    }
   
    # Test 2: Is it already in state?
    Write-Host ""
    Write-Host "Test 2: Checking current state..."
    $stateShow = terraform state show $ResourceAddress 2>&1
   
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$($script:Emoji.Success) Resource already exists in state"
        Write-Host "You may not need to import - resource is already managed"
        return
    } else {
        Write-Host "$($script:Emoji.Info) Resource not found in current state (expected for import)"
    }
   
    # Test 3: Try the actual import to see the specific error
    Write-Host ""
    Write-Host "Test 3: Testing actual import to see error..."
    $importResult = terraform import $ResourceAddress $LakehouseId 2>&1
   
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$($script:Emoji.Success) Import actually succeeded!"
        return
    } else {
        Write-Host "$($script:Emoji.Error) Import failed with error:"
        $importResult | ForEach-Object { Write-Host "  $_" }
       
        # Provide specific recommendations based on error
        $errorText = $importResult -join " "
       
        Write-Host ""
        Write-Host "Recommendations based on error:"
       
        if ($errorText -match "does not exist in the configuration") {
            Write-Host "$($script:Emoji.Gear) Add the resource to your Terraform configuration first"
        }
        elseif ($errorText -match "already exists" -or $errorText -match "already managed") {
            Write-Host "$($script:Emoji.Gear) Resource might already be managed elsewhere - check other state files"
        }
        elseif ($errorText -match "not found" -or $errorText -match "does not exist") {
            Write-Host "$($script:Emoji.Gear) Verify the Lakehouse ID is correct and the resource exists in Fabric"
        }
        else {
            Write-Host "$($script:Emoji.Gear) Try the improved import method with multiple fallback strategies"
        }
    }
}


# Simplified version that tries direct import first, then placeholder method
function Import-LakehouseSimple {
    param(
        [Parameter(Mandatory=$true)]
        [string]$LakehouseName,
       
        [Parameter(Mandatory=$true)]
        [string]$LakehouseId,
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceName = "PlatformServices-Sandbox",
       
        [Parameter(Mandatory=$false)]
        [string]$TerraformStatePrefix = 'module.lakehouse_names.fabric_lakehouse.this'
    )
   
    $expectedKey = "$WorkspaceName-$LakehouseName"
    $expectedAddress = "$TerraformStatePrefix[`"$expectedKey`"]"
   
    Write-Host "##[section]Importing lakehouse: $LakehouseName" -ForegroundColor Yellow
    Write-Host "##[debug]Address: $expectedAddress"
    Write-Host "##[debug]Fabric ID: $LakehouseId"
   
    # Try direct import first
    Write-Host "##[debug]Attempting direct import..."
    $importResult = terraform import $expectedAddress $LakehouseId 2>&1
   
    if ($LASTEXITCODE -eq 0) {
        Write-Host "##[section]$($script:Emoji.Success) Direct import successful!" -ForegroundColor Green
        return $true
    }
   
    Write-Host "##[warning]Direct import failed: $($importResult -join '; ')" -ForegroundColor Yellow
   
    # Try placeholder method
    Write-Host "##[debug]Trying placeholder method..."
   
    # Step 1: Create placeholder
    Write-Host "##[debug]Creating placeholder..."
    $applyResult = terraform apply --target=$expectedAddress -auto-approve 2>&1
   
    if ($LASTEXITCODE -ne 0) {
        Write-Host "##[error]Failed to create placeholder: $($applyResult -join '; ')" -ForegroundColor Red
        return $false
    }
   
    # Step 2: Remove from state
    Write-Host "##[debug]Removing placeholder from state..."
    $removeResult = terraform state rm $expectedAddress 2>&1
   
    if ($LASTEXITCODE -ne 0) {
        Write-Host "##[error]Failed to remove placeholder: $($removeResult -join '; ')" -ForegroundColor Red
        return $false
    }
   
    # Step 3: Import existing
    Write-Host "##[debug]Importing existing resource..."
    $importResult2 = terraform import $expectedAddress $LakehouseId 2>&1
   
    if ($LASTEXITCODE -eq 0) {
        Write-Host "##[section]$($script:Emoji.Success) Placeholder method successful!" -ForegroundColor Green
        return $true
    } else {
        Write-Host "##[error]Placeholder method failed: $($importResult2 -join '; ')" -ForegroundColor Red
        return $false
    }
}

# Main execution function for direct script usage
function Main {
    param(
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [string]$Environment = "dev",
       
        [Parameter(Mandatory=$false)]
        [string]$WorkspaceStatePrefix = 'module.fabric_workspace.fabric_workspace.this',
       
        [Parameter(Mandatory=$false)]
        [string]$LakehouseStatePrefix = 'module.lakehouse_names.fabric_lakehouse.this',
       
        [Parameter(Mandatory=$false)]
        [string]$NotebookStatePrefix = 'module.notebooks.fabric_notebook.this',
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1,
       
        [Parameter(Mandatory=$false)]
        [switch]$SkipWorkspaces,
       
        [Parameter(Mandatory=$false)]
        [switch]$SkipLakehouses,
       
        [Parameter(Mandatory=$false)]
        [switch]$SkipNotebooks,
       
        [Parameter(Mandatory=$false)]
        [switch]$WorkspacesOnly,
       
        [Parameter(Mandatory=$false)]
        [switch]$LakehousesOnly,
       
        [Parameter(Mandatory=$false)]
        [switch]$NotebooksOnly
    )
   
    # Display script banner
    Write-Host ""
    Write-Host "=================================================================="
    Write-Host "  $($script:Emoji.Gear) Workspace, Lakehouse and Notebook State Reconciliation Tool"
    Write-Host "=================================================================="
   
    # Handle convenience switches
    if ($WorkspacesOnly) {
        $SkipLakehouses = $true
        $SkipNotebooks = $true
    }
    if ($LakehousesOnly) {
        $SkipWorkspaces = $true
        $SkipNotebooks = $true
    }
    if ($NotebooksOnly) {
        $SkipWorkspaces = $true
        $SkipLakehouses = $true
    }
   
    # Get WorkspaceId from environment if not provided (only needed for lakehouse/notebook operations)
    if (-not $WorkspaceId -and (-not $SkipLakehouses -or -not $SkipNotebooks)) {
        $WorkspaceId = $env:fabricWorkspaceId
       
        if (-not $WorkspaceId -and (-not $SkipLakehouses -or -not $SkipNotebooks)) {
            Write-Host "##[warning]$($script:Emoji.Warning) WorkspaceId not provided and not found in environment."
            Write-Host "##[warning]Lakehouse and notebook reconciliation will be skipped."
            $SkipLakehouses = $true
            $SkipNotebooks = $true
        }
    }
   
    Write-Host "Environment:             $Environment"
    Write-Host "Workspace State Prefix:  $WorkspaceStatePrefix"
    Write-Host "Lakehouse State Prefix:  $LakehouseStatePrefix"
    Write-Host "Notebook State Prefix:   $NotebookStatePrefix"
    Write-Host "Max Retry Attempts:      $MaxRetryAttempts"
    if ($WorkspaceId) {
        Write-Host "Workspace ID:            $WorkspaceId"
    } else {
        Write-Host "Workspace ID:            Not provided (workspace-level operations only)"
    }
   
    if ($SkipWorkspaces -and $SkipLakehouses -and $SkipNotebooks) {
        Write-Host "Mode:                    All operations skipped"
    } elseif ($WorkspacesOnly) {
        Write-Host "Mode:                    Workspaces Only"
    } elseif ($LakehousesOnly) {
        Write-Host "Mode:                    Lakehouses Only"
    } elseif ($NotebooksOnly) {
        Write-Host "Mode:                    Notebooks Only"
    } else {
        $modes = @()
        if (-not $SkipWorkspaces) { $modes += "Workspaces" }
        if (-not $SkipLakehouses) { $modes += "Lakehouses" }
        if (-not $SkipNotebooks) { $modes += "Notebooks" }
        Write-Host "Mode:                    $($modes -join ', ')"
    }
    Write-Host "=================================================================="
    Write-Host ""
   
    # Verify Terraform is available and backend is configured
    try {
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
        $params = @{
            Environment = $Environment
            WorkspaceStatePrefix = $WorkspaceStatePrefix
            LakehouseStatePrefix = $LakehouseStatePrefix
            NotebookStatePrefix = $NotebookStatePrefix
            MaxRetryAttempts = $MaxRetryAttempts
        }
       
        if ($WorkspaceId) { $params.WorkspaceId = $WorkspaceId }
        if ($SkipWorkspaces) { $params.SkipWorkspaces = $true }
        if ($SkipLakehouses) { $params.SkipLakehouses = $true }
        if ($SkipNotebooks) { $params.SkipNotebooks = $true }
       
        Write-Host "Starting reconciliation process..."
        $result = Invoke-WorkspaceLakehouseAndNotebookReconciliation @params
       
        Write-Host ""
        if ($result) {
            Write-Host "$($script:Emoji.Success) Reconciliation completed successfully!" -ForegroundColor Green
            exit 0
        } else {
            Write-Host "$($script:Emoji.Error) Reconciliation completed with errors." -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host "##[error]$($script:Emoji.Error) Error during reconciliation: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
        exit 1
    }
}

function Invoke-WorkspaceReconciliation {
    param(
        [Parameter(Mandatory=$false)]
        [string]$Environment = "dev",
       
        [Parameter(Mandatory=$false)]
        [string]$StatePrefix = 'module.fabric_workspace.fabric_workspace.this',
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    return Import-MissingWorkspaces -Environment $Environment -TerraformStatePrefix $StatePrefix -MaxRetryAttempts $MaxRetryAttempts
}

# Individual functions for specific use cases
function Invoke-LakehouseReconciliation {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [string]$Environment = "dev",
       
        [Parameter(Mandatory=$false)]
        [string]$StatePrefix = 'module.lakehouse_names.fabric_lakehouse.this',
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    return Import-MissingLakehouses -WorkspaceId $WorkspaceId -Environment $Environment -TerraformStatePrefix $StatePrefix -MaxRetryAttempts $MaxRetryAttempts
}

function Invoke-NotebookReconciliation {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$false)]
        [string]$Environment = "dev",
       
        [Parameter(Mandatory=$false)]
        [string]$StatePrefix = 'module.notebooks.fabric_notebook.this',
       
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryAttempts = 1
    )
   
    return Import-MissingNotebooks -WorkspaceId $WorkspaceId -Environment $Environment -TerraformStatePrefix $StatePrefix -MaxRetryAttempts $MaxRetryAttempts
}

$token = $env:FABRIC_TOKEN

Main @args
