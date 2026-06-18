param(
    [Parameter(Mandatory=$false)]
    [string]$FabricSourcePath = "../../../src/fabric",
   
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceName,
   
    [Parameter(Mandatory=$false)]
    [string]$ShortcutsJson = ""
)

function Get-FabricAccessToken {
    param([string]$Purpose = "Lakehouse Shortcuts")
   
    try {
        Write-Host "##[debug]Retrieving Fabric access token using Azure CLI for $Purpose"
       
        $clientId = $env:ARM_CLIENT_ID
        $clientSecret = $env:ARM_CLIENT_SECRET
        $tenantId = $env:ARM_TENANT_ID
       
        if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($clientSecret) -or [string]::IsNullOrEmpty($tenantId)) {
            Write-Error "ARM_CLIENT_ID, ARM_CLIENT_SECRET, and ARM_TENANT_ID environment variables must be set"
            throw "Missing Azure service principal credentials"
        }
       
        Write-Host "##[debug]Logging in to Azure with service principal"
        $loginResult = az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId 2>&1
       
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Azure CLI login failed: $loginResult"
            throw "Azure CLI login failed"
        }
       
        Write-Host "##[debug]Successfully logged in to Azure"
       
        $tokenResult = az account get-access-token --resource https://api.fabric.microsoft.com/ --query accessToken --output tsv 2>&1
       
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to get Fabric access token: $tokenResult"
            throw "Failed to get Fabric access token"
        }
       
        if ([string]::IsNullOrEmpty($tokenResult)) {
            Write-Error "Received empty access token"
            throw "Received empty access token"
        }
       
        Write-Host "##[debug]Successfully retrieved Fabric access token"
        return $tokenResult.Trim()
    }
    catch {
        Write-Error "Failed to get Fabric access token: $_"
        throw
    }
}

function Get-ShortcutMetadataFiles {
    param(
        [string]$SourcePath
    )
   
    try {
        Write-Host "##[debug]Searching for shortcuts.metadata.json files in: $SourcePath"
       
        $shortcutFiles = Get-ChildItem -Path $SourcePath -Recurse -Filter "shortcuts.metadata.json" |
            Where-Object { $_.Directory.Name -like "*.Lakehouse" } |
            Select-Object -ExpandProperty FullName
       
        Write-Host "##[debug]Found $($shortcutFiles.Count) shortcut metadata files"
       
        # Display shortcutFile for debugging
        foreach ($file in $shortcutFiles) {
            Write-Host "##[debug]  - $file"
        }

        return $shortcutFiles
    }
    catch {
        Write-Error "Failed to get shortcut metadata files: $_"
        throw
    }
}

function Read-ShortcutMetadata {
    param(
        [array]$ShortcutFiles,
        [string]$WorkspaceName
    )
   
    try {
        Write-Host "##[debug]Reading shortcut metadata from files"

        $allFileShortcuts = @()
        foreach ($shortcutFile in $ShortcutFiles) {
            try {
                $shortcutContent = Get-Content $shortcutFile -Raw | ConvertFrom-Json
                # Display shortcutContent for debugging
                Write-Host "##[debug]Processing shortcut file: $shortcutFile"
                Write-Host "##[debug]  Content: $($shortcutContent | ConvertTo-Json -Depth 5)"
                
                $lakehouseDir = Split-Path -Parent $shortcutFile
                $platformFile = Join-Path $lakehouseDir ".platform"
               
                if (-not (Test-Path $platformFile)) {
                    Write-Warning "Platform file not found for: $shortcutFile"
                    continue
                }
               
                $platformContent = Get-Content $platformFile -Raw | ConvertFrom-Json
                $consumerLakehouseName = $platformContent.metadata.displayName
               
                foreach ($shortcut in $shortcutContent) {
                    $allFileShortcuts += @{
                        ShortcutName = $shortcut.name
                        NormalizedName = $shortcut.name.ToLower().Trim()
                        ConsumerLakehouseName = $consumerLakehouseName
                        ConsumerWorkspaceName = $WorkspaceName
                        ShortcutPath = $shortcut.path
                        TargetType = $shortcut.target.type
                        TargetPath = $shortcut.target.oneLake.path
                        TargetItemId = $consumerLakehouseName
                        TargetWorkspaceId = $WorkspaceName
                        Source = "file"
                    }
                   
                    Write-Host "##[debug]  - Shortcut: $($shortcut.name) in $consumerLakehouseName"
                }
            }
            catch {
                Write-Warning "Failed to read shortcut file: $shortcutFile - $_"
            }
        }
       
        Write-Host "##[debug]Loaded $($allFileShortcuts.Count) shortcuts from files"
       
        return $allFileShortcuts
    }
    catch {
        Write-Error "Failed to read shortcut metadata: $_"
        throw
    }
}

