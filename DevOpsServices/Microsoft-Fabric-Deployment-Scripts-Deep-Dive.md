# Microsoft Fabric Deployment Scripts: Deep Dive

---

## Table of Contents

### Architecture Foundation
1. [Script Architecture Overview](#script-architecture-overview)
2. [Common Patterns & Principles](#common-patterns-and-principles)

### Core Deployment Scripts
3. [Script 1: Fabric Workspace - Create-Workspace.ps1](#script-1-create-workspace-ps1)
4. [Script 2: Fabric Workspace - Assign-Capacity-To-Workspace.ps1](#script-2-assign-capacity-to-workspace-ps1)
5. [Script 3: Deploy Fabric Role Assignments - Set-FabricWorkspaceRoleAssignments.ps1](#script-3-set-fabricworkspaceroleassignments-ps1)
6. [Script 4: Fabric Folder Synchronization - Fabric-FolderSynchronization.ps1](#script-4-fabric-foldersynchronization-ps1)
7. [Script 5: Create Fabric Environment and Configure Spark Settings - Invoke-EnvironmentManagement.ps1](#script-5-invoke-environmentmanagement-ps1)
8. [Script 6: Create Fabric Environment and Configure Spark Settings - Invoke-SparkEnvironmentSettings.ps1](#script-6-invoke-sparkenvironmentsettings-ps1)
9. [Script 7: Update Fabric Spark Settings - Update-FabricSparkSettings.ps1](#script-7-update-fabricsparksettings-ps1)
10. [Script 8: Create Fabric Lakehouses - Invoke-LakehouseManagement.ps1](#script-8-invoke-lakehousemanagement-ps1)
11. [Script 9: Upload Monitoring/metadate Workspace Files - Fabric-LakehouseUpload.ps1](#script-9-fabric-lakehouseupload-ps1)
12. [Script 10: Create Fabric Lakehouse Shortcuts - Deploy-LakehouseShortcuts.ps1](#script-10-deploy-lakehouseshortcuts-ps1)
13. [Script 11: Create and Update Fabric Notebooks - Update-NotebookDependencies.ps1](#script-11-update-notebookdependencies-ps1)
14. [Script 12: Create and Update Fabric Notebooks - Invoke-NotebookManagement.ps1](#script-12-invoke-notebookmanagement-ps1)
15. [Script 13: Handle Private Endpoint Approvals - Handle-PrivateEndpointApprovals.ps1](#script-13-handle-privateendpointapprovals-ps1)
16. [Script 14: Fabric Data Pipelines Configuration - Setup-FabricDataPipelines.ps1](#script-14-setup-fabricdatapipelines-ps1)
17. [Script 15: Configure and Deploy Semantic Models - Deploy-FabricSemanticModels.ps1](#script-15-deploy-fabricsemanticmodels-ps1)
18. [Script 16: Configure and Deploy Reports - Deploy-FabricReports.ps1](#script-16-deploy-fabricreports-ps1)
19. [Script 17: Git Connect and Sync - Fabric-GitOperations.ps1](#script-17-fabric-gitoperations-ps1)

### Integration & Advanced Topics
20. [Cross-Script Integration Patterns](#cross-script-integration-patterns)
21. [Error Handling Philosophy](#error-handling-philosophy)
22. [Performance Optimization](#performance-optimization)
23. [Script Extensibility](#script-extensibility)
24. [Security Considerations](#security-considerations)

---

## Script Architecture Overview

The deployment pipeline relies on a collection of PowerShell scripts that act as abstraction layers over the Fabric REST API. Each script follows a consistent architectural pattern:

### Standard Script Structure

```powershell
# 1. AUTHENTICATION FUNCTIONS
function Get-FabricAccessToken {
    # Retrieve Fabric API tokens using Azure CLI and service principal credentials
}

# 2. API WRAPPER FUNCTIONS
function Invoke-FabricApiWithRetry {
    # Encapsulate REST API calls with retry logic and error handling
}

# 3. BUSINESS LOGIC FUNCTIONS
function Create-Resource {
    # Implement deployment patterns (create-or-update, synchronization, etc.)
}

# 4. MAIN EXECUTION BLOCK
try {
    # Orchestrate function calls and handle success/failure scenarios
    $token = Get-FabricAccessToken
    $result = Create-Resource -Token $token
    return $result | ConvertTo-Json
}
catch {
    Write-Error "Deployment failed: $_"
    exit 1
}
```

This architecture enables:
- **Idempotency**: Scripts can be run multiple times safely
- **Resilience**: Automatic retries for transient failures
- **Observability**: Detailed logging at every step

---

## Common Patterns and Principles

### 1. Authentication Pattern

Every script uses the same authentication approach:

```powershell
function Get-FabricAccessToken {
    # Authenticate to Azure using service principal
    $clientId = $env:ARM_CLIENT_ID
    $clientSecret = $env:ARM_CLIENT_SECRET
    $tenantId = $env:ARM_TENANT_ID
    
    az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId
    
    # Get Fabric API token
    $token = az account get-access-token --resource https://api.fabric.microsoft.com/ --query accessToken --output tsv
    
    return $token.Trim()
}
```

**Why Azure CLI?**
- Simpler than PowerShell Az modules for authentication
- Service principal credentials from environment variables
- Returns bearer token for Fabric API authentication

### 2. CreateOrUpdate Pattern

All resource management scripts implement idempotent create-or-update logic:

```powershell
switch ($Action) {
    "createorupdate" {
        # 1. Look up resource by name
        $existingResourceId = Get-ResourceIdByName -Name $DisplayName
        
        if ($null -eq $existingResourceId) {
            # 2a. Resource doesn't exist → Create
            $result = Create-Resource -DisplayName $DisplayName -Config $Config
            Write-Host "##[section]Created: $DisplayName"
        } else {
            # 2b. Resource exists → Update properties
            $result = Update-Resource -ResourceId $existingResourceId -Config $Config
            Write-Host "##[section]Updated: $DisplayName"
            
            # 3. Check folder placement
            $currentFolderId = Get-ResourceCurrentFolder -ResourceId $existingResourceId
            
            # 4. Move if needed
            if ($currentFolderId -ne $targetFolderId) {
                Move-ResourceToFolder -ResourceId $existingResourceId -TargetFolderId $targetFolderId
                Write-Host "##[debug]Moved: $DisplayName to correct folder"
            }
        }
        
        return $result | ConvertTo-Json
    }
}
```

### 3. Retry Logic with Exponential Backoff

All API calls include retry logic to handle transient failures:

```powershell
function Invoke-FabricApiWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method,
        [string]$Body = $null,
        [int]$MaxRetries = 3,
        [int]$BaseRetryDelaySeconds = 30
    )
    
    $attempt = 1
    
    while ($attempt -le $MaxRetries) {
        try {
            Write-Host "##[debug]API call attempt $attempt of $MaxRetries to: $Uri"
            
            $requestParams = @{
                Uri = $Uri
                Headers = $Headers
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
            
            # Try to get the response body if available
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
            
            # Check if this is a RequestBlocked error (Fabric API rate limiting)
            if ($errorResponse -and $errorResponse.Contains('"errorCode":"RequestBlocked"')) {
                Write-Host "##[warning]Request blocked by upstream service. Error response: $errorResponse"
                
                if ($attempt -eq $MaxRetries) {
                    Write-Error "Max retries reached. Request still blocked. Last error: $errorResponse"
                    throw "Max retries reached for blocked request: $_"
                }
                
                # Use exponential backoff for blocked requests
                $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
                Write-Host "##[debug]Request blocked, using exponential backoff: $retryDelay seconds"
                Start-Sleep -Seconds $retryDelay
                
                $attempt++
                continue
            }
            
            # For non-RequestBlocked errors, use standard retry logic
            if ($attempt -eq $MaxRetries) {
                Write-Error "API call failed after $MaxRetries attempts. Last error: $_"
                if ($errorResponse) {
                    Write-Error "Response body: $errorResponse"
                }
                throw "API call failed after $MaxRetries attempts: $_"
            }
            
            # Exponential backoff for other errors
            $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Host "##[warning]API call failed (attempt $attempt), retrying in $retryDelay seconds. Error: $_"
            Start-Sleep -Seconds $retryDelay
            $attempt++
        }
    }
}
```

**Retry Schedule:**
- Attempt 1 fails → wait 30 seconds
- Attempt 2 fails → wait 60 seconds (30 × 2¹)
- Attempt 3 fails → wait 120 seconds (30 × 2²)
- **Total retry time**: 210 seconds (3.5 minutes) before failure

**Why exponential backoff?**
- Fabric API implements rate limiting to protect backend services
- RequestBlocked errors indicate temporary throttling
- Exponential backoff reduces load while waiting for rate limits to reset

### 4. Structured Logging

All scripts use Azure DevOps logging commands for better observability:

```powershell
Write-Host "##[section]Creating Lakehouse"    # Major section header
Write-Host "##[debug]Lakehouse ID: $id"       # Debug details (collapsible)
Write-Host "##[warning]Lakehouse exists"      # Warning (yellow indicator)
Write-Host "##[error]Creation failed"         # Error (red indicator)
```

**Benefits:**
- Structured logs in Azure DevOps UI
- Automatic error/warning counts in pipeline summary
- Debug details collapsed by default (cleaner logs)
- Section markers create collapsible log groups

---

## Script 1 Create-Workspace-ps1

### Purpose
Creates a new Fabric workspace or validates that an existing workspace exists. Returns a hashtable mapping workspace name to workspace ID.

### Key Functions

#### Get-FabricAccessToken
```powershell
function Get-FabricAccessToken {
    # Authenticate to Azure using service principal
    az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId
    
    # Get Fabric API token
    az account get-access-token --resource https://api.fabric.microsoft.com/ --query accessToken --output tsv
}
```

- Uses Azure CLI for authentication (not PowerShell modules) for simplicity
- Service principal credentials come from environment variables (ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID)
- Returns bearer token for Fabric API authentication

#### Get-WorkspaceIdByName
```powershell
function Get-WorkspaceIdByName {
    # Query: GET https://api.fabric.microsoft.com/v1/workspaces
    # Filter: Where displayName equals workspace name
    # Return: Workspace ID or null
}
```

- Lists all workspaces the service principal has access to
- Performs client-side filtering by display name
- Returns `$null` if workspace not found

#### Create-Workspace
```powershell
function Create-Workspace {
    # POST https://api.fabric.microsoft.com/v1/workspaces
    # Body: { "displayName": "WorkspaceName" }
    # Return: Workspace object with ID
}
```

- Creates workspace with minimal configuration (display name only)
- Capacity assignment happens in a separate script
- Returns hashtable: `@{ "WorkspaceName" = "workspace-guid" }`

### Execution Flow

```
1. Authenticate → Get Fabric token
2. Check existence → GET /workspaces, filter by name
3. Decision point:
   - If $EnsureWorkspaceExists = $true AND workspace not found → ERROR (fail pipeline)
   - If workspace not found → Create new workspace
   - If workspace exists → Return existing workspace ID
4. Return hashtable with workspace name → ID mapping
```

### Usage in Pipeline

```yaml
- task: PowerShell@2
  inputs:
    script: |
      $WorkspaceName = $env:TF_VAR_workspace_names.Trim('[', ']').Trim('"')
      $EnsureWorkspaceExists = if ("$(isDefault)" -eq "true") { $false } else { $true }
      
      $scriptPath = "$(System.DefaultWorkingDirectory)/DevOpsServices/pipelines/scripts/Create-Workspace.ps1"
      $WorkspaceNames = & $scriptPath -WorkspaceName "$WorkspaceName" -EnsureWorkspaceExists $EnsureWorkspaceExists
      
      # Store for downstream tasks
      Write-Host "##vso[task.setvariable variable=WORKSPACE_IDS]$($WorkspaceNames | ConvertTo-Json -Compress)"
```

### Key Insight: Deployment Modes

The `$EnsureWorkspaceExists` flag implements different deployment modes:

- **Default mode** (`isDefault = true`): Creates workspace if missing (full deployment)
- **Selective mode** (`isDefault = false`): Requires workspace to pre-exist (prevents accidental workspace creation during targeted updates)

---

## Script 2 Assign-Capacity-To-Workspace-ps1

### Purpose
Assigns a Fabric capacity to a workspace. Workspaces must be assigned to a capacity before items can be created.

### Key Function

#### Assign-Capacity-To-Workspace
```powershell
function Assign-Capacity-To-Workspace {
    param([string]$WorkspaceId, [string]$CapacityId, [string]$Token)
    
    # POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/assignToCapacity
    # Body: { "capacityId": "capacity-guid" }
}
```

### Architecture Decision

**Why separate script?**
- Workspace creation and capacity assignment are atomic operations in the API
- If capacity assignment fails, the workspace still exists but is unusable
- Separating allows for clearer error handling and retry logic

### Capacity Validation Pattern

Before calling this script, the pipeline validates capacity state:

```yaml
- task: PowerShell@2
  inputs:
    script: |
      $scriptPath = "$(System.DefaultWorkingDirectory)/DevOpsServices/pipelines/scripts/Fabric-CapacityState.ps1"
      & $scriptPath
      if ($LASTEXITCODE -ne 0) {
        Write-Error "Fabric Capacity is not active"
        exit 1
      }
```

This prevents failed deployments due to paused or deallocated capacities.

---

## Script 3 Set-FabricWorkspaceRoleAssignments-ps1

### Purpose
Implements desired-state configuration for workspace role assignments. Synchronizes actual role assignments to match declared configuration.

### Key Functions

#### Get-WorkspaceRoleAssignments
```powershell
function Get-WorkspaceRoleAssignments {
    # GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/roleAssignments
    # Returns array of existing assignments with structure:
    # [
    #   { principal: { id: "guid", type: "Group" }, role: "Admin" },
    #   { principal: { id: "guid", type: "User" }, role: "Viewer" }
    # ]
}
```

#### Add-WorkspaceRoleAssignment
```powershell
function Add-WorkspaceRoleAssignment {
    param([string]$PrincipalId, [string]$PrincipalType, [string]$Role)
    
    # POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/roleAssignments
    # Body: {
    #   "principal": { "id": "...", "type": "Group|User|ServicePrincipal" },
    #   "role": "Admin|Member|Contributor|Viewer"
    # }
    
    # Handles 409 Conflict (assignment already exists) gracefully
}
```

#### Sync-WorkspaceRoleAssignments
```powershell
function Sync-WorkspaceRoleAssignments {
    param([hashtable]$DesiredState, [bool]$RemoveUnmanaged)
    
    # 1. Get current assignments from Fabric
    # 2. Add missing assignments from desired state
    # 3. Optionally remove unmanaged assignments (only in PRD environment)
}
```

### Desired State Configuration Pattern

The script uses a declarative approach:

```powershell
$desiredState = @{
    "admins-group" = @{
        PrincipalIds = @("group-guid-1", "group-guid-2")
        PrincipalType = "Group"
        Role = "Admin"
    }
    "viewers-group" = @{
        PrincipalIds = @("group-guid-3")
        PrincipalType = "Group"
        Role = "Viewer"
    }
    "admins-sp" = @{
        PrincipalIds = @("sp-guid-1")
        PrincipalType = "ServicePrincipal"
        Role = "Admin"
    }
}

$syncResult = Sync-WorkspaceRoleAssignments -DesiredState $desiredState -RemoveUnmanaged $true
```

**Benefits:**
- **Idempotent**: Running multiple times produces same result
- **Self-healing**: Automatically corrects drift (manual changes are reverted)
- **Auditable**: All changes logged with before/after state

### Production Safety Feature

```powershell
if ($RemoveUnmanaged -and $ENVIRONMENT -eq "PRD") {
    # Only remove unmanaged assignments in production
    # Dev/Test environments allow manual role additions
}
```

This prevents disruption in lower environments while enforcing strict governance in production.

---

## Script 4 Fabric-FolderSynchronization-ps1

### Purpose
Synchronizes folder structure from Git repository (`src/fabric/`) to Fabric workspace. Creates hierarchical folder organization for notebooks, semantic models, reports, etc.

### Architecture: Five-Phase Synchronization

#### Phase 1: Discovery

```powershell
function Get-FabricArtifactsFromSource {
    # Scan src/fabric/ directory for artifact folders
    # Supported types: SemanticModel, Report, Lakehouse, Notebook, Environment, etc.
    # For each artifact:
    #   - Read .platform file for metadata
    #   - Extract folder path relative to src/fabric
    #   - Build folder hierarchy map
}
```

**Example directory structure:**
```
src/fabric/
├── data/
│   ├── raw/
│   │   └── raw_lakehouse.Lakehouse/
│   │       └── .platform
│   └── curated/
│       └── curated_lakehouse.Lakehouse/
│           └── .platform
└── reports/
    └── sales_report.Report/
        └── .platform
```

**Discovered folders:** `["data/raw", "data/curated", "reports"]`

#### Phase 2: Get Current State

```powershell
function Get-WorkspaceFolders {
    # GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/folders
    # Build folder hierarchy with parent-child relationships
    # Calculate full paths by walking up parent chain
}
```

#### Phase 3: Compare & Plan

```powershell
function Compare-FolderStructures {
    # Create sets: SourceFolders, WorkspaceFolders
    # FoldersToCreate = SourceFolders - WorkspaceFolders
    # FoldersToDelete = WorkspaceFolders - SourceFolders (if DeleteOrphanedFolders enabled)
    # Implements **tail path matching** for flexibility
}
```

**Tail Path Matching Logic:**
```powershell
# Source path: "data/raw"
# Workspace path: "platform/data/raw"
# Match: TRUE (workspace path ends with source path)

function Test-TailPathMatch {
    param([string]$SourceTail, [string]$WorkspaceTail)
    
    # Split paths into components
    $sourcePaths = $SourceTail -split '/'
    $workspacePaths = $WorkspaceTail -split '/'
    
    # Check if workspace path ends with all source path components
    if ($sourcePaths.Count -eq $workspacePaths.Count) {
        return $WorkspaceTail.EndsWith($SourceTail, [StringComparison]::OrdinalIgnoreCase)
    }
    
    # Complex matching logic for partial paths
}
```

This allows flexibility when repository structure doesn't exactly match workspace structure.

#### Phase 4: Build Complete Hierarchy

```powershell
function Build-CompleteFolderHierarchy {
    # For each folder to create:
    #   Extract path components: "data/raw/archives" → ["data", "raw", "archives"]
    #   Create intermediate folders: 
    #     - "data" (depth 1, parent: root)
    #     - "data/raw" (depth 2, parent: "data")
    #     - "data/raw/archives" (depth 3, parent: "data/raw")
}
```

This ensures parent folders are created before children, avoiding API errors.

#### Phase 5: Execute Synchronization

```powershell
function Invoke-FolderSynchronization {
    # Sort folders by depth (parents first)
    foreach ($folder in $sortedFolders) {
        # Check if folder already exists
        $existing = Find-ExistingWorkspaceFolder -FolderPath $folder.RelativePath
        
        if ($existing) {
            # Add to ID map for child folder references
            $folderIdMap[$folder.RelativePath] = $existing.Id
        } else {
            # Get parent folder ID from map
            $parentId = $folderIdMap[$folder.ParentPath]
            
            # Create folder
            New-WorkspaceFolder -FolderName $folder.Name -ParentFolderId $parentId
            
            # Add to ID map
            $folderIdMap[$folder.RelativePath] = $newFolderId
        }
    }
}
```

### Return Value

The script returns a JSON-serialized folder hierarchy that subsequent deployment steps use to place items in correct folders:

```json
[
  {
    "Id": "folder-guid-1",
    "DisplayName": "data",
    "Path": "data",
    "ParentFolderId": null
  },
  {
    "Id": "folder-guid-2",
    "DisplayName": "raw",
    "Path": "data/raw",
    "ParentFolderId": "folder-guid-1"
  }
]
```

This mapping is stored in the `FOLDER_HIERARCHY` pipeline variable for use by notebook, lakehouse, and semantic model deployment scripts.

---

## Script 5 Invoke-EnvironmentManagement-ps1

### Purpose
Creates or updates Fabric environments (Spark runtime configurations). Supports folder placement and handles environment state transitions.

### Key Functions

#### Get-EnvironmentIdByName
```powershell
function Get-EnvironmentIdByName {
    # GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/environments
    # Filter by displayName
    # Return environment ID or $null
}
```

#### Create-Environment
```powershell
function Create-Environment {
    param([string]$WorkspaceId, [string]$DisplayName, [string]$FolderId)
    
    # POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/environments
    # Body: {
    #   "displayName": "Python Runtime Environment",
    #   "folderId": "folder-guid" (optional)
    # }
}
```

#### Move-EnvironmentToFolder
```powershell
function Move-EnvironmentToFolder {
    # POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items/{environmentId}/move
    # Body: { "targetFolderId": "folder-guid" }
}
```

### CreateOrUpdate Pattern

The script implements smart create-or-update logic:

```powershell
switch ($Action) {
    "createorupdate" {
        # 1. Try to find environment by name
        $existingEnvironmentId = Get-EnvironmentIdByName -Name $DisplayName
        
        if ($null -eq $existingEnvironmentId) {
            # 2a. Environment doesn't exist → Create
            $result = Create-Environment -DisplayName $DisplayName -FolderId $folderId
            return $result | ConvertTo-Json
        } else {
            # 2b. Environment exists → Update properties
            $result = Update-Environment -EnvironmentId $existingEnvironmentId -DisplayName $DisplayName
            
            # 3. Check if environment is in correct folder
            $currentFolderId = Get-EnvironmentCurrentFolder -EnvironmentId $existingEnvironmentId
            
            if ($currentFolderId -ne $folderId) {
                # 4. Move to correct folder if needed
                Move-EnvironmentToFolder -EnvironmentId $existingEnvironmentId -TargetFolderId $folderId
            }
            
            return $result | ConvertTo-Json
        }
    }
}
```

---

## Script 6 Invoke-SparkEnvironmentSettings-ps1

### Purpose
Configures Spark compute settings for an environment (driver/executor resources, autoscaling, runtime version).

### Spark Configuration API

#### Set-SparkEnvironmentSettings
```powershell
function Set-SparkEnvironmentSettings {
    # PATCH https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/environments/{environmentId}/staging/sparkcompute
    # Body: {
    #   "driverCores": 4,
    #   "driverMemory": "28g",
    #   "executorCores": 4,
    #   "executorMemory": "28g",
    #   "runtimeVersion": "1.3",
    #   "dynamicExecutorAllocation": {
    #     "enabled": true,
    #     "minExecutors": 1,
    #     "maxExecutors": 3
    #   }
    # }
}
```

### Staging vs. Published State

Fabric environments have two states:
- **Staging**: Work-in-progress configuration
- **Published**: Active configuration used by notebooks

The script updates staging state. The environment must be published separately to activate changes (this happens automatically when notebooks attach to the environment).

### Compute Settings Explained

**Driver Resources:**
- Driver node runs the Spark driver process (orchestrates executors)
- Typically requires less memory than executors
- Example: 4 cores, 28GB RAM

**Executor Resources:**
- Executor nodes run Spark tasks (data processing)
- Should match data processing workload
- Example: 4 cores, 28GB RAM per executor

**Dynamic Executor Allocation:**
- `enabled: true` → Spark automatically scales executors based on workload
- `minExecutors`: Minimum always-on executors (for responsiveness)
- `maxExecutors`: Maximum concurrent executors (cost control)

**Runtime Version:**
- Specifies Spark version: "1.2" (Spark 3.3), "1.3" (Spark 3.4), etc.
- Different versions support different Python/Scala library versions

### Pipeline Usage Pattern

The pipeline calls this script twice:

**Main environment configuration:**
```yaml
- task: PowerShell@2
  inputs:
    script: |
      $scriptPath = "Invoke-SparkEnvironmentSettings.ps1"
      & $scriptPath -WorkspaceId $WorkspaceId -EnvironmentName $environmentDisplayName `
        -DriverCores $sparkSettings.driver_cores `
        -DriverMemory $sparkSettings.driver_memory `
        -ExecutorCores $sparkSettings.executor_cores `
        -ExecutorMemory $sparkSettings.executor_memory `
        -RuntimeVersion $sparkSettings.runtime_version `
        -MinExecutors $sparkSettings.min_executors `
        -MaxExecutors $sparkSettings.max_executors
```

**Subdomain environment configuration:**
```powershell
foreach ($env in $createdEnvironments) {
    & $sparkScriptPath -WorkspaceId $env.WorkspaceId -EnvironmentName $env.DisplayName <same params>
}
```

This ensures both main and subdomain environments have consistent Spark configurations.

---

## Script 7 Update-FabricSparkSettings-ps1

### Purpose
Configures workspace-level Spark settings (default environment, high concurrency mode, automatic logging).

### Workspace vs. Environment Settings

**Key Distinction:**
- **Environment settings** (Script 6): Apply to specific environment (driver/executor resources)
- **Workspace settings** (Script 7): Apply to all notebooks in workspace (default environment, concurrency mode)

### Update-SparkSettings

```powershell
function Update-SparkSettings {
    # PATCH https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/spark/settings
    # Body: {
    #   "automaticLog": { "enabled": true },
    #   "highConcurrency": {
    #     "notebookInteractiveRunEnabled": false,
    #     "notebookPipelineRunEnabled": true
    #   },
    #   "environment": {
    #     "name": "Python Runtime Environment",
    #     "runtimeVersion": "1.3"
    #   }
    # }
}
```

### Settings Explained

**automaticLog.enabled:**
- When true, Fabric automatically captures Spark logs for all notebook runs
- Logs stored in workspace storage account
- Used for debugging and auditing

**highConcurrency.notebookInteractiveRunEnabled:**
- When true, multiple users can run notebooks concurrently on shared Spark sessions
- Reduces resource usage but may cause conflicts
- Typically disabled for production workspaces

**highConcurrency.notebookPipelineRunEnabled:**
- When true, data pipeline notebook activities can run concurrently
- Essential for parallel pipeline execution
- Typically enabled for production orchestration

**environment.name:**
- Sets the default environment for all new notebooks in workspace
- Notebooks without explicit environment binding use this default
- Should point to main Python runtime environment

### Pipeline Context

This script runs after environment creation:

```yaml
# Create main environment
Invoke-EnvironmentManagement.ps1 -Action CreateOrUpdate -DisplayName "Python Runtime"

# Configure environment Spark settings
Invoke-SparkEnvironmentSettings.ps1 -EnvironmentName "Python Runtime" <params>

# Set workspace default to this environment
Update-FabricSparkSettings.ps1 -EnvironmentName "Python Runtime" -RuntimeVersion "1.3"
```

**Result**: New notebooks automatically use "Python Runtime" environment with specified compute settings.

---

## Script 8 Invoke-LakehouseManagement-ps1

### Purpose
Creates or updates Fabric lakehouses with schema support and folder placement. Implements same CreateOrUpdate pattern as environment management.

### Key Functions

#### Create-Lakehouse
```powershell
function Create-Lakehouse {
    param([string]$DisplayName, [bool]$EnableSchemas, [string]$FolderId)
    
    # POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/lakehouses
    # Body: {
    #   "displayName": "raw_lakehouse",
    #   "creationPayload": {
    #     "enableSchemas": true
    #   },
    #   "folderId": "folder-guid" (optional)
    # }
}
```

#### Get-LakehouseIdByName
```powershell
function Get-LakehouseIdByName {
    # GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/lakehouses
    # Filter by displayName
    # Return lakehouse ID or $null
}
```

### Schema Support

`enableSchemas` parameter controls lakehouse schema support:

**When true (default):**
- Lakehouse supports database schemas (multi-level namespacing)
- Tables organized as: `schemaName.tableName`
- Example: `sales.customers`, `sales.orders`, `hr.employees`
- Benefits: Better organization, access control per schema

**When false:**
- Lakehouse uses flat namespace
- All tables at root level: `customers`, `orders`, `employees`
- Legacy mode for backward compatibility

### CreateOrUpdate with Folder Movement

```powershell
"createorupdate" {
    # 1. Look up lakehouse by name
    $existingLakehouseId = Get-LakehouseIdByName -Name $DisplayName
    
    if ($null -eq $existingLakehouseId) {
        # 2a. Create new lakehouse in target folder
        $result = Create-Lakehouse -DisplayName $DisplayName -EnableSchemas $true -FolderId $folderId
    } else {
        # 2b. Update existing lakehouse properties
        $result = Update-Lakehouse -LakehouseId $existingLakehouseId -DisplayName $DisplayName
        
        # 3. Check folder placement
        $currentFolderId = Get-LakehouseCurrentFolder -LakehouseId $existingLakehouseId
        
        # 4. Move if needed
        if ($currentFolderId -ne $folderId) {
            Move-LakehouseToFolder -LakehouseId $existingLakehouseId -TargetFolderId $folderId
        }
    }
    
    return $result | ConvertTo-Json
}
```

### State File Creation

The pipeline saves lakehouse IDs to disk for state tracking:

```yaml
- task: PowerShell@2
  inputs:
    script: |
      $lakehouseResult = Invoke-LakehouseManagement.ps1 -Action CreateOrUpdate -DisplayName "raw_lakehouse"
      
      # Extract lakehouse ID from result
      $lakehouseId = ($lakehouseResult | ConvertFrom-Json).id
      
      # Create state file
      $fileKey = "${WorkspaceName}-${lakehouseDisplayName}".Replace("-", "_")
      $stateFile = "$workingDirectory/.terraform/lakehouse_${fileKey}_id.txt"
      Set-Content -Path $stateFile -Value $lakehouseId -NoNewline
```

**Why state files?**
- Terraform originally managed lakehouses, creating state files
- When migrating to PowerShell scripts, state file pattern maintained for backward compatibility
- Allows gradual migration from Terraform to PowerShell without breaking dependencies
- Other scripts can read lakehouse IDs from state files without API calls

---

## Script 9 Fabric-LakehouseUpload-ps1

### Purpose
Uploads files from local repository to Microsoft Fabric lakehouse using OneLake storage API. Enables data ingestion from Git-managed datasets.

### OneLake Architecture

**What is OneLake?**
- OneLake is Microsoft Fabric's **unified data lake**
- Every Fabric workspace gets its own OneLake storage
- Lakehouses store data in OneLake using Azure Data Lake Gen2 format
- Accessible via ADLS Gen2 APIs using workspace ID as filesystem

**Storage Path Pattern:**
```
onelake.dfs.fabric.microsoft.com/{workspaceId}/{lakehouseId}/Files/{path}
```

### Key Functions

#### Azure-Login
```powershell
function Azure-Login {
    param($TenantId, $ClientId, $ClientSecret)
    
    # Create secure credential
    $securePassword = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $credential = New-Object PSCredential($ClientId, $securePassword)
    
    # Connect to Azure using service principal
    Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $credential
}
```

**Why Az modules?**
- OneLake uses ADLS Gen2 protocol
- `Az.Storage` module provides native ADLS Gen2 cmdlets
- More reliable than REST API for file uploads
- Handles chunking, retries, and progress tracking automatically

#### Upload-Files
```powershell
function Upload-Files {
    param([string]$LakehouseId, [string]$WorkspaceId, [string]$LocalPath, [string]$RemotePath)
    
    # Create OneLake storage context
    $StorageCtx = New-AzStorageContext -StorageAccountName 'onelake' -UseConnectedAccount -endpoint 'fabric.microsoft.com'
    
    # Get all files recursively, excluding .gitkeep
    $DirList = Get-ChildItem -Path $LocalPath -Recurse -File | Where-Object { $_.name -ne '.gitkeep'}
    
    foreach ($file in $DirList) {
        # Calculate relative path
        $relativePath = (Resolve-Path -Relative -Path $file.FullName -RelativeBasePath $LocalPath).Substring(2)
        
        # Construct OneLake path: {lakehouseId}{remotePath}/{relativePath}
        $uploadPath = "$LakehouseId$RemotePath/$relativePath"
        
        # Upload to OneLake
        New-AzDataLakeGen2Item -Context $StorageCtx -FileSystem $WorkspaceId -Path $uploadPath -Source $file.FullName -Force
    }
}
```

### OneLake Path Construction

**Pattern Breakdown:**
```powershell
# Local path: ../../../src/metadata/templates/template1.json
# LocalPath: ../../../src/metadata
# RemotePath: /Files/templates
# LakehouseId: abc-123-def-456

# Relative path calculation:
$relativePath = "templates/template1.json"

# Final OneLake path:
$uploadPath = "abc-123-def-456/Files/templates/templates/template1.json"
```

**Why `/Files/` prefix?**
- Lakehouse storage has two top-level folders: `Files` and `Tables`
- `Files`: Raw data storage (unstructured)
- `Tables`: Delta Lake tables (structured)
- This script targets `Files` for raw data ingestion

### Pipeline Usage

```yaml
- task: PowerShell@2
  displayName: 'Upload Metadata Templates'
  inputs:
    script: |
      $env:LAKEHOUSE_NAME = "metadata"
      $env:SOURCE_PATH = "src/metadata/templates"
      $env:TARGET_PATH = "templates"
      
      & "$(System.DefaultWorkingDirectory)/DevOpsServices/pipelines/scripts/Fabric-LakehouseUpload.ps1"
```

**Use Cases:**
- Upload BPA (Best Practice Analyzer) rules
- Upload metadata configuration files
- Upload data quality rules
- Upload reference data

### Optimization: Parallel Uploads

**Current Implementation**: Sequential uploads

**Optimization Opportunity:**
```powershell
# Potential improvement (not implemented):
$DirList | ForEach-Object -Parallel {
    $file = $_
    # Upload logic
} -ThrottleLimit 5
```

**Trade-off**: Increased complexity vs. faster uploads for large datasets

---

## Script 10 Deploy-LakehouseShortcuts-ps1

### Purpose
Creates lakehouse shortcuts enabling cross-workspace and cross-lakehouse data access without duplication.

### Lakehouse Shortcuts Explained

**What are shortcuts?**
- Pointers to data in other lakehouses or storage accounts
- Enable data virtualization (no copying)
- Support OneLake-to-OneLake and OneLake-to-ADLS shortcuts
- Changes in source immediately visible in consumer

**Architecture:**
```
Workspace A (Raw Data)
└── raw_lakehouse
    └── Tables
        └── customers (actual data)

Workspace B (Analytics)
└── analytics_lakehouse
    └── Tables
        └── customers (shortcut to Workspace A)
```

### Key Functions

#### Get-ShortcutMetadataFiles
```powershell
function Get-ShortcutMetadataFiles {
    param([string]$SourcePath)
    
    # Find all shortcuts.metadata.json files in lakehouse folders
    $shortcutFiles = Get-ChildItem -Path $SourcePath -Recurse -Filter "shortcuts.metadata.json" |
        Where-Object { $_.Directory.Name -like "*.Lakehouse" }
    
    return $shortcutFiles
}
```

**shortcuts.metadata.json Structure:**
```json
[
  {
    "name": "raw_customers",
    "path": "/Tables/customers",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "/Tables/customers",
        "itemId": "source-lakehouse-id",
        "workspaceId": "source-workspace-id"
      }
    }
  }
]
```

#### Read-ShortcutMetadata
```powershell
function Read-ShortcutMetadata {
    param([array]$ShortcutFiles, [string]$WorkspaceName)
    
    $allFileShortcuts = @()
    
    foreach ($shortcutFile in $ShortcutFiles) {
        $shortcutContent = Get-Content $shortcutFile -Raw | ConvertFrom-Json
        
        # Get consumer lakehouse from .platform file
        $platformFile = Join-Path (Split-Path $shortcutFile) ".platform"
        $platformContent = Get-Content $platformFile -Raw | ConvertFrom-Json
        $consumerLakehouseName = $platformContent.metadata.displayName
        
        foreach ($shortcut in $shortcutContent) {
            $allFileShortcuts += @{
                ShortcutName = $shortcut.name
                ConsumerLakehouseName = $consumerLakehouseName
                ConsumerWorkspaceName = $WorkspaceName
                ShortcutPath = $shortcut.path
                TargetType = $shortcut.target.type
                TargetPath = $shortcut.target.oneLake.path
                TargetItemId = $consumerLakehouseName  # Placeholder - replaced during merge
                TargetWorkspaceId = $WorkspaceName     # Placeholder - replaced during merge
            }
        }
    }
    
    return $allFileShortcuts
}
```

#### Merge-Shortcuts
```powershell
function Merge-Shortcuts {
    param([array]$FileShortcuts, [array]$VariableShortcuts)
    
    # FileShortcuts: Structure from Git (shortcut definitions)
    # VariableShortcuts: Runtime values from pipeline (actual lakehouse/workspace IDs)
    
    $mergedShortcuts = @()
    
    # Create lookup for file shortcuts
    $fileShortcutLookup = @{}
    foreach ($shortcut in $FileShortcuts) {
        $normalizedName = $shortcut.ShortcutName.ToLower().Trim()
        $fileShortcutLookup[$normalizedName] = $shortcut
    }
    
    # Merge variable shortcuts with file shortcuts
    foreach ($varShortcut in $VariableShortcuts) {
        $normalizedName = $varShortcut.name.ToLower().Trim()
        
        if ($fileShortcutLookup.ContainsKey($normalizedName)) {
            $fileShortcut = $fileShortcutLookup[$normalizedName]
            
            # Combine structure from file with runtime IDs from variables
            $mergedShortcuts += @{
                ShortcutName = $varShortcut.name
                LakehouseName = $varShortcut.lakehouse  # Target lakehouse name
                WorkspaceName = $varShortcut.workspace  # Target workspace name
                ConsumerLakehouseName = $fileShortcut.ConsumerLakehouseName
                ConsumerWorkspaceName = $fileShortcut.ConsumerWorkspaceName
                ShortcutPath = $fileShortcut.ShortcutPath
                TargetPath = $fileShortcut.TargetPath
            }
        }
    }
    
    return $mergedShortcuts
}
```

### Variable Shortcuts Pattern

**Pipeline Variables:**
```yaml
variables:
  - name: shortcut_rawdata_lakehouse
    value: "raw_lakehouse"
  - name: shortcut_rawdata_workspace
    value: "shared_workspace"
```

**Parsed to JSON:**
```json
[
  {
    "name": "rawdata",
    "lakehouse": "raw_lakehouse",
    "workspace": "shared_workspace"
  }
]
```

**Why this pattern?**
- **Separation of concerns**: Structure in Git, IDs in pipeline
- **Environment flexibility**: Same structure, different targets per environment
- **Security**: Workspace/lakehouse names as variables, not hardcoded

### Shortcut Creation Flow

```
1. Read shortcuts.metadata.json → Get shortcut definitions
2. Parse pipeline variables → Get runtime lakehouse/workspace names
3. Merge definitions + runtime values → Complete shortcut configuration
4. For each shortcut:
   a. Resolve consumer lakehouse ID
   b. Resolve target lakehouse ID
   c. Call Invoke-ShortcutCreation.ps1
5. Report success/failure counts
```

### Integration with Invoke-ShortcutCreation.ps1

The main script delegates actual API calls to a child script:

```powershell
& $invokeScript `
    -ConsumerWorkspaceName $shortcut.ConsumerWorkspaceName `
    -ConsumerLakehouseName $shortcut.ConsumerLakehouseName `
    -ShortcutName $shortcut.ShortcutName `
    -ShortcutPath $shortcut.ShortcutPath `
    -TargetWorkspaceName $shortcut.TargetWorkspaceId `
    -TargetLakehouseName $shortcut.TargetItemId `
    -TargetPath $shortcut.TargetPath
```

**Why separate script?**
- Reusable for standalone shortcut creation
- Cleaner error handling per shortcut
- Easier testing

---

## Script 11 Update-NotebookDependencies-ps1

### Purpose
**Phase 1** of notebook deployment: Updates notebook source files to reference correct environment-specific resources (KeyVault, lakehouses, workspaces, environments) before converting to `.ipynb` format.

### Why This Step is Necessary

**Problem:** Notebooks in Git contain development resource IDs:
```python
# META "default_lakehouse_name": "dev_raw_lakehouse"
# META "default_lakehouse_id": "dev-lakehouse-guid"
# META "workspace_id": "dev-workspace-guid"
# META "environment_id": "dev-environment-guid"

secretsScope = "kv-dev-secrets"
```

**Solution:** Replace with production resource IDs at deployment time:
```python
# META "default_lakehouse_name": "prod_raw_lakehouse"
# META "default_lakehouse_id": "prod-lakehouse-guid"
# META "workspace_id": "prod-workspace-guid"
# META "environment_id": "prod-environment-guid"

secretsScope = "kv-prod-secrets"
```

### Notebook Metadata Format

Fabric notebooks use **commented metadata** to store configuration:

```python
# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "lakehouse-guid",
# META       "default_lakehouse_name": "raw_lakehouse",
# META       "default_lakehouse_workspace_id": "workspace-guid"
# META     },
# META     "environment": {
# META       "environmentId": "environment-guid",
# META       "workspaceId": "workspace-guid"
# META     }
# META   }
# META }

# MARKDOWN ********************

# # Data Processing Notebook

# CELL ********************

import pandas as pd
from notebookutils import mssparkutils

# Get secrets from KeyVault
secretsScope = "kv-dev-secrets"
api_key = mssparkutils.credentials.getSecret(secretsScope, "api-key")
```

### Key Functions

#### Get-CommentPrefix
```powershell
function Get-CommentPrefix {
    param([string]$FileExtension)
    
    switch ($FileExtension) {
        ".sql"   { return "--" }
        ".scala" { return "//" }
        default  { return "#" }   # Python, R
    }
}
```

#### Remove-MetaLines
```powershell
function Remove-MetaLines {
    param([string]$Content, [string]$CommentPrefix, [string]$KeyVaultName)
    
    $notebookSource = "$CommentPrefix Fabric notebook source"
    
    return $Content -split "`n" |
        Where-Object {
            # Remove META lines
            -not ($_.Trim().StartsWith("$CommentPrefix META") -or
                  $_.Trim().StartsWith("$CommentPrefix METADATA") -or
                  $_.Trim() -eq $notebookSource)
        } |
        ForEach-Object {
            $line = $_
            
            # Replace secretsScope assignment with new KeyVault name
            if ($line -match "(secretsScope\s*=\s*[`"'])([^`"']+)([`"'])") {
                $before = $matches[1]
                $oldValue = $matches[2]
                $after = $matches[3]
                $line = "${before}${KeyVaultName}${after}"
                Write-Host "Replaced secretsScope from '$oldValue' to '$KeyVaultName'"
            }
            
            return $line
        } |
        Out-String
}
```

#### Get-SectionMarkers
```powershell
function Get-SectionMarkers {
    param([string]$Content, [string]$CommentPrefix)
    
    # Find section markers: # CELL, # PARAMETERS CELL, # METADATA, # MARKDOWN
    $pattern = $CommentPrefix + ' (CELL|PARAMETERS CELL|META(?:DATA)?|MARKDOWN) \*{1,}'
    return [regex]::Matches($Content, $pattern)
}
```

### Notebook Structure Processing

Notebooks are divided into **sections** by markers:

```python
# Fabric notebook source

# METADATA ********************
# { "kernel_info": { "name": "synapse_pyspark" } }

# MARKDOWN ********************
# # Data Processing

# PARAMETERS CELL ********************
date_param = "2024-01-01"
environment = "dev"

# CELL ********************
import pandas as pd
df = pd.read_csv(f"data_{date_param}.csv")

# CELL ********************
df.to_parquet(f"output_{environment}.parquet")
```

**Script processes:**
1. **METADATA section** → Becomes `metadata` in `.ipynb`
2. **MARKDOWN sections** → Become `markdown` cells
3. **PARAMETERS CELL** → Becomes `code` cell with `"tags": ["parameters"]`
4. **CELL sections** → Become regular `code` cells

### Parameters Cell Handling

**Why special handling?**
- Fabric supports **parameterized notebooks** for data pipelines
- Parameters cell values can be overridden at runtime
- Must be tagged with `"tags": ["parameters"]` in `.ipynb` format

**Example transformation:**

**Input (.py):**
```python
# PARAMETERS CELL ********************
date_param = "2024-01-01"
lakehouse_id = "dev-lakehouse-guid"
```

**Output (.ipynb):**
```json
{
  "cell_type": "code",
  "source": [
    "date_param = \"2024-01-01\"\n",
    "lakehouse_id = \"prod-lakehouse-guid\""
  ],
  "metadata": {
    "tags": ["parameters"],
    "microsoft": {
      "language": "python",
      "language_group": "synapse_pyspark"
    }
  },
  "outputs": []
}
```

### IPYNB Structure Creation

```powershell
$ipynbContent = @{
    cells = @(
        @{
            cell_type = "markdown"
            source = @("# Data Processing Notebook")
            metadata = @{}
        },
        @{
            cell_type = "code"
            source = @("date_param = '2024-01-01'")
            metadata = @{
                tags = @("parameters")
                microsoft = @{
                    language = "python"
                    language_group = "synapse_pyspark"
                }
            }
            outputs = @()
        }
    )
    metadata = @{
        kernel_info = @{
            name = "synapse_pyspark"
            jupyter_kernel_name = "synapse_pyspark"
        }
        dependencies = @{
            environment = @{
                environmentId = $EnvironmentId
                workspaceId = $WorkspaceId
            }
            lakehouse = @{
                default_lakehouse = $LakehouseId
                default_lakehouse_name = $LakehouseName
                default_lakehouse_workspace_id = $WorkspaceId
            }
        }
        language_info = @{
            name = "python"
        }
    }
    nbformat = 4
    nbformat_minor = 2
}

# Write to file
$jsonContent = $ipynbContent | ConvertTo-Json -Depth 10 -Compress
[System.IO.File]::WriteAllText($ipynbPath, $jsonContent, [System.Text.Encoding]::UTF8)
```

### Environment ID Resolution Pattern

```powershell
# Default to null if GUID is all zeros
if ("00000000-0000-0000-0000-000000000000" -eq $EnvironmentId) {
    $EnvironmentId = $null
}

# Use Python-specific environment if kernel is Python
if ($jupyterKernelName.StartsWith("python")) {
    $EnvironmentId = $EnvironmentIdPython
}
```

**Why?**
- Different kernels may require different environment configurations
- Python notebooks might use different library versions than Scala
- Null environment ID = use workspace default environment

### Pipeline Integration

```yaml
# Phase 1: Update dependencies
- task: PowerShell@2
  displayName: 'Update Notebook Dependencies'
  inputs:
    script: |
      $notebooks = Get-ChildItem -Path "src/fabric" -Filter "*.Notebook" -Recurse
      
      foreach ($notebook in $notebooks) {
        $notebookContent = Get-ChildItem -Path $notebook.FullName -Filter "*.py" -Recurse | Select-Object -First 1
        
        & "Update-NotebookDependencies.ps1" `
          -KeyVaultName "kv-prod-secrets" `
          -LakehouseName "prod_raw_lakehouse" `
          -LakehouseId $lakehouseId `
          -WorkspaceId $workspaceId `
          -EnvironmentId $environmentId `
          -EnvironmentIdPython $pythonEnvId `
          -NotebookPath $notebookContent.FullName
      }

# Phase 2: Deploy notebooks (uses generated .ipynb files)
- task: PowerShell@2
  displayName: 'Deploy Notebooks'
  inputs:
    script: |
      # Invoke-NotebookManagement.ps1 ...
```

---

## Script 12 Invoke-NotebookManagement-ps1

### Purpose
**Phase 2** of notebook deployment: Creates or updates notebooks in Fabric workspace using `.ipynb` files generated by `Update-NotebookDependencies.ps1`.

### Key Functions

#### ConvertTo-Base64
```powershell
function ConvertTo-Base64 {
    param([string]$FilePath)
    
    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $base64String = [System.Convert]::ToBase64String($fileBytes)
    
    return $base64String
}
```

#### Create-Notebook
```powershell
function Create-Notebook {
    param([string]$WorkspaceId, [string]$DisplayName, [string]$FolderId, [string]$IpynbFile, [string]$Token)
    
    # Convert notebook to Base64
    $ipynbBase64 = ConvertTo-Base64 -FilePath $IpynbFile
    
    # Prepare API request
    $body = @{
        displayName = $DisplayName
        definition = @{
            format = "ipynb"
            parts = @(
                @{
                    path = "notebook-content.ipynb"
                    payload = $ipynbBase64
                    payloadType = "InlineBase64"
                }
            )
        }
    }
    
    # Add folder if specified
    if (-not [string]::IsNullOrEmpty($FolderId)) {
        $body.folderId = $FolderId
    }
    
    # POST https://api.fabric.microsoft.com/v1/workspaces/{id}/notebooks
    $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body ($body | ConvertTo-Json -Depth 10)
    
    return $response
}
```

#### Update-Notebook
```powershell
function Update-Notebook {
    param([string]$WorkspaceId, [string]$NotebookId, [string]$DisplayName, [string]$IpynbFile, [string]$Token)
    
    # Update definition
    $definitionUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks/$NotebookId/updateDefinition"
    
    $ipynbBase64 = ConvertTo-Base64 -FilePath $IpynbFile
    
    $definitionBody = @{
        definition = @{
            format = "ipynb"
            parts = @(
                @{
                    path = "notebook-content.ipynb"
                    payload = $ipynbBase64
                    payloadType = "InlineBase64"
                }
            )
        }
    }
    
    Invoke-FabricApiWithRetry -Uri $definitionUrl -Headers $headers -Method POST -Body ($definitionBody | ConvertTo-Json -Depth 10)
    
    # Update properties if needed
    if (-not [string]::IsNullOrEmpty($DisplayName)) {
        $propertiesUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks/$NotebookId"
        $propertiesBody = @{ displayName = $DisplayName }
        Invoke-FabricApiWithRetry -Uri $propertiesUrl -Headers $headers -Method PATCH -Body ($propertiesBody | ConvertTo-Json)
    }
}
```

### CreateOrUpdate Pattern with Folder Movement

```powershell
switch ($Action) {
    "createorupdate" {
        # 1. Look up notebook by name
        $existingNotebookId = Get-NotebookIdByName -WorkspaceId $WorkspaceId -Name $DisplayName
        
        if ($null -eq $existingNotebookId) {
            # 2a. Create new notebook
            $result = Create-Notebook -WorkspaceId $WorkspaceId -DisplayName $DisplayName -FolderId $folderId -IpynbFile $IpynbFile
        } else {
            # 2b. Update existing notebook
            $result = Update-Notebook -WorkspaceId $WorkspaceId -NotebookId $existingNotebookId -DisplayName $DisplayName -IpynbFile $IpynbFile
            
            # 3. Check folder placement
            $currentFolderId = Get-NotebookCurrentFolder -WorkspaceId $WorkspaceId -NotebookId $existingNotebookId
            
            # 4. Move if needed
            if ($currentFolderId -ne $folderId) {
                Move-NotebookToFolder -WorkspaceId $WorkspaceId -NotebookId $existingNotebookId -TargetFolderId $folderId
            }
        }
        
        return $result
    }
}
```

### Why Two-Step Update?

**updateDefinition (POST):**
- Updates notebook content (cells, code)
- Requires Base64-encoded `.ipynb` payload
- Cannot update display name

**PATCH (properties):**
- Updates metadata (display name, description)
- Cannot update notebook content

**Solution:** Call both endpoints for complete update

---

## Script 13 Handle-PrivateEndpointApprovals-ps1

### Purpose
Orchestrates private endpoint creation/deletion for Fabric managed private endpoints. Processes JSON configuration and delegates to `Create-ManagedPrivateEndpoints.ps1` for each endpoint.

### Key Functions

#### Parameter Handling
```powershell
param(
    [Parameter(Mandatory = $true)]
    [string]$PepDetailedJson,              # JSON array of private endpoint configurations
   
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,
   
    [Parameter(Mandatory = $false)]
    [bool]$ForceDeletionPPE = $false,      # Force deletion flag
   
    [Parameter(Mandatory = $false)]
    [string]$ScriptBasePath = "."          # Base path for child scripts
)
```

### Private Endpoint Configuration Structure

**Input JSON Format:**
```json
[
  {
    "resourceId": "/subscriptions/54b793d9-b402-4390-9cb2-e18192123540/resourceGroups/bhg-prod-fabric-eus-rg/providers/Microsoft.Storage/storageAccounts/bhgprodfabricedoussa",
    "subresourceType": "blob",
    "allowed": true
  },
  {
    "resourceId": "/subscriptions/3a2539e2-7efe-40cb-b451-10953168fd56/resourceGroups/bhg-hub-fabric-eus-rg/providers/Microsoft.KeyVault/vaults/bhg-hub-fabric01-eus-kv",
    "subresourceType": "vault",
    "allowed": false
  }
]
```

### Endpoint Name Construction

```powershell
# Extract resource name from resource ID
$resourceIdParts = $pep.resourceId -split '/'
$resourceName = $resourceIdParts[-1]

# Create endpoint name (max 64 characters)
$workspaceNameCleaned = $workspaceName -replace '\s+', '-' -replace '[/\\]', '-'
$endpointName = "$workspaceNameCleaned-$resourceName"

if ($endpointName.Length -gt 64) {
    $endpointName = $endpointName.Substring(0, 64)
}
```

**Pattern:** `{workspaceName}-{resourceName}` (max 64 characters)

**Example:** `"analytics-workspace-mystorageaccount"`

### Execution Flow

```
1. Parse PepDetailedJson → Get endpoint configurations
2. For each configuration:
   a. Extract resource name from resource ID
   b. Construct endpoint name
   c. Build endpoint object with all required properties
3. For each endpoint:
   a. If allowed=true: 
      - Call Create-ManagedPrivateEndpoints.ps1 with Delete=false
      - Fail task if creation fails
   b. If allowed=false:
      - Call Create-ManagedPrivateEndpoints.ps1 with Delete=true
      - Continue with warning if deletion fails (don't fail task)
   c. Wait 5 seconds between endpoints (avoid rate limiting)
4. Report success/failure counts
```

### Error Handling Strategy

**Creation/Update Failures:**
```powershell
if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
    Write-Host "##[info]Successfully processed endpoint: $($endpoint.endpoint_name)"
} else {
    Write-Host "##[error]Failed to process endpoint: $($endpoint.endpoint_name). Exit code: $LASTEXITCODE"
    throw "Private endpoint creation failed for $($endpoint.endpoint_name)"
}
```

**Deletion Failures:**
```powershell
if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
    Write-Host "##[info]Successfully deleted endpoint: $($endpoint.endpoint_name)"
} else {
    Write-Host "##[warning]Failed to delete endpoint: $($endpoint.endpoint_name). Exit code: $LASTEXITCODE"
    # Don't throw error for deletion failures, just warn
}
```

**Why different handling?**
- **Creation failures** are critical → Fail the pipeline (networking requirement not met)
- **Deletion failures** are non-critical → Warn but continue (endpoint may already be deleted or not exist)

### Integration with Create-ManagedPrivateEndpoints.ps1

The script delegates actual API calls to a child script:

```powershell
$scriptParams = @{
    WorkspaceId = $endpoint.workspace_id
    EndpointName = $endpoint.endpoint_name
    TargetResourceId = $endpoint.target_resource_id
    TargetSubresourceType = $endpoint.target_subresource
    RequestMessage = $endpoint.request_message
    Verbose = $true
    Delete = $endpoint.force_deletion_ppe  # or $true for deletion
}

& $managedEndpointsScript @scriptParams
```

### Rate Limiting Strategy

```powershell
# Add a brief pause between endpoints to avoid API rate limiting
Write-Host "##[debug]Waiting 5 seconds before processing next endpoint..."
Start-Sleep -Seconds 5
```

**Why?** Fabric API has rate limits for private endpoint operations. Sequential processing with delays ensures reliability.

---

## Script 14 Setup-FabricDataPipelines-ps1

### Purpose
Creates/updates Fabric data pipelines with dynamic parameter replacement (lakehouse IDs, workspace IDs, connection IDs, notebook IDs, pipeline IDs).

### Key Functions

#### Get-PlatformFiles
```powershell
function Get-PlatformFiles {
    # Scan src/fabric/ directory for *.DataPipeline folders
    # Read .platform files for metadata
    # Return array of pipeline definitions with:
    #   - displayName
    #   - description
    #   - logicalId
    #   - folderPath
}
```

#### Get-NotebookMappings
```powershell
function Get-NotebookMappings {
    # Scan for *.Notebook folders
    # Read .platform files
    # Build mapping of logicalId to displayName
    # Used to replace notebook references in pipelines
}
```

#### New-FabricDataPipelines
```powershell
function New-FabricDataPipelines {
    param (
        [string]$token,
        [string]$workspaceId,
        [array]$platformFiles
    )
   
    # Get existing pipelines
    $existingPipelines = Get-ExistingDataPipelines -token $token -workspaceId $workspaceId
   
    foreach ($pf in $platformFiles) {
        $existingPipeline = $existingPipelines | Where-Object { $_.displayName -eq $pf.displayName }
       
        if ($existingPipeline) {
            # Update existing pipeline
            Update-FabricDataPipelines -token $token -workspaceId $workspaceId -pipelineId $existingPipeline.id -platformFile $pf
           
            # Check and move to correct folder if needed
            if (-not [string]::IsNullOrEmpty($folderId)) {
                $currentFolderId = Get-DataPipelineCurrentFolder -WorkspaceId $WorkspaceId -DataPipelineId $existingPipeline.id -Token $token
                if ($currentFolderId -ne $folderId) {
                    Move-DataPipelineToFolder -WorkspaceId $WorkspaceId -DataPipelineId $existingPipeline.id -TargetFolderId $folderId -Token $token
                }
            }
        } else {
            # Create new pipeline
            $response = Invoke-FabricApiWithRetry -Uri $uri -Headers $headers -Method POST -Body $bodyJson -MaxRetries 5
        }
    }
   
    return $recordedPipelines
}
```

### Parameter Replacement Patterns

#### 1. Lakehouse Parameters (lh_{name}_id)

**Pattern:** `lh_metadata_id`, `lh_raw_id`, `lh_observability_id`

**Extraction Logic:**
```powershell
function Get-LakehouseNameFromParameter {
    param([string]$parameterName)
   
    # Pattern: lh_{lakehousename}_id
    # Extract the part between 'lh_' and '_id'
    if ($parameterName -match '^lh_(.+?)_id$') {
        $lakehouseName = $Matches[1]
        return $lakehouseName
    }
   
    return $null
}
```

**Replacement:**
```powershell
# Find matching lakehouse by name
$targetLakehouse = Find-LakehouseByName -lakehouseName $lakehouseName -lakehouses $lakehouses

if ($targetLakehouse) {
    $paramValue.defaultValue = $targetLakehouse.id
}
```

#### 2. Workspace ID Replacement

**Pattern:** `workspace_id` parameter with placeholder `"00000000-0000-0000-0000-000000000000"`

**Recursive Update:**
```powershell
function Update-WorkspaceIds {
    param([object]$InputObject)
   
    # Recursively process all objects
    if ($InputObject -is [System.Array]) {
        foreach ($item in $InputObject) {
            Update-WorkspaceIds -InputObject $item
        }
        return
    }
   
    if ($InputObject -is [PSCustomObject]) {
        # Check if this is an InvokePipeline activity
        if ($InputObject.type -eq "InvokePipeline" -and $InputObject.typeProperties) {
            $InputObject.typeProperties.workspaceId = $workspaceId
        }
       
        # Recursively process all properties
        foreach ($property in $InputObject.PSObject.Properties) {
            Update-WorkspaceIds -InputObject $property.Value
        }
    }
}
```

**Why recursive?** InvokePipeline activities can be nested at any depth in the pipeline JSON structure.

#### 3. Lakehouse ArtifactId in LinkedService

**Pattern:**
```json
{
  "linkedService": {
    "name": "den_lhw_pdi_001_metadata",
    "properties": {
      "type": "Lakehouse",
      "typeProperties": {
        "artifactId": "8b2c756c-53e7-bda0-4d1b-0fd908217f49"
      }
    }
  }
}
```

**Replacement:**
```powershell
foreach ($lakehouse in $lakehouses) {
    $linkedServicePattern = "name`":\s*`"$($lakehouse.displayName)`"[\s\S]*?`"artifactId`":\s*`"([^`"]+)`""
   
    if ($contentJson -match $linkedServicePattern) {
        $oldArtifactId = $Matches[1]
        $contentJson = $contentJson -replace $oldArtifactId, $lakehouse.id
    }
}
```

#### 4. Pipeline LogicalId Replacement

**Purpose:** Replace pipeline references that use logicalId (from .platform file) with actual pipeline IDs

**Pattern:**
```powershell
$pipelineReplacements = @()
foreach ($pipeline in $createdPipelines) {
    $pipelineReplacements += @{
        logicalId = $pipeline.logicalId
        id = $pipeline.id
    }
}

# Replace in pipeline content
foreach ($replacement in $pipelineReplacements) {
    $contentJson = $contentJson.Replace($replacement.logicalId, $replacement.id)
}
```

#### 5. Connection IDs

**Pattern:** Connection name and GUID in pipeline JSON

**Replacement:**
```powershell
foreach ($mapping in $fabricManagedConnections) {
    $connection = $fabricConnections | Where-Object { $_.displayName -eq $mapping.new_name }
   
    if ($connection) {
        $contentJson = $contentJson.Replace($mapping.original_name, $mapping.new_name)
        $contentJson = $contentJson.Replace($mapping.guid, $connection.id)
    }
}
```

#### 6. Notebook IDs

**Pattern:** Notebook logicalId from .platform file

**Replacement:**
```powershell
foreach ($mapping in $notebookMappings) {
    $matchingNotebook = $notebookIds | Where-Object {
        $cleanedDisplayName = $_.displayName -replace '^dev_', ''
        $cleanedDisplayName -like "*$($mapping.displayName)*"
    }
   
    if ($matchingNotebook) {
        $contentJson = $contentJson.Replace($mapping.searchId, $matchingNotebook.id)
    }
}
```

### Update-PipelineContent Function

The core transformation function:

```powershell
function Update-PipelineContent {
    param (
        [string]$pipelinePath,
        [object]$lakehouses,
        [string]$workspaceId,
        [array]$pipelineReplacements,
        [array]$fabricConnections,
        [array]$notebookIds,
        [array]$fabricManagedConnections
    )
   
    # 1. Read pipeline content
    $content = Get-Content -Path $pipelinePath | ConvertFrom-Json
   
    # 2. Update lakehouse parameters
    foreach ($param in $lakehouseParameters) {
        $lakehouseName = Get-LakehouseNameFromParameter -parameterName $param.Name
        $targetLakehouse = Find-LakehouseByName -lakehouseName $lakehouseName -lakehouses $lakehouses
        $param.Value.defaultValue = $targetLakehouse.id
    }
   
    # 3. Update workspace IDs recursively
    Update-WorkspaceIds -InputObject $content.properties.activities
   
    # 4. Convert to JSON for string replacements
    $contentJson = ConvertTo-Json -InputObject $content -Depth 100
   
    # 5. Replace lakehouse artifactIds in linkedServices
    foreach ($lakehouse in $lakehouses) {
        # Pattern matching and replacement
    }
   
    # 6. Replace pipeline logicalIds with IDs
    foreach ($replacement in $pipelineReplacements) {
        $contentJson = $contentJson.Replace($replacement.logicalId, $replacement.id)
    }
   
    # 7. Replace placeholder workspace IDs
    $contentJson = $contentJson.Replace("00000000-0000-0000-0000-000000000000", $workspaceId)
   
    # 8. Replace connection names and IDs
    foreach ($mapping in $fabricManagedConnections) {
        # Connection replacement logic
    }
   
    # 9. Replace notebook IDs
    foreach ($mapping in $notebookMappings) {
        # Notebook replacement logic
    }
   
    # 10. Convert back to object
    return (ConvertFrom-Json -InputObject $contentJson)
}
```

### Execution Flow

```
1. Get platform files → Read .platform files from *.DataPipeline folders
2. Create/update pipelines → For each platform file, create or update pipeline
3. Build replacement mappings:
   - Pipeline logicalId → ID mappings
   - Get lakehouses from workspace
4. For each pipeline:
   a. Read pipeline-content.json
   b. Update content with all replacements:
      - Lakehouse parameters
      - Workspace IDs (recursive)
      - Lakehouse artifactIds
      - Pipeline IDs
      - Connection IDs
      - Notebook IDs
   c. Update definition via API
5. Handle folder placement (move if needed)
```

### Pipeline Definition Update

```powershell
function Update-PipelineDefinition {
    param (
        [string]$token,
        [string]$workspaceId,
        [string]$itemId,
        [object]$definition
    )
   
    # Convert definition to JSON
    $definitionJson = ConvertTo-Json -InputObject $definition -Depth 100
   
    # Convert to Base64
    $fileBytes = [System.Text.Encoding]::UTF8.GetBytes($definitionJson)
    $contentPayload = [System.Convert]::ToBase64String($fileBytes)
   
    $body = @{
        displayName = $definition.displayName
        description = $definition.description
        definition = @{
            parts = @(
                @{
                    path = "pipeline-content.json"
                    payload = $contentPayload
                    payloadType = "InlineBase64"
                }
            )
        }
    }
   
    $uri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items/$itemId/updateDefinition"
    $response = Invoke-FabricApiWithRetry -Uri $uri -Headers $headers -Method POST -Body $bodyJson -MaxRetries 5
}
```

---

## Script 15 Deploy-FabricSemanticModels-ps1

### Purpose
Deploys semantic models (TMDL format) with dynamic parameter replacement and connection binding to lakehouses.

### Key Functions

#### Read-PlatformFiles
```powershell
function Read-PlatformFiles {
    param (
        [string]$BaseFolderPath,
        [string]$FabricItemType = "SemanticModel",
        [string]$WorkspaceId
    )
   
    # Scan for *.SemanticModel folders
    # Read .platform files and all .tmdl files
    # Process each file with parameter replacement
    # Return array of semantic model definitions with Base64-encoded parts
}
```

#### Get-ContentPayload
```powershell
function Get-ContentPayload {
    param (
        [string]$filePath,
        [string]$fileName,
        [string]$WorkspaceId,
        [string]$DisplayName
    )
   
    # Read file content
    $fileContent = Get-Content -Path $filePath -Raw -Encoding UTF8
   
    # Apply transformations based on file type
    if ($fileExtension -eq ".tmdl") {
        $fileContent = Update-ParameterSourceSQLDatabase -fileContent $fileContent -fileName $fileName
        $fileContent = Update-ParameterAzureStorage -fileContent $fileContent -WorkspaceId $WorkspaceId -DisplayName $DisplayName
    }
   
    if ($fileName -eq "expressions.tmdl") {
        $fileContent = Update-Connection -fileContent $fileContent -WorkspaceId $WorkspaceId -DisplayName $DisplayName
    }
   
    # Convert to Base64
    $fileBytes = [System.Text.Encoding]::UTF8.GetBytes($fileContent)
    return [Convert]::ToBase64String($fileBytes)
}
```

### TMDL Format (Tabular Model Definition Language)

TMDL is a text-based format for semantic models, replacing PBIX for source control.

**File Structure:**
```
semanticmodel.SemanticModel/
├── .platform                    # Metadata
├── model.tmdl                   # Model configuration
├── expressions.tmdl             # M expressions (connections)
└── tables/
    ├── customers.tmdl          # Table definitions
    ├── orders.tmdl
    └── ...
```

### Parameter Replacement in TMDL

#### 1. Source Parameter (SQLDatabase)

**Pattern in TMDL file:**
```
source = "8b2c756c-53e7-bda0-4d1b-0fd908217f49" meta [...]
```

**Replacement Logic:**
```powershell
function Update-ParameterSourceSQLDatabase {
    param (
        [string]$fileContent,
        [string]$fileName
    )
   
    $fileBaseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $sourcePattern = 'source\s*=\s*"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"'
   
    $matches = [regex]::Matches($fileContent, $sourcePattern)
   
    foreach ($match in $matches) {
        $currentGuid = $match.Groups[1].Value
       
        # Look up replacement in variable group
        $replacement = $SemanticModelsParametersDetail | Where-Object { $_.name -eq $fileBaseName }
       
        if ($replacement) {
            $newGuid = $replacement.newValue
            $fileContent = $fileContent -replace $currentGuid, $newGuid
        }
    }
   
    return $fileContent
}
```

#### 2. AzureStorage.DataLake (OneLake Paths)

**Pattern:**
```
onelake.dfs.fabric.microsoft.com/{workspaceId}/{lakehouseId}
```

**Replacement Logic:**
```powershell
function Update-ParameterAzureStorage {
    param (
        [string]$fileContent,
        [string]$WorkspaceId,
        [string]$DisplayName
    )
   
    $azureStoragePattern = 'onelake\.dfs\.fabric\.microsoft\.com/([a-fA-F0-9-]{36})/([a-fA-F0-9-]{36})'
    $matches = [regex]::Matches($fileContent, $azureStoragePattern)
   
    foreach ($match in $matches) {
        $currentWorkspaceId = $match.Groups[1].Value
        $currentLakehouseId = $match.Groups[2].Value
       
        # Find target lakehouse from variable group mapping
        $semanticModel = $SemanticModelsDetail | Where-Object { $_.name -eq $DisplayName }
        $targetLakehouseName = $semanticModel.newValue
       
        $targetLakehouse = $global:WorkspaceLakehouses | Where-Object {
            $_.displayName -eq $targetLakehouseName
        }
       
        if ($targetLakehouse) {
            $newWorkspaceId = $WorkspaceId
            $newLakehouseId = $targetLakehouse.id
           
            $oldUrl = $match.Value
            $newUrl = $oldUrl -replace $currentWorkspaceId, $newWorkspaceId
            $newUrl = $newUrl -replace $currentLakehouseId, $newLakehouseId
           
            $fileContent = $fileContent.Replace($oldUrl, $newUrl)
        }
    }
   
    return $fileContent
}
```

#### 3. Sql.Database Connection

**Pattern in expressions.tmdl:**
```
Sql.Database("server.database.windows.net", "database-guid")
```

**Replacement Logic:**
```powershell
function Update-Connection {
    param (
        [string]$fileContent,
        [string]$WorkspaceId,
        [string]$DisplayName
    )
   
    $sqlDatabasePattern = 'Sql\.Database\("([^"]+)", "([^"]+)"\)'
    $matches = $fileContent | Select-String -pattern $sqlDatabasePattern -AllMatches
   
    foreach ($match in $matches.Matches) {
        $currentServer = $match.Groups[1].Value
        $currentDatabaseId = $match.Groups[2].Value
       
        # Find lakehouse by display name or ID
        $lakehouse = $global:WorkspaceLakehouses | Where-Object {
            $_.displayName -eq $currentDatabaseId -or $_.id -eq $currentDatabaseId
        }
       
        if (-not $lakehouse) {
            # Fallback: Get from semantic model mapping
            $semanticModel = $SemanticModelsDetail | Where-Object { $_.name -eq $DisplayName }
            if ($semanticModel) {
                $lakehouse = $global:WorkspaceLakehouses | Where-Object {
                    $_.displayName -eq $semanticModel.newValue
                }
            }
        }
       
        if ($lakehouse) {
            # Get SQL endpoint connection details
            $sqlEndpointUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/sqlEndpoints"
            $sqlEndpointsResponse = Invoke-FabricApiWithRetry -Uri $sqlEndpointUri -Headers $headers -Method Get
           
            $sqlEndpoint = $sqlEndpointsResponse.value | Where-Object {
                $_.displayName -eq $lakehouse.displayName
            }
           
            $newServer = $lakehouse.properties.sqlEndpointProperties.connectionString
            $newDatabaseId = $sqlEndpoint.id
           
            # Replace entire Sql.Database() call
            $oldSqlCall = $match.Value
            $newSqlCall = "Sql.Database(`"$newServer`", `"$newDatabaseId`")"
            $fileContent = $fileContent.Replace($oldSqlCall, $newSqlCall)
        }
    }
   
    return $fileContent
}
```

### Connection Binding After Deployment

#### Get-LakehouseSQLEndpointConnection
```powershell
function Get-LakehouseSQLEndpointConnection {
    param(
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$Token
    )
   
    # Get lakehouse details
    $lakehouse = $global:WorkspaceLakehouses | Where-Object { $_.id -eq $LakehouseId }
   
    # Get SQL Endpoint ID
    $sqlEndpointUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/sqlEndpoints"
    $sqlEndpointsResponse = Invoke-FabricApiWithRetry -Uri $sqlEndpointUri -Headers $headers -Method GET
   
    $sqlEndpoint = $sqlEndpointsResponse.value | Where-Object {
        $_.displayName -eq $lakehouse.displayName
    }
   
    # Get connection details
    $connectionString = $lakehouse.properties.sqlEndpointProperties.connectionString
   
    return @{
        lakehouseId = $LakehouseId
        sqlEndpointId = $sqlEndpoint.id
        connectionString = $connectionString
        databaseId = $sqlEndpoint.id
    }
}
```

#### Bind-SemanticModelConnection
```powershell
function Bind-SemanticModelConnection {
    param(
        [string]$WorkspaceId,
        [string]$SemanticModelId,
        [string]$DisplayName,
        [string]$Token
    )
   
    # Step 1: Determine target lakehouse from variable group
    $semanticModel = $SemanticModelsDetail | Where-Object { $_.name -eq $DisplayName }
    $targetLakehouseName = $semanticModel.newValue
   
    # Step 2: Find target lakehouse
    $targetLakehouse = $global:WorkspaceLakehouses | Where-Object {
        $_.displayName -eq $targetLakehouseName
    }
   
    # Step 3: Get SQL Endpoint connection details
    $connectionDetails = Get-LakehouseSQLEndpointConnection `
        -WorkspaceId $WorkspaceId `
        -LakehouseId $targetLakehouse.id `
        -Token $Token
   
    # Step 4: Get existing connections for semantic model
    $existingConnections = $fabricConnections | Where-Object {
        $_.displayName -eq $semanticModel.connectionName
    }
   
    # Step 5: Bind each SQL connection
    foreach ($connection in $existingConnections) {
        if ($connection.connectionDetails.type -eq "SQL") {
            # Construct new connection path: "server;databaseId"
            $newPath = "$($connectionDetails.connectionString);$($connectionDetails.databaseId)"
           
            $bindingBody = @{
                connectionBinding = @{
                    id = $connection.id
                    connectivityType = "ShareableCloud"
                    connectionDetails = @{
                        type = "SQL"
                        path = $newPath
                    }
                }
            } | ConvertTo-Json -Depth 10
           
            $bindUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/semanticModels/$SemanticModelId/bindConnection"
           
            Invoke-RestMethod -Uri $bindUri -Headers $headers -Method POST -Body $bindingBody
        }
    }
}
```

### Model Ownership Takeover

**Why needed?** Semantic models created by service principal require ownership transfer before updates.

```powershell
function Invoke-SemanticModelTakeOver {
    param(
        [string]$WorkspaceId,
        [string]$SemanticModelId,
        [string]$Token
    )
   
    # Use Power BI API (not Fabric API) for takeover
    $apiUrl = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets/$SemanticModelId/Default.TakeOver"
   
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }
   
    # Execute take over (POST with empty body)
    Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body "{}"
}
```

### Execution Flow

```
1. Read platform files → Process .tmdl files with parameter replacement
2. For each semantic model:
   a. Check if exists by displayName
   b. If exists:
      - Take ownership of model
      - Update definition with transformed TMDL
      - Check folder placement
      - Move to folder if needed
   c. If not exists:
      - Create model with definition
   d. Wait 5 seconds for stabilization
   e. Bind connections to target lakehouses:
      - Determine target lakehouse from variable group
      - Get SQL endpoint connection details
      - Get existing connections for model
      - Bind each SQL connection to lakehouse
3. Report success/failure counts
```

### Folder Placement

```powershell
if (-not [string]::IsNullOrEmpty($folderId)) {
    $currentFolderId = Get-SemanticModelCurrentFolder -WorkspaceId $WorkspaceId -SemanticModelId $itemLookup.id -Token $FabricToken
   
    $needsMove = $false
    if ([string]::IsNullOrEmpty($currentFolderId) -and -not [string]::IsNullOrEmpty($folderId)) {
        $needsMove = $true
    } elseif (-not [string]::IsNullOrEmpty($currentFolderId) -and $currentFolderId -ne $folderId) {
        $needsMove = $true
    }
   
    if ($needsMove) {
        Move-SemanticModelToFolder -WorkspaceId $WorkspaceId -SemanticModelId $itemLookup.id -TargetFolderId $folderId -Token $FabricToken
    }
}
```

---

## Script 16 Deploy-FabricReports-ps1

### Purpose
Deploys Power BI reports with semantic model binding and static resources (logos, themes).

### Key Functions

#### Read-PlatformFiles
```powershell
function Read-PlatformFiles {
    param (
        [string]$BaseFolderPath,
        [string]$WorkspaceId,
        [string]$WorkspaceName,
        [string]$FabricItemType = "Report"
    )
   
    # Scan for *.Report folders
    # Process definition.pbir files (update semantic model connections)
    # Include static resources (logos, themes)
    # Return array of report definitions
}
```

### Definition.pbir Processing

**Report Definition File Structure:**
```json
{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/visualContainer/1.0.0/schema.json",
  "version": "4.0",
  "datasetReference": {
    "byPath": {
      "path": "../semanticmodel.SemanticModel"
    }
  }
}
```

### Semantic Model Resolution

**Process:**
```
1. Read definition.pbir → Extract byPath reference
2. Resolve relative path from report folder to semantic model folder
3. Read semantic model .platform file → Get displayName
4. Find semantic model in workspace by displayName → Get ID
5. Replace byPath with byConnection (v1 or v2 based on schema version)
```

**Resolution Logic:**
```powershell
# Read pbir content
$pbirContent = Get-Content -Path $definitionPBISMFilePath -Raw | ConvertFrom-Json
$originalPath = $pbirContent.datasetReference.byPath.path

# Resolve relative path
if ($originalPath -match '^\.\.\/') {
    $relativePath = $originalPath -replace '/', '\'
    $reportFolderFullPath = $folder.FullName
    $resolvedPath = Resolve-Path -Path (Join-Path $reportFolderFullPath $relativePath)
    $smPath = $resolvedPath.Path
}

# Read semantic model .platform file
$platformFilePath = Join-Path $smPath ".platform"
$referenceSemanticModel = Get-Content -Path $platformFilePath -Raw | ConvertFrom-Json
$semanticModelName = $referenceSemanticModel.metadata.displayName

# Find semantic model in workspace
$semanticModelId = $null
foreach ($model in $FabricSemanticModels) {
    if ($model.displayName -eq $semanticModelName -and $model.workspaceId -eq $WorkspaceId) {
        $semanticModelId = $model.id
        break
    }
}
```

### PBIR Version Handling

#### Version 1 (Schema 1.0.0) - Full Connection Object

```powershell
# Replace schema version
$pbirContent.'$schema' = $pbirContent.'$schema' -replace '/2\.0\.0/', '/1.0.0/'

# Remove byPath, add byConnection
$pbirContent.datasetReference.byPath = $null
$pbirContent.datasetReference | Add-Member -MemberType NoteProperty -Name byConnection -Value @{}

$pbirContent.datasetReference.byConnection = @{
    "connectionString" = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$WorkspaceName;Initial Catalog=$semanticModelName;"
    "pbiServiceModelId" = $null
    "pbiModelVirtualServerName" = "sobe_wowvirtualserver"
    "pbiModelDatabaseName" = $semanticModelId
    "name" = "EntityDataSource"
    "connectionType" = "pbiServiceXmlaStyleLive"
}

$pbirJson = $pbirContent | ConvertTo-Json -Depth 10
```

#### Version 2 (Schema 2.0.0) - Connection String Only

```powershell
$cleanPbirContent = @{
    '$schema' = $pbirContent.'$schema'
    "version" = "4.0"
    "datasetReference" = @{
        "byConnection" = @{
            "connectionString" = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$WorkspaceName;Initial Catalog=$semanticModelName;semanticmodelid=$semanticModelId"
        }
    }
}

$pbirJson = $cleanPbirContent | ConvertTo-Json -Depth 10
```

**Key Difference:** v2 uses simplified connection string format with `semanticmodelid` parameter.

### Static Resources Handling

Reports can include static resources in `staticResources/RegisteredResources/` folder:

```powershell
elseif ($itemPath -like "staticResources/RegisteredResources/*") {
    # Handle static resources (logos, themes, etc.)
   
    # For binary files (images)
    if ($_.Extension -in @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico')) {
        $fileBytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $contentPayload = [Convert]::ToBase64String($fileBytes)
    }
    # For text files (JSON, etc.)
    else {
        $contentPayload = Get-ContentPayload -filePath $_.FullName
    }
   
    $result.definitionParts += @{ $itemPath = $contentPayload }
}
```

**Static Resource Types:**
- **Images**: Logos, custom visuals icons (`.png`, `.jpg`, `.gif`)
- **Themes**: Custom color schemes (`.json`)
- **Fonts**: Custom fonts (if supported)

### PBIR v2 Detection

```powershell
# Check if report uses v2 format (has 'definition' folder)
$pbir_v2 = $false
$definitionFolder = $itemSourceFiles | Where-Object { 
    $_.FullName -like "*definition*" -and $_.Name -ne "definition.pbir" 
}

if ($definitionFolder) {
    $pbir_v2 = $true
}

# If v2, include .platform file as definition part
if ($pbir_v2) {
    $platformPayload = Get-ContentPayload -filePath $platformFilePath
    $result.definitionParts += @{ ".platform" = $platformPayload }
}
```

### Report Deployment

```powershell
$ItemBody = @{
    "displayName" = $displayName
    "description" = $displayName
    "type" = "Report"
    "definition" = @{ 
        "parts" = @($ItemDefinitionPart) 
    }
    "folderId" = $folderId
} | ConvertTo-Json -Compress -Depth 100

if ($null -eq $itemLookup.id) {
    # Create report
    $itemUrl = "https://api.fabric.Microsoft.com/v1/workspaces/$WorkspaceId/reports"
    $crud_response = Invoke-WebRequest -Uri $itemUrl -Headers $headers -Body $ItemBody -Method POST
} else {
    # Update report
    $itemUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/reports/$($itemLookup.id)/updateDefinition"
    $crud_response = Invoke-WebRequest -Uri $itemUrl -Headers $headers -Body $ItemBody -Method POST
   
    # Check and move to folder if needed
    if (-not [string]::IsNullOrEmpty($folderId)) {
        $currentFolderId = Get-ReportCurrentFolder -WorkspaceId $WorkspaceId -ReportId $itemLookup.id -Token $FabricToken
       
        if ($currentFolderId -ne $folderId) {
            Move-ReportToFolder -WorkspaceId $WorkspaceId -ReportId $itemLookup.id -TargetFolderId $folderId -Token $FabricToken
        }
    }
}
```

### Operation Status Polling

Reports use long-running operation pattern:

```powershell
$operation_url = [System.Uri]::new($crud_response.Headers["Location"])

while ($true) {
    if ($crud_response.StatusCode -eq 200) {
        Write-Host "##[info]Successful Deployment"
        break
    }
   
    if ($crud_response.StatusCode -ne 202) {
        break
    }
   
    Start-Sleep -Seconds 1
   
    $crud_response = Invoke-WebRequest -Uri $operation_url -Headers $headers -Method GET
   
    if (($crud_response.Content | ConvertFrom-Json).status -eq 'Failed') {
        Write-Host "##[error]$($crud_response.Content | ConvertFrom-Json).error"
        break
    }
}
```

**Status Codes:**
- `202 Accepted`: Operation in progress, continue polling
- `200 OK`: Operation completed successfully
- Other: Operation failed or completed

---

## Script 17 Fabric-GitOperations-ps1

### Purpose
Integrates Fabric workspace with Azure DevOps Git repository. Supports connect, initialize, commit, update, and branch synchronization.

### Key Functions

#### Connect-FabricGit
```powershell
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
   
    $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git/connect"
    $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body ($body | ConvertTo-Json)
   
    # Handle 409 WorkspaceAlreadyConnectedToGit gracefully
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 409) {
            $errorJson = $errorBody | ConvertFrom-Json
            if ($errorJson.errorCode -eq "WorkspaceAlreadyConnectedToGit") {
                return $errorJson  # Return to indicate already connected
            }
        }
        throw
    }
}
```

#### Initialize-FabricGitConnection
```powershell
function Initialize-FabricGitConnection {
    param (
        [string]$Token,
        [string]$WorkspaceId,
        [ValidateSet('None', 'PreferRemote', 'PreferWorkspace')]
        [string]$InitializationStrategy = 'PreferWorkspace'
    )
   
    $body = @{
        initializationStrategy = $InitializationStrategy
    }
   
    $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git/initializeConnection"
    $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body ($body | ConvertTo-Json)
   
    # Handle 409 WorkspaceGitConnectionAlreadyInitialized gracefully
}
```

**Initialization Strategies:**
- **PreferRemote**: Use Git content, overwrite workspace
- **PreferWorkspace**: Use workspace content, overwrite Git (default)
- **None**: No automatic resolution

#### Invoke-FabricGitCommit
```powershell
function Invoke-FabricGitCommit {
    param (
        [string]$Token,
        [string]$WorkspaceId,
        [string]$Comment = "Initial commit from Fabric workspace"
    )
   
    $body = @{
        mode = "All"
        comment = $Comment
    }
   
    $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git/commitToGit"
    $response = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body ($body | ConvertTo-Json)
   
    if ($response.StatusCode -eq 202) {
        return $response.Headers['x-ms-operation-id']  # Return operation ID for polling
    }
}
```

#### Update-FabricFromGit
```powershell
function Update-FabricFromGit {
    param (
        [string]$Token,
        [string]$WorkspaceId,
        [string]$RemoteCommitHash,
        [string]$WorkspaceHead
    )
   
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
   
    $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git/updateFromGit"
    $response = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body ($body | ConvertTo-Json)
   
    if ($response.StatusCode -eq 202) {
        return $response.Headers['x-ms-operation-id']
    }
}
```

#### Wait-FabricOperation
```powershell
function Wait-FabricOperation {
    param (
        [string]$Token,
        [string]$OperationId,
        [int]$RetryAfterSeconds = 30,
        [int]$MaxAttempts = 20
    )
   
    $url = "https://api.fabric.microsoft.com/v1/operations/$OperationId"
    $attempts = 0
   
    do {
        $attempts++
        Start-Sleep -Seconds $RetryAfterSeconds
       
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
       
        if ($response.status -eq "Succeeded") {
            return $response
        }
        elseif ($response.status -eq "Failed") {
            throw "Operation failed: $($response.error.message)"
        }
    } while ($attempts -lt $MaxAttempts)
   
    throw "Operation timed out after $MaxAttempts attempts"
}
```

#### Get-FabricGitStatus
```powershell
function Get-FabricGitStatus {
    param (
        [string]$Token,
        [string]$WorkspaceId
    )
   
    $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git/status"
    $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
   
    # Returns:
    # - workspaceHead: Current workspace commit hash
    # - remoteCommitHash: Remote branch commit hash
    # - changes: Array of changed items with workspaceChange, remoteChange, conflictType
}
```

#### Evaluate-GitActions
```powershell
function Evaluate-GitActions {
    param ([PSCustomObject]$GitStatus)
   
    $actions = @{
        RequiresCommit = $false
        RequiresUpdate = $false
        HasConflicts = $false
        Message = ""
    }
   
    # No changes and matching hashes
    if ($GitStatus.changes.Count -eq 0 -and $GitStatus.workspaceHead -eq $GitStatus.remoteCommitHash) {
        $actions.Message = "No changes detected. Workspace and remote are in sync."
        return $actions
    }
   
    # Analyze changes
    $workspaceChanges = @($GitStatus.changes | Where-Object { $_.workspaceChange })
    $remoteChanges = @($GitStatus.changes | Where-Object { $_.remoteChange })
    $conflicts = @($GitStatus.changes | Where-Object { $_.conflictType -eq "Conflict" })
   
    if ($conflicts.Count -gt 0) {
        $actions.HasConflicts = $true
        $actions.Message = "Conflicts detected: $($conflicts.Count) items"
    }
   
    if ($workspaceChanges.Count -gt 0) {
        $actions.RequiresCommit = $true
        $actions.Message = "Workspace changes detected"
    }
   
    if ($remoteChanges.Count -gt 0 -and $GitStatus.workspaceHead -ne $GitStatus.remoteCommitHash) {
        $actions.RequiresUpdate = $true
        $actions.Message += " Remote changes detected"
    }
   
    return $actions
}
```

### Sync-IntegrationBranch Function

Creates/updates `integration-platform-services` branch with DevOps scripts and documentation:

```powershell
function Sync-IntegrationBranch {
    param (
        [string]$Token,
        [string]$Organization,
        [string]$Project,
        [string]$Repository
    )
   
    # Create temp directory
    $tempDir = Join-Path $env:TEMP "fabricsync_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force
   
    try {
        # Get Azure AD token for Git authentication
        $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        $authResult = Invoke-RestMethod -Method Post -Uri $tokenUrl -ContentType "application/x-www-form-urlencoded" -Body $encodedBody
       
        # Initialize repository
        Set-Location $tempDir
        git init
        git remote add origin $repoUrl
       
        # Check if integration branch exists
        $remoteRefs = git ls-remote --heads origin $integrationBranch
        $integrationExists = $remoteRefs -match $integrationBranch
       
        if ($integrationExists) {
            # Fetch and checkout existing branch
            git fetch origin $integrationBranch
            git checkout -b $integrationBranch --track origin/$integrationBranch
        } else {
            # Create new branch from main
            git fetch origin main:main
            git checkout -b $integrationBranch main
        }
       
        # Create directory structure
        New-Item -ItemType Directory -Path "src/fabric" -Force
        New-Item -ItemType Directory -Path "src/metadata" -Force
        New-Item -ItemType Directory -Path "src/ellie" -Force
       
        # Create README files
        Set-Content -Path "src/fabric/readme.md" -Value $readmeContent
        Set-Content -Path "src/metadata/readme.md" -Value $readmeMetadataContent
       
        # Fetch DevOpsServices, docs, src/metadata, src/ellie, .vscode folders from source branch
        git fetch origin $sourceBranch
        git checkout FETCH_HEAD -- DevOpsServices docs src/metadata src/ellie .vscode *.md
       
        # Add and commit changes
        git add -A
        $status = git status --porcelain
       
        if ($status) {
            git commit -m "feat: Sync DevOpsServices, docs, .vscode, src/ellie, src/metadata from $sourceBranch"
            git push -u origin $integrationBranch --force
        }
    }
    finally {
        # Clean up temp directory
        Set-Location $PSScriptRoot
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
```

**Purpose:** Maintain separate branch for pipeline scripts and documentation that syncs from feature/main branches.

### Git Integration Flow

```
1. Sync Integration Branch
   └── Create/update integration-platform-services branch with DevOps scripts

2. Connect Workspace to Git
   └── Link workspace to Azure DevOps repository

3. Initialize Connection
   └── Set up two-way sync (PreferRemote strategy)

4. Get Git Status
   └── Determine if commit or update needed

5. Evaluate Actions
   ├── HasConflicts? → Manual resolution required
   ├── RequiresCommit? → Commit workspace changes to Git
   └── RequiresUpdate? → Update workspace from Git

6. Execute Action
   ├── Commit: Invoke-FabricGitCommit → Wait-FabricOperation
   └── Update: Update-FabricFromGit → Wait-FabricOperation
```

### Conflict Resolution

```powershell
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
```

**Strategies:**
- **PreferWorkspace**: Keep workspace version in conflicts
- **PreferRemote**: Keep Git version in conflicts

### Git Configuration for Windows

```powershell
function Initialize-GitConfiguration {
    # Clear proxy settings
    git config --global --unset http.proxy
    git config --global --unset https.proxy
   
    # Clear environment variables
    [Environment]::SetEnvironmentVariable("http_proxy", $null, "Process")
    [Environment]::SetEnvironmentVariable("https_proxy", $null, "Process")
   
    # Configure Windows-specific settings
    git config --global core.autocrlf true        # Handle line endings
    git config --global core.longpaths true       # Handle long paths
    git config --global core.packedGitLimit 512m
    git config --global http.postBuffer 524288000
}
```

---

## Cross-Script Integration Patterns

### Pattern 1: Token Reuse

Each script retrieves its own token rather than reusing a shared token:

**Why not share tokens?**
- **Isolation**: Each script is self-contained and independently executable
- **Debugging**: Easier to test individual scripts in isolation
- **Resilience**: Token refresh handled per-script, not pipeline-wide
- **Simplicity**: No need for token expiration logic or refresh coordination

**Token Lifetime**: Fabric API tokens are valid for ~1 hour, sufficient for entire pipeline execution.

### Pattern 2: Folder ID Resolution

Multiple scripts need to place items in folders:

```powershell
# Common function across scripts
function Get-FolderIdByPath {
    param([string]$FolderPath, [string]$FolderHierarchy)
    
    # Parse folder hierarchy JSON
    $folders = $FolderHierarchy | ConvertFrom-Json
    
    # Normalize path separators
    $FolderPath = $FolderPath -replace '\\', '/'
    
    # Find matching folder
    $matchingFolder = $folders | Where-Object { $_.Path -eq $FolderPath }
    
    return $matchingFolder.Id
}
```

**Execution Flow:**
1. `Fabric-FolderSynchronization.ps1` runs → returns `FOLDER_HIERARCHY` JSON
2. Pipeline stores JSON in variable
3. `Invoke-EnvironmentManagement.ps1` receives JSON via parameter
4. Script calls `Get-FolderIdByPath` to resolve folder ID
5. Environment created in correct folder

Same pattern used by lakehouse, notebook, semantic model, and report management scripts.

### Pattern 3: Retry with Exponential Backoff

All scripts implement consistent retry logic (covered in [Common Patterns](#common-patterns--principles)).

### Pattern 4: Structured Logging

All scripts use Azure DevOps logging commands (covered in [Common Patterns](#common-patterns--principles)).

---

## Error Handling Philosophy

### Fail Fast vs. Continue on Error

#### Fail Fast Scenarios

```powershell
if ([string]::IsNullOrEmpty($token)) {
    Write-Error "Failed to get Fabric token"
    exit 1  # Immediate failure
}
```

**When to fail fast:**
- Authentication failures
- Missing required parameters
- Workspace not found in selective deployment mode

#### Continue on Error Scenarios

```powershell
try {
    Add-WorkspaceRoleAssignment -PrincipalId $principalId -Role "Admin"
    $results.Added++
} catch {
    Write-Warning "Failed to add role assignment: $_"
    $results.Failed++
    # Continue processing remaining principals
}
```

**When to continue:**
- Role assignment failures (some principals may be invalid)
- Folder synchronization errors (some folders may fail, others succeed)
- Notebook deployment errors (deploy what succeeds, report what fails)

### Summary Reporting

Scripts return structured results for pipeline reporting:

```powershell
$syncResults = @{
    Added = 5
    Skipped = 3
    Failed = 1
    Errors = @("Failed to add principal abc-123: Principal not found")
}

return $syncResults | ConvertTo-Json
```

**Pipeline can then:**
- Display summary in logs
- Set pipeline result (success/partial failure/failure)
- Send notifications with detailed error counts

---

## Performance Optimization

### Parallel API Calls

**Problem:** Creating 20 lakehouses sequentially takes 20 × 30 seconds = 10 minutes

**Solution:** PowerShell parallel processing

```powershell
# NOT IMPLEMENTED in current scripts, but possible pattern:
$lakehouses | ForEach-Object -Parallel {
    Invoke-LakehouseManagement.ps1 -DisplayName $_.Name
} -ThrottleLimit 5
```

Current scripts use **sequential processing** for reliability and debuggability.

### Caching Token Retrieval

**Current Approach:** Each script retrieves its own token

**Optimization Opportunity:** Cache token in temp file, reuse if not expired

```powershell
# Potential optimization (not implemented):
function Get-CachedFabricToken {
    $tokenFile = "$env:TEMP/fabric-token.json"
    
    if (Test-Path $tokenFile) {
        $cached = Get-Content $tokenFile | ConvertFrom-Json
        $expiry = [DateTime]::Parse($cached.ExpiresOn)
        
        if ($expiry -gt (Get-Date).AddMinutes(5)) {
            return $cached.Token  # Reuse cached token
        }
    }
    
    # Retrieve new token
    $token = Get-FabricAccessToken
    $expiry = (Get-Date).AddHours(1)
    
    @{ Token = $token; ExpiresOn = $expiry } | ConvertTo-Json | Set-Content $tokenFile
    
    return $token
}
```

**Trade-off:** Reduced API calls vs. increased complexity

---

## Script Extensibility

### Adding New Resource Types

To add support for a new Fabric resource type (e.g., Data Warehouses):

#### 1. Create Management Script

```powershell
# Invoke-DataWarehouseManagement.ps1
param([string]$Action, [string]$WorkspaceId, [string]$DisplayName)

function Create-DataWarehouse {
    # POST https://api.fabric.microsoft.com/v1/workspaces/{id}/datawarehouses
}

function Get-DataWarehouseIdByName {
    # GET https://api.fabric.microsoft.com/v1/workspaces/{id}/datawarehouses
}

# Implement CreateOrUpdate pattern
```

#### 2. Add Pipeline Task

```yaml
- task: PowerShell@2
  displayName: 'Create Fabric Data Warehouses'
  inputs:
    script: |
      $scriptPath = "Invoke-DataWarehouseManagement.ps1"
      & $scriptPath -Action CreateOrUpdate -WorkspaceId $WorkspaceId -DisplayName "prod_warehouse"
```

#### 3. Update Folder Sync

```powershell
# In Fabric-FolderSynchronization.ps1
$supportedArtifactTypes = @(
    "SemanticModel", "Report", "Lakehouse", "Notebook", "Environment",
    "DataWarehouse"  # Add new type
)
```

### Custom Retry Logic

To add custom retry behavior for specific errors:

```powershell
function Invoke-FabricApiWithRetry {
    # ... existing code ...
    
    # Add custom error handling
    if ($errorResponse.Contains('ConflictError')) {
        Write-Host "Resource conflict detected, waiting for reconciliation..."
        Start-Sleep -Seconds 60
        $attempt++
        continue
    }
}
```

---

## Security Considerations

### Credential Management

**Service Principal Credentials:**
- Stored as Azure DevOps pipeline secrets
- Injected as environment variables at runtime
- Never written to logs or disk

```powershell
$clientId = $env:ARM_CLIENT_ID
$clientSecret = $env:ARM_CLIENT_SECRET
$tenantId = $env:ARM_TENANT_ID

# az login uses these credentials
# Token stored in memory only, not persisted
```

### Token Handling

**Fabric API Tokens:**
- Retrieved on-demand per script
- Stored in memory as PowerShell variables
- Automatically garbage collected after script execution
- Not written to pipeline variables (would expose in logs)

### Least Privilege

**Service Principal Permissions Required:**
- **Fabric API**: Workspace Admin on target workspaces
- **Azure AD**: No additional permissions (uses delegated access)
- **Azure CLI**: Login-only (no Azure subscription permissions needed)

**Why Workspace Admin?**
- Create/update resources (environments, lakehouses, notebooks)
- Manage role assignments
- Configure Spark settings

**Not Required:**
- Fabric Capacity Admin (capacity assignment handled separately)
- Azure Subscription Contributor (uses Fabric APIs only)

---

## Conclusion

This deep dive demonstrates how these PowerShell scripts work together to orchestrate a complete Microsoft Fabric deployment, from workspace provisioning through resource creation to configuration management—all with robust error handling, retry logic, and state tracking.

**Key Takeaways:**

1. **Consistent Architecture**: All scripts follow the same pattern (authentication → API wrappers → business logic → main execution)
2. **Idempotency**: CreateOrUpdate pattern enables safe re-runs
3. **Resilience**: Exponential backoff retry logic handles transient failures
4. **Observability**: Structured logging provides detailed execution traces
5. **Security**: Least-privilege service principal, credentials never written to disk
6. **Extensibility**: Adding new resource types follows established patterns

**Total Scripts Coverage:** 12+ core scripts managing complete Fabric infrastructure lifecycle.

---

**Document Version:** 1.0  
**Last Updated:** January 2026  
**Author:** Platform Services Team
