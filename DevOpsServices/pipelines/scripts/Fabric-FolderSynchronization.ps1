# ===================================================================
# FABRIC FOLDER SYNCHRONIZATION SYSTEM
# Syncs folder structure between Azure DevOps Git and Fabric workspace
# ===================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceName,
   
    [Parameter(Mandatory=$false)]
    [string]$SourceCodePath = "../../../src/fabric",
   
    [Parameter(Mandatory=$false)]
    [switch]$DeleteOrphanedFolders = $false
)

function Get-FabricAccessToken {
    try {
        Write-Host "Retrieving Fabric access token using Azure CLI"
       
        # Login to Azure using service principal
        $clientId = $env:ARM_CLIENT_ID
        $clientSecret = $env:ARM_CLIENT_SECRET
        $tenantId = $env:ARM_TENANT_ID
       
        if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($clientSecret) -or [string]::IsNullOrEmpty($tenantId)) {
            Write-Error "ARM_CLIENT_ID, ARM_CLIENT_SECRET, and ARM_TENANT_ID environment variables must be set"
            throw "Missing Azure service principal credentials"
        }
       
        Write-Host "Logging in to Azure with service principal"
        $loginResult = az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId 2>&1
       
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Azure CLI login failed: $loginResult"
            throw "Azure CLI login failed"
        }
       
        Write-Host "Successfully logged in to Azure"
       
        # Get access token for PowerBI/Fabric API
        Write-Host "Retrieving access token for Fabric API"
        $tokenResult = az account get-access-token --resource https://api.fabric.microsoft.com/ --query accessToken --output tsv 2>&1
       
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to get Fabric access token: $tokenResult"
            throw "Failed to get Fabric access token"
        }
       
        if ([string]::IsNullOrEmpty($tokenResult)) {
            Write-Error "Received empty access token"
            throw "Received empty access token"
        }
       
        Write-Host "Successfully retrieved Fabric access token"
        return $tokenResult.Trim()
    }
    catch {
        Write-Error "Failed to get Fabric access token: $_"
        throw
    }
}

# ===================================================================
# STEP 0: WORKSPACE RESOLUTION
# ===================================================================

function Get-WorkspaceByName {
    param(
        [string]$WorkspaceName,
        [hashtable]$Headers
    )
   
    Write-Host "##[section] RESOLVING WORKSPACE BY NAME"
    Write-Host "=========================================="
    Write-Host "Looking for workspace: '$WorkspaceName'"
   
    try {
        $uri = "https://api.fabric.microsoft.com/v1/workspaces"
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET
       
        Write-Host "##[debug] Found $($response.value.Count) total workspaces"
       
        # Find workspace by display name (case-insensitive)
        $targetWorkspace = $response.value | Where-Object {
            $_.displayName -eq $WorkspaceName
        }
       
        if (-not $targetWorkspace) {
            # Try case-insensitive match
            $targetWorkspace = $response.value | Where-Object {
                $_.displayName.ToLower() -eq $WorkspaceName.ToLower()
            }
        }
       
        if ($targetWorkspace) {
            Write-Host "##[debug] Found workspace:"
            Write-Host "##[debug]   ID: $($targetWorkspace.id)"
            Write-Host "##[debug]   Name: $($targetWorkspace.displayName)"
            Write-Host "##[debug]   Type: $($targetWorkspace.type)"
            if ($targetWorkspace.description) {
                Write-Host "##[debug]   Description: $($targetWorkspace.description)"
            }
            if ($targetWorkspace.capacityId) {
                Write-Host "##[debug]   Capacity ID: $($targetWorkspace.capacityId)"
            }
           
            return @{
                Success = $true
                Workspace = $targetWorkspace
                WorkspaceId = $targetWorkspace.id
                WorkspaceName = $targetWorkspace.displayName
            }
        } else {
            Write-Host "##[error] Workspace '$WorkspaceName' not found"
           
            # Show available workspaces for debugging
            Write-Host "##[debug] Available workspaces:"
            $response.value | ForEach-Object {
                Write-Host "##[debug]   - '$($_.displayName)' (ID: $($_.id), Type: $($_.type))"
            }
           
            return @{
                Success = $false
                Error = "Workspace '$WorkspaceName' not found"
                Workspace = $null
                WorkspaceId = $null
                WorkspaceName = $null
                AvailableWorkspaces = $response.value
            }
        }
    }
    catch {
        Write-Host "##[error] Failed to get workspaces: $($_.Exception.Message)"
        return @{
            Success = $false
            Error = "Failed to retrieve workspaces: $($_.Exception.Message)"
        }
    }
}

# ===================================================================
# STEP 1: DISCOVER ALL FABRIC ARTIFACTS FROM SOURCE CODE
# ===================================================================