function Merge-Shortcuts {
    param(
        [array]$FileShortcuts,
        [array]$VariableShortcuts
    )
   
    try {
        Write-Host "##[debug]Merging variable shortcuts with file shortcuts"
       
        # Create lookup dictionary for file shortcuts
        $fileShortcutLookup = @{}
        foreach ($shortcut in $FileShortcuts) {
            $fileShortcutLookup[$shortcut.NormalizedName] = $shortcut
        }
       
        $mergedShortcuts = @()
       
        # Process variable shortcuts (if provided)
        if ($VariableShortcuts.Count -gt 0) {
            Write-Host "##[debug]Processing $($VariableShortcuts.Count) variable shortcuts"
           
            foreach ($varShortcut in $VariableShortcuts) {
                $normalizedName = $varShortcut.name.ToLower().Trim()
               
                if ($fileShortcutLookup.ContainsKey($normalizedName)) {
                    $fileShortcut = $fileShortcutLookup[$normalizedName]
                   
                    $mergedShortcuts += @{
                        ShortcutName = $varShortcut.name.Trim()
                        LakehouseName = $varShortcut.lakehouse.Trim()
                        WorkspaceName = $varShortcut.workspace.Trim()
                        ConsumerLakehouseName = $fileShortcut.ConsumerLakehouseName
                        ConsumerWorkspaceName = $fileShortcut.ConsumerWorkspaceName
                        ShortcutPath = $fileShortcut.ShortcutPath
                        TargetType = $fileShortcut.TargetType
                        TargetPath = $fileShortcut.TargetPath
                        TargetItemId = $varShortcut.lakehouse.Trim()
                        TargetWorkspaceId = $varShortcut.workspace.Trim()
                        FileTargetItemId = $fileShortcut.FileTargetItemId
                        FileTargetWorkspaceId = $fileShortcut.FileTargetWorkspaceId
                        HasFileMatch = $true
                        Source = "merged"
                    }
                   
                    # Remove from lookup to track which were matched
                    $fileShortcutLookup.Remove($normalizedName)
                   
                    Write-Host "##[debug]  - Merged: $($varShortcut.name) -> $($varShortcut.lakehouse)"
                }
            }
        }
       
        # Add remaining file shortcuts (simplicity approach)
        Write-Host "##[debug]Adding remaining file shortcuts"
        foreach ($key in $fileShortcutLookup.Keys) {
            $fileShortcut = $fileShortcutLookup[$key]
           
            $mergedShortcuts += @{
                ShortcutName = $fileShortcut.ShortcutName
                LakehouseName = $fileShortcut.ConsumerLakehouseName
                WorkspaceName = $fileShortcut.ConsumerWorkspaceName
                ConsumerLakehouseName = $fileShortcut.ConsumerLakehouseName
                ConsumerWorkspaceName = $fileShortcut.ConsumerWorkspaceName
                ShortcutPath = $fileShortcut.ShortcutPath
                TargetType = $fileShortcut.TargetType
                TargetPath = $fileShortcut.TargetPath
                TargetItemId = $fileShortcut.ConsumerLakehouseName
                TargetWorkspaceId = $fileShortcut.ConsumerWorkspaceName
                FileTargetItemId = $fileShortcut.FileTargetItemId
                FileTargetWorkspaceId = $fileShortcut.FileTargetWorkspaceId
                HasFileMatch = $true
                Source = $fileShortcut.Source
            }
           
            Write-Host "##[debug]  - Added: $($fileShortcut.ShortcutName)"
        }
       
        Write-Host "##[debug]Total merged shortcuts: $($mergedShortcuts.Count)"
       
        return $mergedShortcuts
    }
    catch {
        Write-Error "Failed to merge shortcuts: $_"
        throw
    }
}

# Main execution
try {
    Write-Host "##[section]Lakehouse Shortcuts Deployment"
    Write-Host ""
   
    # Resolve fabric source path
    $resolvedSourcePath = $FabricSourcePath
    if (-not [System.IO.Path]::IsPathRooted($resolvedSourcePath)) {
        $resolvedSourcePath = Join-Path $PSScriptRoot $resolvedSourcePath
    }
   
    Write-Host "##[debug]Fabric Source Path: $resolvedSourcePath"
   
    if (-not (Test-Path $resolvedSourcePath)) {
        Write-Error "Fabric source path not found: $resolvedSourcePath"
        exit 1
    }
   
    # Get Fabric token
    Write-Host "##[section]Authenticating to Fabric..."
    $token = Get-FabricAccessToken -Purpose "Lakehouse Shortcuts Deployment"
    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "Failed to retrieve Fabric access token"
        exit 1
    }
   
    # Set token as environment variable for Invoke-ShortcutCreation.ps1
    $env:FABRIC_TOKEN = $token
    Write-Host "##[debug]FABRIC_TOKEN environment variable set"
    Write-Host ""
   

    # Find and read shortcut metadata files
    Write-Host "##[section]Reading Shortcut Metadata Files"
    $shortcutFiles = Get-ShortcutMetadataFiles -SourcePath $resolvedSourcePath
   
    if ($shortcutFiles.Count -eq 0) {
        Write-Warning "No shortcut metadata files found in: $resolvedSourcePath"
        Write-Host "##[endgroup]"
        exit 0
    }
   
    $fileShortcuts = Read-ShortcutMetadata -ShortcutFiles $shortcutFiles -WorkspaceName $WorkspaceName
    Write-Host "##[endgroup]"
    Write-Host ""
   
    # Parse variable shortcuts (if provided)
    $variableShortcuts = @()
    if (-not [string]::IsNullOrEmpty($ShortcutsJson)) {
        Write-Host "##[section]Parsing Variable Shortcuts"
        try {
            $variableShortcuts = $ShortcutsJson | ConvertFrom-Json
            Write-Host "##[debug]Parsed $($variableShortcuts.Count) variable shortcuts"
        }
        catch {
            Write-Warning "Failed to parse shortcuts JSON: $_"
        }
        Write-Host ""
    }
   
    # Merge shortcuts
    Write-Host "##[section]Merging Shortcuts"
    Write-Host "##[group]Shortcut Merging"
    $mergedShortcuts = Merge-Shortcuts -FileShortcuts $fileShortcuts -VariableShortcuts $variableShortcuts
    Write-Host "##[endgroup]"
    Write-Host ""
   
    if ($mergedShortcuts.Count -eq 0) {
        Write-Warning "No shortcuts to create after merging"
        exit 0
    }
   
    # Create shortcuts
    Write-Host "##[section]Creating Shortcuts"
    Write-Host "##[debug]Total shortcuts to create: $($mergedShortcuts.Count)"
    Write-Host ""
   
    $successCount = 0
    $failureCount = 0
    $invokeScript = Join-Path $PSScriptRoot "Invoke-ShortcutCreation.ps1"
   
    if (-not (Test-Path $invokeScript)) {
        Write-Error "Invoke-ShortcutCreation.ps1 not found at: $invokeScript"
        exit 1
    }
   
    #  Display mergedSHortcuts for debugging
    Write-Host "##[debug]Merged Shortcuts to Create:"
    Write-Host ($mergedShortcuts | ConvertTo-Json -Depth 5)

    foreach ($shortcut in $mergedShortcuts) {
        try {
            Write-Host "##[group]Creating: $($shortcut.ShortcutName)"
            Write-Host "##[debug]  Consumer: $($shortcut.ConsumerWorkspaceName)/$($shortcut.ConsumerLakehouseName)"
            Write-Host "##[debug]  Target: $($shortcut.TargetWorkspaceId)/$($shortcut.TargetItemId)"
            Write-Host "##[debug]  Path: $($shortcut.ShortcutPath) -> $($shortcut.TargetPath)"
            Write-Host "##[debug]  Source: $($shortcut.Source)"
           
            # Call Invoke-ShortcutCreation.ps1
            & $invokeScript `
                -ConsumerWorkspaceName $shortcut.ConsumerWorkspaceName `
                -ConsumerLakehouseName $shortcut.ConsumerLakehouseName `
                -ShortcutName $shortcut.ShortcutName `
                -ShortcutPath $shortcut.ShortcutPath `
                -TargetWorkspaceName $shortcut.TargetWorkspaceId `
                -TargetLakehouseName $shortcut.TargetItemId `
                -TargetPath $shortcut.TargetPath
           
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to create shortcut: $($shortcut.ShortcutName)"
                $failureCount++
            } else {
                Write-Host "##[section] Shortcut created successfully"
                $successCount++
            }
           
            Write-Host "##[endgroup]"
            Write-Host ""
        }
        catch {
            Write-Error "Error creating shortcut $($shortcut.ShortcutName): $_"
            $failureCount++
            Write-Host "##[endgroup]"
            Write-Host ""
        }
    }
   
    # Summary
    Write-Host ""
    Write-Host "##[section]Shortcuts Deployment Summary"
    Write-Host "##[section]Total:    $($mergedShortcuts.Count)"
    Write-Host "##[section]Success:  $successCount"
    if ($failureCount -gt 0) {
        Write-Host "##[warning]Failed:   $failureCount"
    } else {
        Write-Host "##[section]Failed:   $failureCount"
    }   
    Write-Host ""
   
    if ($failureCount -gt 0) {
        Write-Error "Some shortcuts failed to create"
        exit 1
    }
   
    Write-Host "##[section] All shortcuts deployed successfully"
    exit 0
}
catch {
    Write-Error "Error in lakehouse shortcuts deployment: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
}