function Get-FabricArtifactsFromSource {
    param(
        [string]$BasePath
    )

    Write-Host "##[section] DISCOVERING FABRIC ARTIFACTS FROM SOURCE CODE"
    Write-Host "============================================================"
    Write-Host "Base Path: $BasePath"
   
    $supportedArtifactTypes = @(
        "SemanticModel", "Report", "Dashboard", "Lakehouse", "Notebook",
        "DataPipeline", "Environment", "KQLDashboard"
    )
   
    $artifactsMap = @{}
    $foldersMap = @{}
   
    foreach ($artifactType in $supportedArtifactTypes) {
        Write-Host "##[debug] Searching for *.$artifactType artifacts..."
       
        try {
            # Find all artifacts of this type
            $artifacts = Get-ChildItem -Path $BasePath -Directory -Recurse -Include "*.$artifactType"
           
            Write-Host "##[debug] Found $($artifacts.Count) $artifactType artifacts"
           
            foreach ($artifact in $artifacts) {
                # Get relative path from base
                $relativePath = $artifact.FullName.Replace($BasePath, "").TrimStart('\', '/')
               
                # Extract folder path (everything except the artifact folder itself)
                $folderPath = Split-Path $relativePath -Parent
                if ($folderPath -eq ".") { $folderPath = "" }  # Root level
               
                # Check if .platform file exists
                $platformFile = Join-Path $artifact.FullName ".platform"
                if (Test-Path $platformFile) {
                    try {
                        $platformContent = Get-Content $platformFile -Raw | ConvertFrom-Json
                       
                        $artifactInfo = @{
                            Name = $artifact.Name
                            Type = $artifactType
                            DisplayName = $platformContent.metadata.displayName
                            LogicalId = $platformContent.config.logicalId
                            FolderPath = $folderPath
                            FullPath = $artifact.FullName
                            RelativePath = $relativePath
                        }
                       
                        # Add to artifacts map
                        if (-not $artifactsMap.ContainsKey($artifactType)) {
                            $artifactsMap[$artifactType] = @()
                        }
                        $artifactsMap[$artifactType] += $artifactInfo
                       
                        # Track folder usage
                        if ($folderPath -ne "") {
                            if (-not $foldersMap.ContainsKey($folderPath)) {
                                $foldersMap[$folderPath] = @{
                                    Path = $folderPath
                                    Artifacts = @()
                                    Depth = ($folderPath.Split('/', [StringSplitOptions]::RemoveEmptyEntries)).Count
                                }
                            }
                            $foldersMap[$folderPath].Artifacts += $artifactInfo
                        }
                       
                        Write-Host "##[debug]   $($artifactInfo.DisplayName) -> Folder: '$folderPath'"
                    }
                    catch {
                        Write-Host "##[warning] Failed to parse .platform file: $platformFile - $($_.Exception.Message)"
                    }
                } else {
                    Write-Host "##[debug]   No .platform file found: $($artifact.Name)"
                }
            }
        }
        catch {
            Write-Host "##[error] Error searching for $artifactType $($_.Exception.Message)"
        }
    }
   
    # Build folder hierarchy
    $folderHierarchy = Build-FolderHierarchy -FoldersMap $foldersMap
   
    # display folder Hierarchy json for debugging
    write-Host "##[debug] Folder hierarchy: "
    Write-Host "##[debug] $($folderHierarchy | ConvertTo-Json -Depth 10)"


    Write-Host ""
    Write-Host "##[section] DISCOVERY SUMMARY"
    Write-Host "================================"
    Write-Host "Total artifact types found: $($artifactsMap.Keys.Count)"
    foreach ($type in $artifactsMap.Keys) {
        Write-Host "  $type $($artifactsMap[$type].Count) artifacts"
    }
    Write-Host "Total unique folders needed: $($foldersMap.Keys.Count)"
    Write-Host ""
   
    return @{
        Artifacts = $artifactsMap
        Folders = $foldersMap
        FolderHierarchy = $folderHierarchy
    }
}

function Build-FolderHierarchy {
    param($FoldersMap)
   
    $hierarchy = @()
   
    # Sort folders by depth (parents first)
    $sortedFolders = $FoldersMap.Values | Sort-Object Depth
   
    foreach ($folder in $sortedFolders) {
        $pathParts = $folder.Path.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
       
        $hierarchyItem = @{
            Path = $folder.Path
            Name = $pathParts[-1]  # Last part is the folder name
            ParentPath = if ($pathParts.Count -gt 1) {
                ($pathParts[0..($pathParts.Count-2)] -join '/')
            } else {
                ""
            }
            Depth = $folder.Depth
            Artifacts = $folder.Artifacts
        }
       
        $hierarchy += $hierarchyItem
    }
   
    return $hierarchy
}

# ===================================================================
# STEP 2: GET CURRENT WORKSPACE FOLDERS
# ===================================================================

function Get-WorkspaceFolders {
    param(
        [string]$WorkspaceId,
        [hashtable]$Headers
    )
   
    Write-Host "##[section] GETTING CURRENT WORKSPACE FOLDERS"
    Write-Host "==============================================="
   
    try {

        if ($null -eq $WorkspaceId) {
            Write-Host "##[error] WorkspaceId is null"
            return @{
                Folders = @{}
                FolderHierarchy = @()
            }
        }
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/folders"
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET
       
        $folders = @{}
        $folderHierarchy = @()
       
        foreach ($folder in $response.value) {
            # Build folder path from hierarchy
            $folderPath = Get-FolderPath -FolderId $folder.id -AllFolders $response.value
           
            $folderInfo = @{
                Id = $folder.id
                DisplayName = $folder.displayName
                WorkspaceId = $folder.workspaceId
                ParentFolderId = $folder.parentFolderId
                Path = $folderPath
            }
           
            $folders[$folder.id] = $folderInfo
            $folderHierarchy += $folderInfo
        }
       
        Write-Host "##[debug] Found $($folders.Keys.Count) folders in workspace"
       
        # Show folder structure
        Write-Host "##[debug] Current folder structure:"
        $folderHierarchy | Sort-Object Path | ForEach-Object {
            $indent = "  " * (($_.Path.Split('/').Count) - 1)
            Write-Host "##[debug]$indent $($_.DisplayName) -> $($_.Path)"
        }
       
        return @{
            Folders = $folders
            FolderHierarchy = $folderHierarchy
        }
    }
    catch {
        Write-Host "##[error] Failed to get workspace folders: $($_.Exception.Message)"
        return @{
            Folders = @{}
            FolderHierarchy = @()
        }
    }
}

function Get-FolderPath {
    param(
        [string]$FolderId,
        [array]$AllFolders
    )
   
    $folder = $AllFolders | Where-Object { $_.id -eq $FolderId }
    if (-not $folder) { return "" }
   
    $path = $folder.displayName
   
    # Walk up the hierarchy
    $currentFolder = $folder
    while ($currentFolder.parentFolderId) {
        $parentFolder = $AllFolders | Where-Object { $_.id -eq $currentFolder.parentFolderId }
        if ($parentFolder) {
            $path = "$($parentFolder.displayName)/$path"
            $currentFolder = $parentFolder
        } else {
            break
        }
    }
   
    return $path
}

# ===================================================================
# STEP 3: COMPARE AND PLAN SYNCHRONIZATION
# ===================================================================

function Compare-FolderStructures {
    param(
        [object]$SourceStructure,
        [object]$WorkspaceStructure
    )
   
    Write-Host "##[section] COMPARING FOLDER STRUCTURES"
    Write-Host "=========================================="
   
    $syncPlan = @{
        FoldersToCreate = @()
        FoldersToDelete = @()
        FoldersToUpdate = @()
        FoldersToMove = @()
        UnchangedFolders = @()
    }
   
    # Create lookup maps
    $sourceByPath = @{}
    foreach ($folder in $SourceStructure.FolderHierarchy) {
        $sourceByPath[$folder.Path] = $folder
    }
   
    $workspaceByPath = @{}
    $workspaceFolders = @() # Store all workspace folders for tail matching
    foreach ($folder in $WorkspaceStructure.FolderHierarchy) {
        $workspaceByPath[$folder.Path] = $folder
        $workspaceFolders += $folder
    }
   
    # Find folders to create (in source but not in workspace)
    foreach ($sourcePath in $sourceByPath.Keys) {

        # convert source path to json
        Write-Host "##[debug] Processing source path: $sourcePath"

        # Check tail path matching - iterate through all workspace folders
        $tailMatchFound = $false
        $sourcePathNormalize = $sourcePath -replace '\\', '/'  # Normalize path separators
        Write-Host "##[debug] Checking source path: '$sourcePathNormalize'"


        if (-not [string]::IsNullOrEmpty($sourcePathNormalize)) {
            foreach ($workspaceFolder in $workspaceFolders) {
                # Write-Host "##[debug] Checking tail match for source: '$sourcePathNormalize' against workspace: '$($workspaceFolder.Path)'"

                $sourceTailPath = Get-TailPathFromSourcePath -SourcePath $sourcePathNormalize


                # Check if source tail matches the END of workspace path
                if (Test-TailPathMatch -SourceTail $sourceTailPath -WorkspaceTail $workspaceFolder.Path) {  
                    $tailMatchFound = $true
                    Write-Host "##[debug] TAIL MATCH FOUND: '$sourceTailPath' matches '$($workspaceFolder.Path)'"
                    break
                }
            }
        }

        if ($tailMatchFound -eq $false) {
            $syncPlan.FoldersToCreate += $sourceByPath[$sourcePath]
            Write-Host "##[debug] CREATE: $sourcePath"
        } 
    }
   
    # Find folders to delete (in workspace but not in source, considering tail matching)
    foreach ($workspacePath in $workspaceByPath.Keys) {
        $workspaceFolder = $workspaceByPath[$workspacePath]
       
        # Skip if exact path exists in source
        if ($sourceByPath.ContainsKey($workspacePath)) {
            continue
        }
       
        # Check if this workspace folder has a tail match in source
        $tailMatchInSource = $false
        $workspaceTailPath = Get-TailPathFromWorkspacePath -WorkspacePath $workspacePath
       
        if (-not [string]::IsNullOrEmpty($workspaceTailPath)) {
            foreach ($sourcePath in $sourceByPath.Keys) {
                $sourceTailPath = Get-TailPathFromSourcePath -SourcePath $sourcePath
               
                if (Test-TailPathMatchDelete -SourceTail $sourceTailPath -WorkspaceTail $workspaceTailPath) {
                    $tailMatchInSource = $true
                    Write-Host "##[debug] Workspace folder '$workspacePath' has tail match in source - keeping"
                    break
                }
            }
        }
       
        if (-not $tailMatchInSource) {
            $syncPlan.FoldersToDelete += $workspaceFolder
            Write-Host "##[debug] DELETE: $workspacePath (no tail match in source)"
        }
    }   

    Write-Host ""
    Write-Host "##[section] SYNCHRONIZATION PLAN SUMMARY"
    Write-Host "==========================================="
    Write-Host "Folders to CREATE: $($syncPlan.FoldersToCreate.Count)"
    Write-Host "Folders to DELETE: $($syncPlan.FoldersToDelete.Count)"
    Write-Host "Folders to UPDATE: $($syncPlan.FoldersToUpdate.Count)"
    Write-Host "Folders UNCHANGED: $($syncPlan.UnchangedFolders.Count)"
   
    return $syncPlan
}

function Get-TailPathFromWorkspacePath {
    param(
        [string]$WorkspacePath
    )
   
    if ([string]::IsNullOrEmpty($WorkspacePath)) {
        return ""
    }
   
    # Workspace paths should already be in the correct format
    # Just normalize separators to forward slashes
    $tailPath = $WorkspacePath -replace '\\', '/'
   
    return $tailPath
}

function Get-TailPathFromSourcePath {
    param(
        [string]$SourcePath
    )
   
    if ([string]::IsNullOrEmpty($SourcePath)) {
        return ""
    }
   
    # For source paths, extract the relative path after 'src/fabric'
    $relativePath = Get-RelativePathFromSrcFabric -FullPath $SourcePath
   
    # Normalize path separators to forward slashes
    $tailPath = $relativePath -replace '\\', '/'
   
    return $tailPath
}

function Test-TailPathMatchDelete {
    param([string]$SourceTail, [string]$WorkspaceTail)
   
    Write-Host "##[debug] Testing tail path match: '$SourceTail' against workspace: '$WorkspaceTail'"

    # Check if workspace path ENDS with the source tail
    $sourcePaths = $SourceTail -split '/'
    $workspacePaths = $WorkspaceTail -split '/'

    if ($sourcePaths.Count -eq $workspacePaths.Count) {

        $endsWith = $WorkspaceTail.EndsWith($SourceTail, [System.StringComparison]::OrdinalIgnoreCase)

        if ($endsWith) {
            # If exact match, it's valid
            if ($SourceTail -eq $WorkspaceTail) {
                return $true
            }

        }
    }
    else {
        $match_found = $false
        $j = 0
        for ($i = 0; $i -lt $workspacePaths.Count; $i++) {
            if ($sourcePaths[$j] -eq $workspacePaths[$i]) {
                $match_found = $true
            }
            else {
                $match_found = $false
                break
            }
            if ($j -lt $sourcePaths.Count - 1) {
                $j++
            }
            else {
                # If we reach the end of workspace paths, check if we matched all source paths
                if ($i -eq $workspacePaths.Count - 1) {
                    $match_found = $true
                }
            }
        }
        if ($match_found) {
            Write-Host "##[debug] Tail path match found: '$SourceTail' matches '$WorkspaceTail'"
            return $true
        }
    }
    return $false
}

function Test-TailPathMatch {
    param([string]$SourceTail, [string]$WorkspaceTail)
   
    Write-Host "##[debug] Testing tail path match: '$SourceTail' against workspace: '$WorkspaceTail'"

    # Check if workspace path ENDS with the source tail
    $sourcePaths = $SourceTail -split '/'
    $workspacePaths = $WorkspaceTail -split '/'

    if ($sourcePaths.Count -eq $workspacePaths.Count) {

        $endsWith = $WorkspaceTail.EndsWith($SourceTail, [System.StringComparison]::OrdinalIgnoreCase)

        if ($endsWith) {
            # If exact match, it's valid
            if ($SourceTail -eq $WorkspaceTail) {
                return $true
            }

        }
    }
    return $false
}

# ===================================================================
# STEP 4: EXECUTE SYNCHRONIZATION PLAN
# ===================================================================

function Invoke-FolderSynchronization {
    param(
        [string]$WorkspaceId,
        [object]$SyncPlan,
        [hashtable]$Headers,
        [object]$WorkspaceStructure,
        [bool]$DeleteOrphanedFolders = $true
    )
   
    Write-Host "##[section]  EXECUTING FOLDER SYNCHRONIZATION"
    Write-Host "=============================================="
   
    $results = @{
        Created = @()
        Deleted = @()
        Updated = @()
        Errors = @()
    }
   
    $folderIdMap = @{}  # Track created folder IDs for parent references
   
    # STEP 1: Create folders (hierarchical creation - parents first)
    if ($SyncPlan.FoldersToCreate.Count -gt 0) {
        Write-Host "##[debug] CREATING FOLDERS HIERARCHICALLY..."
       
        # Build complete folder hierarchy from sync plan
        $folderHierarchy = Build-CompleteFolderHierarchy -FoldersToCreate $SyncPlan.FoldersToCreate
       
        # view the complete hierarchy for debugging
        Write-Host "##[debug] Complete folder hierarchy:"
        Write-Host ($folderHierarchy | ConvertTo-Json -Depth 10)

        # Sort by depth to ensure parents are created before children
        # $sortedHierarchy = $folderHierarchy | Sort-Object Depth

        Write-Host "##[debug] Total folder levels to create: $($folderHierarchy.Count)"

        foreach ($folderLevel in $folderHierarchy) {
            try {
                Write-Host "##[debug] Processing folder level: '$($folderLevel.Name)'"
                Write-Host "##[debug]   Relative Path: $($folderLevel.RelativePath)"
                Write-Host "##[debug]   Parent Path: $($folderLevel.ParentPath)"
                Write-Host "##[debug]   Depth: $($folderLevel.Depth)"
            
                # STEP 1: Check if folder already exists in workspace
                $existingFolder = Find-ExistingWorkspaceFolder -WorkspaceId $WorkspaceId -FolderPath $folderLevel.RelativePath -FolderName $folderLevel.Name -Headers $Headers -WorkspaceStructure $WorkspaceStructure
            
                if ($existingFolder) {
                    Write-Host "##[debug]    EXISTING: Folder '$($folderLevel.Name)' already exists (ID: $($existingFolder.Id))"
                
                    # Add to folder ID map for child folder references
                    $folderIdMap[$folderLevel.RelativePath] = $existingFolder.Id
                    $results.Unchanged += $folderLevel.RelativePath
                
                    Write-Host "##[debug]    Mapped existing folder: '$($folderLevel.RelativePath)' -> ID: $($existingFolder.Id)"
                    continue
                }
            
                # STEP 2: Get parent folder ID if this folder has a parent
                $parentFolderId = $null
                if ($folderLevel.ParentPath -and $folderLevel.ParentPath -ne "") {
                
                    # Check if parent folder ID is already in our map
                    if ($folderIdMap.ContainsKey($folderLevel.ParentPath)) {
                        $parentFolderId = $folderIdMap[$folderLevel.ParentPath]
                        Write-Host "##[debug]    Parent ID from map: $parentFolderId"
                    }
                    else {
                        # Parent not in map - try to find it in existing workspace folders
                        Write-Host "##[debug]    Parent folder ID not in map, searching workspace for: '$($folderLevel.ParentPath)'"
                    
                        $parentFolder = Find-ExistingWorkspaceFolder -WorkspaceId $WorkspaceId -FolderPath $folderLevel.ParentPath -FolderName (Split-Path $folderLevel.ParentPath -Leaf) -Headers $Headers -WorkspaceStructure $WorkspaceStructure
                    
                        if ($parentFolder) {
                            $parentFolderId = $parentFolder.Id
                            $folderIdMap[$folderLevel.ParentPath] = $parentFolderId
                            Write-Host "##[debug]    Found existing parent folder: '$($folderLevel.ParentPath)' (ID: $parentFolderId)"
                        }
                        else {
                            Write-Host "##[warning] Parent folder not found for path: '$($folderLevel.ParentPath)'"
                            Write-Host "##[warning]   This may indicate a dependency issue - parent should be created first"
                        }
                    }
                }
            
                Write-Host "##[debug]    Final Parent ID: $parentFolderId"
            
                # STEP 3: Create the folder if it doesn't exist
                Write-Host "##[debug]    Creating new folder: '$($folderLevel.Name)'"
                $createResult = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName $folderLevel.Name -ParentFolderId $parentFolderId -Headers $Headers

                if ($createResult.Success) {
                    $folderIdMap[$folderLevel.RelativePath] = $createResult.FolderId
                    $results.Created += $folderLevel.RelativePath
                    Write-Host "##[debug]    Created: '$($folderLevel.Name)' (ID: $($createResult.FolderId))"
                } else {
                    $errorMsg = "Failed to create folder '$($folderLevel.Name)' at path '$($folderLevel.RelativePath)': $($createResult.Error)"
                    $results.Errors += $errorMsg
                    Write-Host "##[debug]    Failed: $errorMsg"
                
                    # Don't continue creating child folders if parent failed
                    continue
                }
            }
            catch {
                $error = "Exception creating folder '$($folderLevel.Name)' at path '$($folderLevel.RelativePath)': $($_.Exception.Message)"
                $results.Errors += $error
                Write-Host "##[debug]    Exception: $error"
            }
        }
    }
        
    # STEP 2: Update folders
    if ($SyncPlan.FoldersToUpdate.Count -gt 0) {
        Write-Host "##[debug] UPDATING FOLDERS..."
       
        foreach ($updateItem in $SyncPlan.FoldersToUpdate) {
            try {

                $updateResult = Update-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderId $updateItem.Workspace.Id -NewName $updateItem.Source.Name -Headers $Headers
                
                if ($updateResult.Success) {
                    $results.Updated += $updateItem.Workspace.Path
                    Write-Host "##[debug]   Updated: $($updateItem.Workspace.Path)"
                } else {
                    $results.Errors += "Failed to update $($updateItem.Workspace.Path): $($updateResult.Error)"
                    Write-Host "##[debug]   Failed: $($updateItem.Workspace.Path) - $($updateResult.Error)"
                }

            }
            catch {
                $error = "Exception updating $($updateItem.Workspace.Path): $($_.Exception.Message)"
                $results.Errors += $error
                Write-Host "##[debug]   Exception: $error"
            }
        }
    }
   
    # STEP 3: Delete orphaned folders (optional and dangerous)
    if ($DeleteOrphanedFolders -and $SyncPlan.FoldersToDelete.Count -gt 0) {
        Write-Host "##[debug] DELETING ORPHANED FOLDERS..."
        Write-Host "##[warning] This is a destructive operation!"
       
        # Sort by depth (deepest first to avoid parent dependency issues)
        $sortedFoldersToDelete = $SyncPlan.FoldersToDelete | Sort-Object { $_.Path.Split('/').Count } -Descending
       
        foreach ($folder in $sortedFoldersToDelete) {
            try {
                Write-Host "##[debug]   Deleting folder: $($folder.Path) (ID: $($folder.Id))"
                $deleteResult = Remove-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderId $folder.Id -Headers $Headers
                
                if ($deleteResult.Success) {
                    $results.Deleted += $folder.Path
                    Write-Host "##[debug]   Deleted: $($folder.Path)"
                } else {
                    $results.Errors += "Failed to delete $($folder.Path): $($deleteResult.Error)"
                    Write-Host "##[debug]   Failed: $($folder.Path) - $($deleteResult.Error)"
                }
                
            }
            catch {
                $error = "Exception deleting $($folder.Path): $($_.Exception.Message)"
                $results.Errors += $error
                Write-Host "##[debug]   Exception: $error"
            }
        }
    } elseif ($SyncPlan.FoldersToDelete.Count -gt 0) {
        Write-Host "##[warning] Found $($SyncPlan.FoldersToDelete.Count) orphaned folders, but deletion is disabled"
        Write-Host "##[info] Use -DeleteOrphanedFolders to enable deletion (use with caution!)"
    }
   
    Write-Host ""
    Write-Host "##[section] SYNCHRONIZATION RESULTS"
    Write-Host "====================================="
    Write-Host "Folders CREATED: $($results.Created.Count)"
    Write-Host "Folders UPDATED: $($results.Updated.Count)"
    Write-Host "Folders DELETED: $($results.Deleted.Count)"
    Write-Host "ERRORS: $($results.Errors.Count)"
   
    if ($results.Errors.Count -gt 0) {
        Write-Host ""
        Write-Host "##[error] ERRORS ENCOUNTERED:"
        $results.Errors | ForEach-Object {
            Write-Host "##[error]  - $_"
        }
    }
   
    return $results
}

function Find-ExistingWorkspaceFolder {
    param(
        [string]$WorkspaceId,
        [string]$FolderPath,
        [string]$FolderName,
        [hashtable]$Headers,
        [object]$WorkspaceStructure
    )
   
    Write-Host "##[debug] Searching for existing folder: '$FolderName' at path: '$FolderPath'"
   
    # METHOD 1: Search in workspace structure (from previous API call)
    if ($WorkspaceStructure -and $WorkspaceStructure.FolderHierarchy) {
        foreach ($existingFolder in $WorkspaceStructure.FolderHierarchy) {
           
           Write-Host "##[debug]    Checking existing folder: '$($existingFolder.DisplayName)' at path '$($existingFolder.Path)'"

            # Check exact path match
            if ($existingFolder.Path -eq $FolderPath) {
                Write-Host "##[debug]    Found by exact path match: '$($existingFolder.Path)'"
                return $existingFolder
            }
           
            # Check tail path match
            if (Test-TailPathMatch -SourceTail $FolderPath -WorkspaceTail $existingFolder.Path) {
                if ($existingFolder.DisplayName -eq $FolderName) {
                    Write-Host "##[debug]    Found by tail path match: '$($existingFolder.Path)' matches '$FolderPath'"
                    return $existingFolder
                }
            }
        }
    }
   
    Write-Host "##[debug]    Folder not found: '$FolderName' at '$FolderPath'"
    return $null
}


function Build-CompleteFolderHierarchy {
    param(
        [Array]$FoldersToCreate
    )
   
    Write-Host "##[debug] Building complete folder hierarchy..."
   
    $allFolderLevels = @()
    $processedPaths = @{}
   
    foreach ($folder in $FoldersToCreate) {
        Write-Host "##[debug] Processing folder path: $($folder.Path)"
       
        # Extract relative path from src/fabric onwards
        $relativePath = Get-RelativePathFromSrcFabric -FullPath $folder.Path
       
        if ([string]::IsNullOrEmpty($relativePath)) {
            Write-Host "##[debug]    Skipping - no valid path after 'src/fabric': $($folder.Path)"
            continue
        }
       
        Write-Host "##[debug]  Relative path after 'src/fabric': $relativePath"
       
        # Split the relative path into individual folder components
        $pathParts = $relativePath -split '[/\\]' | Where-Object { $_ -ne "" -and $_ -ne "." }
       
        if ($pathParts.Count -eq 0) {
            Write-Host "##[debug]    Skipping - no valid folder components found"
            continue
        }
       
        Write-Host "##[debug]    Folder components: $($pathParts -join ' -> ')"
       
        # Build hierarchy for each level
        for ($i = 0; $i -lt $pathParts.Count; $i++) {
            
            if ($pathParts.Count -eq 1) {
                $folderName = $pathParts
                $currentPath = $pathParts
            } else {
                $folderName = $pathParts[$i]
                $currentPath = ($pathParts[0..$i] -join '/')
            }

            $parentPath = if ($i -gt 0) { ($pathParts[0..($i-1)] -join '/') } else { "" }
           
            # Skip if we've already processed this path
            if ($processedPaths.ContainsKey($currentPath)) {
                Write-Host "##[debug]   Already processed: $currentPath"
                continue
            }
           
            $folderLevel = @{
                Name = $folderName
                RelativePath = $currentPath
                ParentPath = $parentPath
                Depth = $i + 1
                IsLeaf = ($i -eq ($pathParts.Count - 1))
                OriginalFullPath = $folder.Path
            }
           
            $allFolderLevels += $folderLevel
            $processedPaths[$currentPath] = $true
           
            Write-Host "##[debug]    Level $($folderLevel.Depth): '$($folderLevel.Name)' (Parent: '$($folderLevel.ParentPath)')"
        }
    }
   
    Write-Host "##[debug] Built hierarchy with $($allFolderLevels.Count) folder levels"
   
    return $allFolderLevels
}

function Get-RelativePathFromSrcFabric {
    param(
        [string]$FullPath
    )
   
    if ([string]::IsNullOrEmpty($FullPath)) {
        return ""
    }
   
    Write-Host "##[debug] Extracting relative path from: $FullPath"
   
    # Normalize path separators to forward slashes for consistent processing
    $normalizedPath = $FullPath -replace '\\', '/'
   
    # Find the index of 'src/fabric' in the path (case-insensitive)
    $srcFabricPattern = "src/fabric"
    $srcFabricIndex = $normalizedPath.ToLower().IndexOf($srcFabricPattern.ToLower())
   
    if ($srcFabricIndex -eq -1) {
        Write-Host "##[debug]    'src/fabric' not found in path"
        return ""
    }
   
    # Calculate the start position after 'src/fabric/'
    $startIndex = $srcFabricIndex + $srcFabricPattern.Length
   
    # Handle case where path ends with 'src/fabric' (no trailing content)
    if ($startIndex -ge $normalizedPath.Length) {
        Write-Host "##[debug]    Path ends at 'src/fabric' - no relative path"
        return ""
    }
   
    # Extract everything after 'src/fabric/'
    $relativePath = $normalizedPath.Substring($startIndex)
   
    # Remove leading slashes
    $relativePath = $relativePath.TrimStart('/')
   
    # Remove trailing slashes  
    $relativePath = $relativePath.TrimEnd('/')
   
    Write-Host "##[debug]    Extracted relative path: '$relativePath'"
   
    return $relativePath
}


# ===================================================================
# STEP 5: FABRIC API OPERATIONS
# ===================================================================

function New-WorkspaceFolder {
    param(
        [string]$WorkspaceId,
        [string]$FolderName,
        [string]$ParentFolderId,
        [hashtable]$Headers
    )
   
    try {
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/folders"
       
        $body = @{
            displayName = $FolderName
        }
       
        if ($ParentFolderId) {
            $body.parentFolderId = $ParentFolderId
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method POST -Body $jsonBody
       
        return @{
            Success = $true
            FolderId = $response.id
            Response = $response
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
            FolderId = $null
        }
    }
}

function Update-WorkspaceFolder {
    param(
        [string]$WorkspaceId,
        [string]$FolderId,
        [string]$NewName,
        [hashtable]$Headers
    )
   
    try {
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/folders/$FolderId"
       
        $body = @{
            displayName = $NewName
        } | ConvertTo-Json -Depth 10
       
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method PATCH -Body $body
       
        return @{
            Success = $true
            Response = $response
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Remove-WorkspaceFolder {
    param(
        [string]$WorkspaceId,
        [string]$FolderId,
        [hashtable]$Headers
    )
   
    try {
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/folders/$FolderId"
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method DELETE
       
        return @{
            Success = $true
            Response = $response
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Move-WorkspaceFolder {
    param(
        [string]$WorkspaceId,
        [string]$FolderId,
        [string]$TargetFolderId,
        [hashtable]$Headers
    )
   
    try {
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/folders/$FolderId/move"
       
        $body = @{
            targetFolderId = $TargetFolderId
        } | ConvertTo-Json -Depth 10
       
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method POST -Body $body
       
        return @{
            Success = $true
            Response = $response
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

# ===================================================================
# MAIN EXECUTION
# ===================================================================

function Start-FabricFolderSync {
    param(
        [string]$WorkspaceName,
        [string]$SourceCodePath,
        [bool]$DeleteOrphanedFolders
    )
   
    Write-Host "##[section] FABRIC FOLDER SYNCHRONIZATION SYSTEM"
    Write-Host "==================================================="
    Write-Host "Workspace Name: $WorkspaceName"
    Write-Host "Source Path: $SourceCodePath"
    Write-Host "Delete Orphaned: $DeleteOrphanedFolders"
    Write-Host ""
   
    # Validate inputs
    if (-not (Test-Path $SourceCodePath)) {
        Write-Host "##[error] Source code path does not exist: $SourceCodePath"
        return $false
    }
   
    $fabricToken = Get-FabricAccessToken
    if (-not $fabricToken) {
        Write-Host "##[error] fabric token variable not set"
        return $false
    }
   
    $headers = @{
        'Authorization' = "Bearer $fabricToken"
        'Content-Type' = 'application/json'
    }
   
    try {
        # Step 0: Resolve workspace name to ID
        $workspaceResult = Get-WorkspaceByName -WorkspaceName $WorkspaceName -Headers $headers
       
        # if (-not $workspaceResult.Success) {
        #     Write-Host "##[error] $($workspaceResult.Error)"
        #     return $false
        # }
       
        $workspaceId = $workspaceResult.WorkspaceId
        $actualWorkspaceName = $workspaceResult.WorkspaceName
       
        Write-Host "##[info] Using workspace: '$actualWorkspaceName' (ID: $workspaceId)"
        Write-Host ""
       
        # Step 1: Discover source structure
        $sourceStructure = Get-FabricArtifactsFromSource -BasePath $SourceCodePath
       
        # Step 2: Get workspace structure
        $workspaceStructure = Get-WorkspaceFolders -WorkspaceId $WorkspaceId -Headers $headers
       
        # display workspace structure json for debugging
        Write-Host "##[debug] Workspace structure:"
        Write-Host ($workspaceStructure | ConvertTo-Json -Depth 10)
        
        # Step 3: Compare and plan
        $syncPlan = Compare-FolderStructures -SourceStructure $sourceStructure -WorkspaceStructure $workspaceStructure
       
        # Step 4: Execute synchronization
        $syncResults = Invoke-FolderSynchronization -WorkspaceId $WorkspaceId -SyncPlan $syncPlan -Headers $headers -WorkspaceStructure $workspaceStructure -DeleteOrphanedFolders $DeleteOrphanedFolders
       
        # Step 5: Generate report
        Write-Host "##[section] FINAL SUMMARY"
        Write-Host "==========================="
        Write-Host " Synchronization completed successfully"
        Write-Host " Workspace: '$actualWorkspaceName' (ID: $workspaceId)"
       
        return $true
       
    } catch {
        Write-Host "##[error] Synchronization failed: $($_.Exception.Message)"
        Write-Host "##[error]Stack trace: $($_.ScriptStackTrace)"
        return $false
    }
}

# Execute the synchronization
try {

    $success = Start-FabricFolderSync -WorkspaceName $WorkspaceName -SourceCodePath $SourceCodePath -DeleteOrphanedFolders $DeleteOrphanedFolders
   
    if ($success) {
        Write-Host "##[section] FOLDER SYNCHRONIZATION COMPLETED SUCCESSFULLY!"
    } else {
        Write-Host "##[section] FOLDER SYNCHRONIZATION FAILED!"
        exit 1
    }

    $fabricToken = Get-FabricAccessToken
    if (-not $fabricToken) {
        Write-Host "##[error] faric token variable not set"
        return $false
    }
   
    $headers = @{
        'Authorization' = "Bearer $fabricToken"
        'Content-Type' = 'application/json'
    }

    $workspaceResult = Get-WorkspaceByName -WorkspaceName $WorkspaceName -Headers $headers
    
    if (-not $workspaceResult.Success) {
        Write-Host "##[error] $($workspaceResult.Error)"
        return $false
    }
    
    $workspaceId = $workspaceResult.WorkspaceId
    $workspaceStructure = Get-WorkspaceFolders -WorkspaceId $WorkspaceId -Headers $headers

    $folderHierarchy = ($($workspaceStructure.FolderHierarchy) | ConvertTo-Json -Depth 10 -Compress)

    return $folderHierarchy

} catch {
    Write-Host "##[error] Critical error: $($_.Exception.Message)"
    exit 1
}