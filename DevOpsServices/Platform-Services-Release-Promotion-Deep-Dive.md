# Platform Services: Release Branch Promotion - Deep Dive

---

## Table of Contents

### Architecture Foundation
1. [Release Promotion Overview](#release-promotion-overview)
2. [multi-project Deployment Strategy](#multi-project-deployment-strategy)
3. [Common Patterns & Principles](#common-patterns-and-principles)

### Pipeline Orchestration
4. [Pipeline 1: Deploy-release-subdomain.yml](#pipeline-1-deploy-release-subdomain-yml)
5. [Pipeline 2: Deploy-release-branch.yml](#pipeline-2-deploy-release-branch-yml)

### Automation Scripts
6. [Script 1: Deploy-ReleaseBranch.ps1](#script-1-deploy-releasebranch-ps1)
7. [Script 2: Copy-VariableGroup.ps1](#script-2-copy-variablegroup-ps1)
8. [Script 3: Create-AzDevOpsEnvironment.ps1](#script-3-create-azdevopsenvironment-ps1)
9. [Script 4: Create-ReleasePipeline.ps1](#script-4-create-releasepipeline-ps1)
10. [Script 5: Create-Pipeline.ps1](#script-5-create-pipeline-ps1)

### Integration & Advanced Topics
11. [Release Branch Lifecycle](#release-branch-lifecycle)
12. [Variable Group Management](#variable-group-management)
13. [Security & Approval Workflows](#security-and-approval-workflows)
14. [Multi-Repository Coordination](#multi-repository-coordination)
15. [Error Handling & Rollback Strategies](#error-handling-and-rollback-strategies)

---

## Release Promotion Overview

The Platform Services release promotion architecture implements a multi-project deployment model that enables controlled rollout of infrastructure code changes across multiple domains (tenants) with different Azure DevOps projects and repositories.

### Key Concepts

**Release Branch:** A versioned branch (e.g., `release/platform-services-v1.0.0`) containing tested infrastructure code ready for deployment to target domains.

**Super Domain:** High-level organizational boundary (e.g., "DnA Distribution", "DnA Claims").

**Sub-Domain:** Specific tenant within a super domain (e.g., "DnA Distro - Del Auth", "DnA Claims - Claims Handling").

**Variable Group:** Azure DevOps variable collection containing environment-specific configuration (workspace names, capacity IDs, security groups, etc.).

**Environment:** Azure DevOps approval gate for lifecycle management (e.g., INT/DEV/QA/UAT/PRD environments require approval).

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  Source Repository (PlatformServices-Fabric)                │
│  - release/platform-services-v1.0.0 (source code)           │
└───────────────────┬─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  Deploy-release-subdomain.yml (Orchestration Pipeline)      │
│  - Reads subdomain config files (JSON)                      │
│  - Creates dynamic matrix of target deployments             │
│  - Executes parallel deployment jobs                        │
└───────────────────┬─────────────────────────────────────────┘
                    │
        ┌───────────┴───────────┬─────────────┐
        ▼                       ▼             ▼
┌──────────────────┐   ┌──────────────────┐  ┌──────────────────┐
│ Target Domain 1  │   │ Target Domain 2  │  │ Target Domain N  │
│ - Copy branch    │   │ - Copy branch    │  │ - Copy branch    │
│ - Copy variables │   │ - Copy variables │  │ - Copy variables │
│ - Create pipeline│   │ - Create pipeline│  │ - Create pipeline│
│ - Setup approval │   │ - Setup approval │  │ - Setup approval │
└──────────────────┘   └──────────────────┘  └──────────────────┘
```

### Deployment Flow

```
1. Source Branch Creation
   └── release/platform-services-v1.0.0 created in PlatformServices-Fabric repo

2. Validation Stage
   ├── Validate branch name format
   └── Validate semantic versioning (v{major}.{minor}.{patch})

3. Subdomain Discovery
   ├── Scan DevOpsServices/pipelines/subdomains/*.json
   ├── Parse configuration for each subdomain
   └── Build deployment matrix

4. Parallel Deployment (per subdomain)
   ├── Deploy-release-branch.yml template
   │   ├── Deploy-ReleaseBranch.ps1 (Git operations)
   │   ├── Copy-VariableGroup.ps1 (Configuration)
   │   └── Create-AzDevOpsEnvironment.ps1 (Approval gates)
   │
   ├── Create-ReleasePipeline.ps1 (Infrastructure pipeline)
   └── Create-Pipeline.ps1 (Release branch creation pipeline)


5. Result
   └── Each subdomain has:
       ├── Release branch in target repository
       ├── Variable group with customized configuration
       ├── Approval environments (lifecycleManagementApproval, featureManagementApproval)
       ├── Infrastructure deployment pipeline
       └── Release branch creation pipeline
```

---

## multi-project Deployment Strategy

### Subdomain Configuration Files

Each subdomain is defined by a JSON configuration file in `DevOpsServices/pipelines/subdomains/`:

**Example: `claims_handling_dev.json`**
```json
{
  "targetVariableGroup": "PlatformServices-ClaimsHandling-DEV",
  "targetWorkspaceName": "Claims-ClaimsHandling-DEV",
  "targetSuperDomain": "Claims",
  "targetSubDomain": "Claims Handling",
  "targetProject": "DnA Claims",
  "targetRepository": "DnA Claims - Claims Handling",
  "environment": "dev",
  "adminGroupPrincipalIds": "guid-1,guid-2,guid-3",
  "contributorGroupPrincipalIds": "guid-4,guid-5",
  "viewerGroupPrincipalIds": "guid-6",
  "capacityId": "capacity-guid",
  "keyvaultName": "bhg-dev-claimshdl-eus-kv",
  "requiredSecurityGroup": "GUARD DnA - Claims Claims Handling - Data Product Arch",
  "optionalSecurityGroup": "GUARD DnA - Fluidity - PlatSvc DevOps",
  "pep": [
    {  
        "allowed": false,
        "resourceId": "",    
        "subresourceType": "vault"
    },
    {  
        "allowed": false,
        "resourceId": "",    
        "subresourceType": "blob"
    }        
    ]
}
```

**Configuration Properties:**

| Property | Description | Example |
|----------|-------------|---------|
| `targetVariableGroup` | Name of variable group to create/update in target project | `"PlatformServices-ClaimsHandling-DEV"` |
| `targetWorkspaceName` | Fabric workspace name for this subdomain | `"Claims-ClaimsHandling-DEV"` |
| `targetSuperDomain` | High-level domain name | `"Claims"` |
| `targetSubDomain` | Specific subdomain identifier | `"Claims Handling"` |
| `targetProject` | Target Azure DevOps project | `"Claims Handling"` |
| `targetRepository` | Target Git repository | `"DnA Claims - Claims Handling"` |
| `environment` | Environment identifier (DEV/INT/PRD) | `"dev"` |
| `adminGroupPrincipalIds` | Comma-separated Azure AD group GUIDs for Admin role | `"guid-1,guid-2"` |
| `contributorGroupPrincipalIds` | Comma-separated Azure AD group GUIDs for Contributor role | `"guid-3,guid-4"` |
| `viewerGroupPrincipalIds` | Comma-separated Azure AD group GUIDs for Viewer role | `"guid-5,guid-6"` |
| `capacityId` | Fabric capacity GUID | `"capacity-guid"` |
| `keyvaultName` | Azure Key Vault name for secrets | `"bhg-dev-claimshdl-eus-kv"` |
| `requiredSecurityGroup` | Security group required for pipeline approvals | `"GUARD DnA - Claims Claims Handling - Data Product Arch"` |
| `optionalSecurityGroup` | Optional security group for pipeline approvals | `"GUARD DnA - Fluidity - PlatSvc DevOps"` |
| `pep` | Array of private endpoint configurations | See example above |

### Deployment Matrix Strategy

The pipeline uses Azure DevOps matrix strategy to deploy to multiple subdomains in parallel:

```yaml
jobs:
- job: generator
  steps:
  - task: PowerShell@2
    name: mtrx
    script: |
      # Read all subdomain JSON files
      $files = Get-ChildItem 'DevOpsServices/pipelines/subdomains' -Filter *.json
      
      # Build hashtable for matrix
      $file_hash = @{}
      foreach ($f in $files) {
        $parameters = Get-Content $f.FullName | ConvertFrom-Json
        $file_hash.add($f.BaseName, @{...})
      }
      
      # Convert to JSON and output as matrix variable
      $json = $file_hash | ConvertTo-Json -Compress -Depth 10
      echo "##vso[task.setVariable variable=legs;isOutput=true]$json"

- job: deploy
  dependsOn: generator
  strategy:
    maxParallel: 5  # Deploy to 5 subdomains concurrently
    matrix: $[ dependencies.generator.outputs['mtrx.legs'] ]
  steps:
    # Deploy to each subdomain using matrix variables
```

**Benefits:**
- **Parallel execution**: Deploy to multiple tenants simultaneously (max 5 concurrent)
- **Dynamic discovery**: Add new subdomain by creating JSON file (no pipeline changes)
- **Isolated failures**: One subdomain failure doesn't block others
- **Consistent configuration**: Same deployment logic for all tenants

---

## Common Patterns and Principles

### 1. Azure DevOps Authentication Pattern

All scripts use OAuth 2.0 client credentials flow for Azure DevOps API authentication:

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
    $token = $response.access_token
    
    # Convert to Base64 for Basic authentication header
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token"))
    
    return $base64AuthInfo
}
```

**Why Base64 encoding?** Azure DevOps REST API uses Basic authentication with empty username and token as password.

### 2. URL Encoding for Azure DevOps API

Project names and repository names may contain spaces or special characters:

```powershell
function Format-GitUrl {
    param ([string]$value)
    return $value.Replace(' ', '%20')
}

# Usage
$encodedProject = Format-GitUrl -value "DnA Claims"
# Result: "DnA%20Claims"

$apiUrl = "https://dev.azure.com/$Organization/$encodedProject/_apis/..."
```

### 3. Git Credential Management

Git operations use bearer token authentication with cleanup:

```powershell
# Configure git to use bearer token
git config --global http.extraHeader "AUTHORIZATION: Bearer $Token"

# Perform git operations
git clone $sourceUrl
git push $targetUrl

# Cleanup credentials (critical for security)
function Git-Cleanup {
    git config --global --unset-all http.extraheader
    git config --global --unset-all http.https://dev.azure.com.extraheader
    git config --global credential.helper ""
    git config --global core.askPass ""
}
```

**Why cleanup?** Prevents token leakage to other processes or pipeline steps.

### 4. Conditional Execution Pattern

Scripts execute only for INT environment to avoid accidental production deployments:

```powershell
# Only execute for INT environment
if (-not ($WorkspaceName -match 'INT')) {
    Write-Host "Skipping pipeline creation for $WorkspaceName"
    exit 0
}

# Only execute for INT environment (alternative check)
if (-not ($Environment -match 'INT')) {
    Write-Host "Skipping environment creation for $Environment"
    exit 0
}
```

**Why?** Production deployments require manual review and approval through established processes.

### 5. Temporary Directory Management

Scripts create isolated temporary directories to avoid conflicts:

```powershell
$tempFolder = Join-Path $WorkDir "temp_$versionNumber"

try {
    New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
    Set-Location $tempFolder
    
    # Perform operations in isolated directory
    
} finally {
    Set-Location $WorkDir
    if (Test-Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force
    }
}
```

---

## Pipeline 1 Deploy-release-subdomain-yml

### Purpose
Main orchestration pipeline that coordinates release branch deployment across multiple subdomains using dynamic matrix strategy.

### Parameters

```yaml
parameters:
- name: organizationName
  displayName: 'Organization Name'
  type: string
  default: 'BHGDataAndAnalytics'

- name: variableGroup
  displayName: 'Source Variable Group'
  type: string
  default: 'PlatformServices'

- name: sourceBranch
  type: string
  displayName: 'Source Release Branch'
  default: 'release/platform-services-v1.0.0'
```

### Pool Configuration

```yaml
variables:
  - name: agentPool
    value: GDAP-Fluidity-PlatformServices_Self-hosted-AgentPool

pool:
  name: $(agentPool)
  vmImage: windows-latest
```

**Why self-hosted pool?** Git operations require network access to Azure DevOps repositories. Self-hosted agents have proper network configuration and authentication.

### Stages

#### Stage 1: Validate

**Purpose:** Validate source branch name follows semantic versioning pattern.

```yaml
- stage: Validate
  displayName: 'Validate Parameters'
  jobs:
  - job: validate_parameters
    steps:
     
    - checkout: self
      persistCredentials: true
      fetchDepth: 0
      clean: true  # Ensure clean checkout

    - task: PowerShell@2
      displayName: 'Validate Source Branch'
      inputs:
        targetType: 'inline'
        script: |
          Write-Host "Validating source branch format..."
          $sourceBranch = "${{ parameters.sourceBranch }}"
       
          # Validate branch name format
          if (-not ($sourceBranch -match 'release/platform-services-v\d+\.\d+\.\d+')) {
              Write-Error "Invalid branch name format. Expected: release/platform-services-v{major}.{minor}.{patch}"
              exit 1
          }
```

**Pattern:** `release/platform-services-v1.0.0`
- Prefix: `release/platform-services-v`
- Version: `{major}.{minor}.{patch}` (semantic versioning)

**Checkout options:**
- `persistCredentials: true` → Keep Git credentials for subsequent operations
- `fetchDepth: 0` → Fetch complete history (not shallow clone)
- `clean: true` → Remove untracked files from previous runs

#### Stage 2: Deploy

**Job 1: Generator**

Discovers subdomain configuration files and builds deployment matrix:

```yaml
- job: generator
  steps:

  - checkout: self
    persistCredentials: true
    fetchDepth: 0
    clean: true

  - task: PowerShell@2
    displayName: Get all sub-domain config files
    inputs:
      targetType: 'inline'
      script: |
        $files = Get-ChildItem '$(Build.SourcesDirectory)/DevOpsServices/pipelines/subdomains' -Recurse -Filter *.json | Select-Object BaseName, FullName
        $file_hash = @{}
        
        foreach ($f in $files) {
          $parameters = Get-Content $f.FullName | Out-String | ConvertFrom-Json
         
          # Convert the pep array to a proper JSON string and escape it
          $pepJson = if ($parameters.pep -ne $null) {
              $pepString = $parameters.pep | ConvertTo-Json -Compress -Depth 10
              # Double escape for matrix compatibility
              $pepString
          } else {
              '[]'
          }
         
          $file_hash.add($f.BaseName, @{
              "file_path" = $f.FullName
              "targetVariableGroup" = $parameters.targetVariableGroup
              "targetWorkspaceName" = $parameters.targetWorkspaceName
              "targetSuperDomain" = $parameters.targetSuperDomain
              "targetSubDomain" = $parameters.targetSubDomain
              "targetProject" = $parameters.targetProject
              "targetRepository" = $parameters.targetRepository
              "environment" = $parameters.environment
              "adminGroupPrincipalIds" = $parameters.adminGroupPrincipalIds
              "contributorGroupPrincipalIds" = $parameters.contributorGroupPrincipalIds
              "capacityId" = $parameters.capacityId
              "keyvaultName" = $parameters.keyvaultName
              "pep" = $pepJson
              "requiredSecurityGroup" = $parameters.requiredSecurityGroup
              "optionalSecurityGroup" = $parameters.optionalSecurityGroup
              "viewerGroupPrincipalIds" = $parameters.viewerGroupPrincipalIds                
            }
          )
        }
       
        # Convert to JSON with higher depth limit
        $json = $file_hash | ConvertTo-Json -Compress -Depth 10
       
        # Debug - output the resulting JSON to the pipeline logs
        Write-Host "Generated matrix JSON:"
        Write-Host $json
       
        echo "##vso[task.setVariable variable=legs;isOutput=true]$json"
        Write-Host "##vso[task.setvariable variable=SUBDOMAINS]$json"
    name: mtrx
```

**Key Points:**
- Uses `BaseName` as matrix key (filename without extension)
- Reads all `*.json` files from `DevOpsServices/pipelines/subdomains/`
- Converts PEP (Private Endpoint) array to JSON string for matrix compatibility
- Outputs matrix as `legs` variable for consumption by deploy job
- Also sets `SUBDOMAINS` variable for debugging

**Matrix Key Requirements:**
- Must contain only A-Z, a-z, 0-9, underscore (_)
- Must start with a letter
- Must be 100 characters or less
- Filename serves as matrix key (e.g., `claims_handling_dev.json` → `claims_handling_dev`)

**Job 2: Deploy**

Executes deployment for each subdomain in parallel:

```yaml
- job: deploy
  dependsOn: generator
  strategy:
    maxParallel: 5
    matrix: $[ dependencies.generator.outputs['mtrx.legs'] ]
  variables:
  - group: ${{ parameters.variableGroup }}
  - name: workingDirectory
    value: $(System.DefaultWorkingDirectory)
  steps:
    # Step 1: Deploy release branch using template
    - template: deploy-release-branch.yml
      parameters:
        variableGroup: ${{ parameters.variableGroup }}
        targetVariableGroup: $(targetVariableGroup)
        targetWorkspaceName: $(targetWorkspaceName)
        targetSuperDomain: $(targetSuperDomain)
        targetSubDomain: $(targetSubDomain)
        sourceBranch: ${{ parameters.sourceBranch }}
        targetProject: $(targetProject)
        targetRepository: $(targetRepository)
        environment: $(environment)
        adminGroupPrincipalIds: $(adminGroupPrincipalIds)
        contributorGroupPrincipalIds: $(contributorGroupPrincipalIds)
        capacityId: $(capacityId)
        keyvaultName: $(keyvaultName)
        pep: $(pep)
        requiredSecurityGroup: $(requiredSecurityGroup)
        optionalSecurityGroup: $(optionalSecurityGroup)
        viewerGroupPrincipalIds: $(viewerGroupPrincipalIds)

    # Step 2: Checkout code for subsequent tasks
    - checkout: self
      persistCredentials: true
      fetchDepth: 0
      clean: true

    # Step 3: Create release pipeline for infrastructure deployment
    - task: PowerShell@2
      displayName: 'Create Subdomain Release Pipeline'
      inputs:
        targetType: 'filePath'
        filePath: '$(System.DefaultWorkingDirectory)/DevOpsServices/pipelines/scripts/Create-ReleasePipeline.ps1'
        workingDirectory: '$(System.DefaultWorkingDirectory)/DevOpsServices/pipelines/scripts'
        arguments: >
          -Organization "${{ parameters.organizationName }}"
          -Project "$(targetProject)"
          -PipelineName "$(targetProject) - $(targetSubDomain)"
          -ReleaseVersion "${{ parameters.sourceBranch }}"
          -RepositoryName "$(targetRepository)"
          -WorkspaceName "$(targetWorkspaceName)"
          -VariableGroup "$(targetVariableGroup)"
      env:
        ARM_CLIENT_ID: $(ARM_CLIENT_ID)
        ARM_CLIENT_SECRET: $(ARM_CLIENT_SECRET)
        ARM_TENANT_ID: $(ARM_TENANT_ID)
        ARM_SUBSCRIPTION_ID: $(ARM_SUBSCRIPTION_ID)

    # Step 4: Create release branch creation pipeline
    - task: PowerShell@2
      displayName: 'Create subdomain release branch pipeline'
      inputs:
        targetType: 'filePath'
        filePath: '$(System.DefaultWorkingDirectory)/DevOpsServices/pipelines/scripts/Create-Pipeline.ps1'
        workingDirectory: '$(System.DefaultWorkingDirectory)/DevOpsServices/pipelines/scripts'
        arguments: >
          -Organization "${{ parameters.organizationName }}"
          -Project "$(targetProject)"
          -PipelineName "Create subdomain release branch - $(targetSubDomain)"
          -ReleaseVersion "${{ parameters.sourceBranch }}"
          -RepositoryName "$(targetRepository)"
          -WorkspaceName "$(targetWorkspaceName)"
          -VariableGroupName "$(targetVariableGroup)"
          -YamlPath "DevOpsServices/pipelines/release/create-subdomain-release-branch.yml"
      env:
        ARM_CLIENT_ID: $(ARM_CLIENT_ID)
        ARM_CLIENT_SECRET: $(ARM_CLIENT_SECRET)
        ARM_TENANT_ID: $(ARM_TENANT_ID)
        ARM_SUBSCRIPTION_ID: $(ARM_SUBSCRIPTION_ID)
```

**Matrix Execution:**
- `maxParallel: 5` → Deploy to 5 subdomains concurrently
- Each matrix entry becomes a separate job with unique variables
- Matrix variables from generator become job-level variables (e.g., `$(targetProject)`, `$(targetSubDomain)`)

**Environment Variables Pattern:**
All PowerShell scripts receive service principal credentials via environment variables:
- `ARM_CLIENT_ID` → Service principal application ID
- `ARM_CLIENT_SECRET` → Service principal secret
- `ARM_TENANT_ID` → Azure AD tenant ID
- `ARM_SUBSCRIPTION_ID` → Azure subscription ID (for Key Vault access)

**Working Directory:**
- `workingDirectory` variable ensures scripts run from correct location
- `$(System.DefaultWorkingDirectory)` → Repository root directory

### Output Artifacts

For each subdomain, the pipeline creates:

1. **Release Branch** in target repository
2. **Variable Group** with customized configuration
3. **Approval Environments** (lifecycleManagementApproval, featureManagementApproval)
4. **Infrastructure Pipeline** (`{Project} - {Subdomain}`)
5. **Release Branch Creation Pipeline** (`Create subdomain release branch - {Subdomain}`)

---

## Pipeline 2 Deploy-release-branch-yml

### Purpose
Reusable template that deploys a release branch to a single target subdomain. Called by the main orchestration pipeline for each matrix entry.

### Parameters

```yaml
parameters:
- name: variableGroup          # Source variable group name
- name: targetVariableGroup    # Target variable group name
- name: targetWorkspaceName    # Target Fabric workspace name
- name: targetSuperDomain      # Super domain name
- name: targetSubDomain        # Subdomain name
- name: sourceBranch           # Source release branch
- name: sourceOrganization     # Source Azure DevOps organization
- name: sourceProject          # Source Azure DevOps project
- name: sourceRepository       # Source repository name
- name: targetOrganization     # Target Azure DevOps organization
- name: targetProject          # Target Azure DevOps project
- name: targetRepository       # Target repository name
- name: environment            # Environment (INT/PRD)
- name: capacityId             # Fabric capacity ID
- name: keyvaultName           # Key Vault name
- name: adminGroupPrincipalIds # Admin group GUIDs
- name: contributorGroupPrincipalIds  # Contributor group GUIDs
- name: viewerGroupPrincipalIds       # Viewer group GUIDs
- name: pep                    # Private endpoint configurations (JSON)
- name: requiredSecurityGroup  # Required approval security group
- name: optionalSecurityGroup  # Optional approval security group
```

### Execution Steps

#### Step 1: Authentication Setup

```yaml
- template: ../templates/auth-setup.yml
```

Sets up authentication context for subsequent tasks (service principal credentials).

#### Step 2: Deploy Release Branch

```yaml
- task: PowerShell@2
  name: DeployBranch
  displayName: 'Deploy Release Branch'
  inputs:
    filePath: 'Deploy-ReleaseBranch.ps1'
    arguments: >
      -SourceBranch "${{ parameters.sourceBranch }}"
      -SourceOrganization "${{ parameters.sourceOrganization }}"
      -SourceProject "${{ parameters.sourceProject }}"
      -SourceRepository "${{ parameters.sourceRepository }}"
      -TargetOrganization "${{ parameters.targetOrganization }}"
      -TargetProject "${{ parameters.targetProject }}"
      -TargetRepository "${{ parameters.targetRepository }}"
```

**Performs:**
- Clones source branch from source repository
- Creates release branch in target repository
- Returns target branch name as output variable

#### Step 3: Prepare PEP Parameter

```yaml
- task: PowerShell@2
  displayName: 'Prepare PEP Parameter'
  name: preparePEP
  script: |
    $pepJson = '${{ parameters.pep }}'
    $pepArray = $pepJson | ConvertFrom-Json
    
    # Validate array structure
    if ($pepArray -isnot [System.Array]) {
        $pepArray = @($pepArray)
    }
    
    # Validate required fields
    foreach ($entry in $pepArray) {
        if (-not (($entry.PSObject.Properties.Name -contains "allowed") -and
                  ($entry.PSObject.Properties.Name -contains "resourceId") -and
                  ($entry.PSObject.Properties.Name -contains "subresourceType"))) {
            Write-Error "Missing required PEP fields"
            exit 1
        }
    }
    
    # Write to temp file to avoid escaping issues
    $tempFile = Join-Path $env:TEMP "pep_data.json"
    Set-Content -Path $tempFile -Value ($pepArray | ConvertTo-Json -Compress)
    Write-Host "##vso[task.setvariable variable=pepJsonFilePath]$tempFile"
```

**Why temp file?** Command-line escaping of complex JSON is error-prone. Using a file path is more reliable.

#### Step 4: Copy Variable Group

```yaml
- task: PowerShell@2
  displayName: 'Copy Variable Group'
  name: copyVariableGroup
  inputs:
    filePath: 'Copy-VariableGroup.ps1'
    arguments: >
      -SourceOrg "${{ parameters.sourceOrganization }}"
      -SourceProject "${{ parameters.sourceProject }}"
      -SourceGroupName "${{ parameters.variableGroup }}"
      -TargetOrg "${{ parameters.targetOrganization }}"
      -TargetProject "${{ parameters.targetProject }}"
      -TargetGroupName "${{ parameters.targetVariableGroup }}"
      -TargetWorkspaceName "${{ parameters.targetWorkspaceName }}"
      -TargetParentDomainName "${{ parameters.targetSuperDomain }}"
      -TargetChildDomainName "${{ parameters.targetSubDomain }}"
      -TargetRepository "${{ parameters.targetRepository }}"
      -Environment "${{ parameters.environment }}"
      -AdminGroupPrincipalIds "${{ parameters.adminGroupPrincipalIds }}"
      -ContributorGroupPrincipalIds "${{ parameters.contributorGroupPrincipalIds }}"
      -ViewerGroupPrincipalIds "${{ parameters.viewerGroupPrincipalIds }}"
      -CapacityId "${{ parameters.capacityId }}"
      -KeyvaultName "${{ parameters.keyvaultName }}"
      -PepFilePath "$(pepJsonFilePath)"
```

**Performs:**
- Copies source variable group to target project
- Customizes variables for target subdomain
- Flattens PEP array into individual variables

#### Step 5: Create Environment Checks

```yaml
- task: PowerShell@2
  displayName: 'Create Environment Checks Approval'
  name: createEnvironmentApproval
  inputs:
    filePath: 'Create-AzDevOpsEnvironment.ps1'
    arguments: >
      -Organization "${{ parameters.targetOrganization }}"
      -ProjectName "${{ parameters.targetProject }}"
      -RequiredSecurityGroup "${{ parameters.requiredSecurityGroup }}"
      -OptionalSecurityGroup "${{ parameters.optionalSecurityGroup }}"
      -Environment "${{ parameters.environment }}"
```

**Performs:**
- Creates `lifecycleManagementApproval` environment
- Creates `featureManagementApproval` environment
- Configures approval checks with security groups
- Sets 3-day timeout for approvals

---

## Script 1 Deploy-ReleaseBranch-ps1

### Purpose
Handles Git operations to clone source release branch and push to target repository. Uses bearer token authentication and temporary isolated directories.

### Parameters

```powershell
param (
    [Parameter(Mandatory=$true)]
    [string]$SourceBranch,           # release/platform-services-v1.0.0
    [Parameter(Mandatory=$true)]
    [string]$SourceOrganization,     # BHGDataAndAnalytics
    [Parameter(Mandatory=$true)]
    [string]$SourceProject,          # GDAP-Fluidity-PlatformServices
    [Parameter(Mandatory=$true)]
    [string]$SourceRepository,       # PlatformServices-Fabric
    [Parameter(Mandatory=$true)]
    [string]$TargetOrganization,     # BHGDataAndAnalytics
    [Parameter(Mandatory=$true)]
    [string]$TargetProject,          # DnA Claims
    [Parameter(Mandatory=$true)]
    [string]$TargetRepository,       # DnA Claims-Claims Handling
    [Parameter(Mandatory=$false)]
    [string]$WorkingDirectory = $PWD
)
```

### Key Functions

#### Get-DevOpsAuthToken

```powershell
function Get-DevOpsAuthToken {
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
```

Returns raw access token (not Base64-encoded like other scripts) for Git bearer authentication.

#### Git-Cleanup

```powershell
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
            return $true
        }
    }
    
    # Reset configurations
    Set-GitConfig 'config --global --unset-all http.extraheader'
    Set-GitConfig 'config --global --unset-all http.https://dev.azure.com.extraheader'
    Set-GitConfig 'config --global credential.helper ""'
    Set-GitConfig 'config --global core.askPass ""'
}
```

**Why critical?** Prevents token leakage to subsequent pipeline steps or other processes. Always called in `finally` block.

#### Deploy-ReleaseBranch

```powershell
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
    
    # Extract version number from branch name
    if ($SourceBranch -match 'v(\d+\.\d+\.\d+)') {
        $versionNumber = $matches[1]
    } else {
        throw "Could not extract version number from branch name: $SourceBranch"
    }
    
    $tempFolder = Join-Path $WorkDir "temp_$versionNumber"
    
    try {
        # Create temp directory
        New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
        Set-Location $tempFolder
        
        # Initialize git repo
        git init
        
        # Configure git with bearer token
        git config --global http.extraHeader "AUTHORIZATION: Bearer $Token"
        
        # Add source remote and fetch
        $encodedSourceRepo = Format-GitUrl $SourceRepo
        $encodedSourceProj = Format-GitUrl $SourceProj
        $sourceUrl = "https://dev.azure.com/$SourceOrg/$encodedSourceProj/_git/$encodedSourceRepo"
        
        git remote add source $sourceUrl
        git -c http.$sourceUrl.extraheader="AUTHORIZATION: Bearer $Token" fetch source $SourceBranch --progress
        
        # Checkout source branch
        git checkout -b local_branch source/$SourceBranch
        
        # Add target remote
        $encodedTargetProj = Format-GitUrl $TargetProj
        $encodedTargetRepo = Format-GitUrl $TargetRepo
        $targetUrl = "https://dev.azure.com/$TargetOrg/$encodedTargetProj/_git/$encodedTargetRepo"
        
        git remote add target $targetUrl
        
        # Push to target with bearer token
        $targetBranch = "release/platform-services-v$versionNumber"
        git -c http.$targetUrl.extraheader="AUTHORIZATION: Bearer $Token" push target "local_branch:$targetBranch" --progress
        
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
```

### Execution Flow

```
1. Extract version number from source branch name
   └── release/platform-services-v1.0.0 → "1.0.0"

2. Create temporary directory
   └── temp_1.0.0

3. Initialize Git repository

4. Configure bearer token authentication
   └── git config --global http.extraHeader "AUTHORIZATION: Bearer $Token"

5. Add source remote and fetch branch
   └── git remote add source https://dev.azure.com/{SourceOrg}/{SourceProj}/_git/{SourceRepo}
   └── git fetch source release/platform-services-v1.0.0

6. Checkout source branch
   └── git checkout -b local_branch source/release/platform-services-v1.0.0

7. Add target remote
   └── git remote add target https://dev.azure.com/{TargetOrg}/{TargetProj}/_git/{TargetRepo}

8. Push to target repository
   └── git push target local_branch:release/platform-services-v1.0.0

9. Cleanup
   └── Remove git credentials
   └── Delete temporary directory
```

### Security Considerations

**Bearer Token Handling:**
- Token retrieved fresh for each execution
- Token configured per-remote URL (not global)
- Token cleaned up in `finally` block (always executes)
- Temporary directory deleted after execution

**Why per-URL token?**
```powershell
# Correct: Token scoped to specific URL
git -c http.$sourceUrl.extraheader="AUTHORIZATION: Bearer $Token" fetch source $SourceBranch

# Incorrect: Global token could leak to other operations
git config --global http.extraHeader "AUTHORIZATION: Bearer $Token"
git fetch source $SourceBranch
```

---

## Script 2 Copy-VariableGroup-ps1

### Purpose
Copies a variable group from source project to target project with customization for subdomain-specific configuration. Handles secret retrieval from Key Vault and flattening of PEP configurations.

### Parameters

```powershell
param (
    [Parameter(Mandatory=$true)]
    [string]$SourceOrg,              # Source organization
    [Parameter(Mandatory=$true)]
    [string]$SourceProject,          # Source project
    [Parameter(Mandatory=$true)]
    [string]$SourceGroupName,        # Source variable group name
    [Parameter(Mandatory=$true)]
    [string]$TargetOrg,              # Target organization
    [Parameter(Mandatory=$true)]
    [string]$TargetProject,          # Target project
    [Parameter(Mandatory=$true)]
    [string]$TargetGroupName,        # Target variable group name
    [Parameter(Mandatory=$true)]
    [string]$TargetWorkspaceName,    # Target Fabric workspace
    [Parameter(Mandatory=$true)]
    [string]$TargetParentDomainName, # Super domain name
    [Parameter(Mandatory=$true)]
    [string]$TargetChildDomainName,  # Subdomain name
    [Parameter(Mandatory=$true)]
    [string]$TargetRepository,       # Target repository
    [string]$Environment,            # Environment (INT/PRD)
    [string]$AdminGroupPrincipalIds, # Admin group GUIDs
    [string]$ContributorGroupPrincipalIds, # Contributor group GUIDs
    [string]$ViewerGroupPrincipalIds,      # Viewer group GUIDs
    [string]$CapacityId,             # Fabric capacity ID
    [string]$KeyvaultName,           # Key Vault name
    [string]$PepFilePath = "",       # Path to PEP JSON file
    [string]$KeyvaultPlatformServices = "bhg-hub-fabric01-eus-kv"  # Platform Key Vault
)
```

### Key Functions

#### Get-KeyVaultAuthToken

```powershell
function Get-KeyVaultAuthToken {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Install-Module -Name Az.Accounts -Force -Scope CurrentUser
    }
    
    $secureSecret = ConvertTo-SecureString $env:ARM_CLIENT_SECRET -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential(
        $env:ARM_CLIENT_ID, $secureSecret)
    
    # Connect to Azure using service principal
    Connect-AzAccount -ServicePrincipal -Tenant $env:ARM_TENANT_ID -Credential $credential
    
    # Set context for Key Vault operations
    Set-AzContext -Subscription $env:ARM_SUBSCRIPTION_ID
    
    return $true
}
```

#### Get-KeyVaultSecret

```powershell
function Get-KeyVaultSecret {
    param (
        [string]$SecretName,
        [string]$KeyvaultName
    )
    
    if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
        Install-Module -Name Az.KeyVault -Force -Scope CurrentUser
    }
    Import-Module Az.KeyVault
    
    $secret = Get-AzKeyVaultSecret -VaultName $KeyvaultName -Name $SecretName -AsPlainText
    return $secret
}
```

Used to retrieve service principal secrets and service account passwords from central Key Vault.

#### Copy-AzDevOpsVariableGroup

Main function that performs variable group copy and customization:

```powershell
function Copy-AzDevOpsVariableGroup {
    param (
        [string]$Token,
        [string]$SourceOrg,
        [string]$SourceProject,
        [string]$SourceGroupName,
        [string]$TargetOrg,
        [string]$TargetProject,
        [string]$TargetGroupName,
        # ... other parameters
    )
    
    $headers = @{
        'Authorization' = "Basic $Token"
        'Content-Type' = 'application/json'
    }
    
    # Step 1: Process PEP JSON into flattened properties
    $pepProperties = @{}
    
    if (-not [string]::IsNullOrWhiteSpace($PepFilePath) -and (Test-Path $PepFilePath)) {
        $pepJson = Get-Content -Path $PepFilePath -Raw
        $pepObj = $pepJson | ConvertFrom-Json
        
        # Ensure it's an array
        if ($pepObj -isnot [System.Array]) {
            $pepObj = @($pepObj)
        }
        
        # Flatten each PEP entry into properties
        foreach ($entry in $pepObj) {
            $subresourceType = $entry.subresourceType
            
            # Create flattened properties:
            # pep.blob.allowed = "true"
            # pep.blob.resourceId = "/subscriptions/.../storageAccounts/..."
            # pep.blob.subresourceType = "blob"
            $pepProperties["pep.$subresourceType.allowed"] = $entry.allowed.ToString().ToLower()
            $pepProperties["pep.$subresourceType.resourceId"] = $entry.resourceId
            $pepProperties["pep.$subresourceType.subresourceType"] = $subresourceType
        }
    }
    
    # Step 2: Get source variable group
    $sourceUrl = "https://dev.azure.com/$SourceOrg/$encodedSourceProj/_apis/distributedtask/variablegroups?groupName=$encodedSourceGroupName&api-version=7.2-preview.2"
    $sourceGroup = Invoke-RestMethod -Uri $sourceUrl -Headers $headers -Method Get
    
    if (-not $sourceGroup -or $sourceGroup.value.Count -eq 0) {
        throw "Source variable group '$SourceGroupName' not found"
    }
    
    # Step 3: Get target project ID
    $projectUrl = "https://dev.azure.com/$TargetOrg/_apis/projects/$encodedTargetProj`?api-version=7.2-preview.2"
    $projectDetails = Invoke-RestMethod -Uri $projectUrl -Headers $headers -Method Get
    $targetProjectId = $projectDetails.id
    
    # Step 4: Check if target group exists
    $targetGroupUrl = "https://dev.azure.com/$TargetOrg/$encodedTargetProj/_apis/distributedtask/variablegroups?groupName=$encodedTargetGroupName&api-version=7.2-preview.2"
    $targetGroup = Invoke-RestMethod -Uri $targetGroupUrl -Headers $headers -Method Get
    
    # Step 5: Prepare variables (skip certain variables if they exist in target)
    $variables = @{}
    $skip_flags = @{
        connection = $false
        mngconnection = $false
        sm = $false
        smParameter = $false
        sparkcompute = $false
        shortcut = $false
        default_spark_environment_name = $false
        default_spark_runtime = $false
        teams_channel_web_url = $false
        teams_tags = $false
        capacity_id = $false
        keyvault_name = $false
    }
    
    # If target group exists, preserve certain variables
    if ($targetGroup.count -gt 0 -and $targetGroup.value[0].variables) {
        foreach ($key in $targetGroup.value[0].variables.PSObject.Properties.Name) {
            if ($key.ToLower().StartsWith("mngconnection")) {
                $variables[$key] = @{
                    value = $targetGroup.value[0].variables.$key.value
                    isSecret = $false
                }
                $skip_flags.connection = $true
            }
            # ... similar logic for other prefixes, pep, shortcut, sm, sparkCompute
        }
    }
    
    # Step 6: Copy variables from source, applying customizations
    if ($sourceGroup.value[0].variables) {
        foreach ($key in $sourceGroup.value[0].variables.PSObject.Properties.Name) {
            $value = $sourceGroup.value[0].variables.$key.value
            $isSecret = $sourceGroup.value[0].variables.$key.isSecret
            
            # Apply customizations
            switch ($key) {
                "ENVIRONMENT" {
                    $value = $Environment
                }
                "CAPACITY_ID" {
                    $value = $CapacityId
                }
                "KEYVAULT_NAME" {
                    $value = $KeyvaultName
                }
                "WORKSPACE_NAMES" {
                    $value = "[$($TargetWorkspaceName -replace '^"|"$' | ConvertTo-Json)]"
                }
                "ADMIN_GROUP_PRINCIPAL_IDS" {
                    if ([string]::IsNullOrWhiteSpace($AdminGroupPrincipalIds)) {
                        $value = "[]"
                    } else {
                        $principalIds = $AdminGroupPrincipalIds -split ',' | ForEach-Object { $_.Trim(' "\"') }
                        $value = "[" + ($principalIds -join ',') + "]"
                        $value = $value.Replace('[', '["').Replace(']', '"]').Replace(',', '","').Replace(' ', '')
                    }
                }
                "PARENT_DOMAIN_NAME" {
                    $value = $TargetParentDomainName
                }
                "CHILD_DOMAIN_NAME" {
                    $value = $TargetChildDomainName
                }
            }
            
            # Retrieve secrets from Key Vault
            if ($isSecret) {
                switch ($key) {
                    "CLIENT_SECRET" {
                        $value = Get-KeyVaultSecret -SecretName "spn-gdap-fabricpview-secret" -KeyvaultName $KeyvaultPlatformServices
                    }
                    "SERVICE_ACCOUNT_SECRET" {
                        $value = Get-KeyVaultSecret -SecretName "FabricDnAServiceAccountProd-password" -KeyvaultName $KeyvaultPlatformServices
                    }
                    "TEAMS_NOTIFICATION_PASSWORD" {
                        $value = Get-KeyVaultSecret -SecretName "GUARDDnATeamsNotification-ServiceAccount-password" -KeyvaultName $KeyvaultPlatformServices
                    }
                    "TEAMS_CLIENT_SECRET" {
                        $value = Get-KeyVaultSecret -SecretName "spn-gdap-teams-notification-secret" -KeyvaultName $KeyvaultPlatformServices
                    }
                }
            }
            
            # Skip if variable should be preserved from target
            if ($skip_flags[$key.ToLower()] -eq $true) {
                continue
            }
            
            if ($null -ne $value) {
                $variables[$key] = @{
                    value = $value
                    isSecret = $isSecret
                }
            }
        }
    }
    
    # Step 7: Add flattened PEP properties
    foreach ($key in $pepProperties.Keys) {
        $variables[$key] = @{
            value = $pepProperties[$key]
            isSecret = $false
        }
    }
    
    # Step 8: Add metadata variables
    $variables["TARGET_ORGANIZATION"] = @{ value = $TargetOrg; isSecret = $false }
    $variables["TARGET_PROJECT"] = @{ value = $TargetProject; isSecret = $false }
    $variables["TARGET_REPOSITORY"] = @{ value = $TargetRepository; isSecret = $false }
    
    # Step 9: Create/update variable group
    $newGroup = @{
        name = $TargetGroupName
        description = "Copied from $SourceGroupName"
        variables = $variables
        type = "Vsts"
        variableGroupProjectReferences = @(
            @{
                name = $TargetGroupName
                description = "Copied from $SourceGroupName"
                projectReference = @{
                    id = $targetProjectId
                    name = $TargetProject
                }
            }
        )
    }
    
    if ($targetGroup.count -gt 0) {
        # Update existing group
        $groupId = $targetGroup.value[0].id
        $updateUrl = "https://dev.azure.com/$TargetOrg/_apis/distributedtask/variablegroups/$groupId`?api-version=7.2-preview.2"
        $response = Invoke-RestMethod -Uri $updateUrl -Headers $headers -Method Put -Body ($newGroup | ConvertTo-Json -Depth 10)
    } else {
        # Create new group
        $createUrl = "https://dev.azure.com/$TargetOrg/_apis/distributedtask/variablegroups?api-version=7.2-preview.2"
        $response = Invoke-RestMethod -Uri $createUrl -Headers $headers -Method Post -Body ($newGroup | ConvertTo-Json -Depth 10)
    }
    
    return $response.id
}
```

### PEP Flattening Pattern

**Input (JSON array):**
```json
[
  {
    "allowed": true,
    "resourceId": "/subscriptions/.../storageAccounts/mystorageaccount",
    "subresourceType": "blob"
  },
  {
    "allowed": false,
    "resourceId": "/subscriptions/.../keyvault/mykeyvault",
    "subresourceType": "vault"
  }
]
```

**Output (flattened variables):**
```
pep.blob.allowed = "true"
pep.blob.resourceId = "/subscriptions/.../storageAccounts/mystorageaccount"
pep.blob.subresourceType = "blob"
pep.vault.allowed = "false"
pep.vault.resourceId = "/subscriptions/.../keyvault/mykeyvault"
pep.vault.subresourceType = "vault"
```

**Why flatten?** Azure DevOps variable groups don't support nested JSON objects. Flattening enables structured access in downstream scripts.

### Variable Preservation Strategy

Certain variables are preserved from existing target variable groups to avoid overwriting environment-specific runtime values:

**Preserved Variable Prefixes:**
- `connection*` → Fabric connection IDs (generated after first deployment)
- `mngconnection*` → Managed connection configurations
- `sm*` → Semantic model configurations
- `smParameter*` → Semantic model parameters
- `sparkcompute*` → Spark compute settings
- `shortcut*` → Lakehouse shortcut configurations

**Preserved Specific Variables:**
- `DEFAULT_SPARK_ENVIRONMENT_NAME`
- `DEFAULT_SPARK_RUNTIME`
- `TEAMS_CHANNEL_WEB_URL`
- `TEAMS_TAGS`
- `CAPACITY_ID`
- `KEYVAULT_NAME`

**Why preserve?** These values are generated or customized during initial deployment. Overwriting would break existing infrastructure.

### Principal ID Formatting

Admin, Contributor, and Viewer group principal IDs are formatted as JSON arrays:

```powershell
# Input: "guid-1,guid-2,guid-3"
$principalIds = $AdminGroupPrincipalIds -split ',' | ForEach-Object { $_.Trim(' "\"') }
$value = "[" + ($principalIds -join ',') + "]"
$value = $value.Replace('[', '["').Replace(']', '"]').Replace(',', '","').Replace(' ', '')

# Output: ["guid-1","guid-2","guid-3"]
```

This format is consumed by RBAC assignment scripts.

---

## Script 3 Create-AzDevOpsEnvironment-ps1

### Purpose
Creates Azure DevOps environments with approval checks and security role assignments. Environments act as gates for lifecycle management and feature deployments.

### Parameters

```powershell
param (
    [Parameter(Mandatory=$true)]
    [string]$Organization,
    
    [Parameter(Mandatory=$true)]
    [string]$ProjectName,
    
    [Parameter(Mandatory=$true)]
    [string]$RequiredSecurityGroup,    # Required approver group
    
    [Parameter(Mandatory=$false)]
    [string]$OptionalSecurityGroup = "", # Optional approver group
    
    [Parameter(Mandatory=$false)]
    [string]$Environment = "INT",      # Only execute for INT
    
    [string]$LifecycleEnvironmentName = "lifecycleManagementApproval",
    [string]$FeatureEnvironmentName = "featureManagementApproval",
    [int]$TimeoutInMinutes = 4320      # 3 days (72 hours)
)
```

### Key Functions

#### Get-SecurityGroupWithLocalId

Uses IdentityPicker API to resolve security group names to IDs:

```powershell
function Get-SecurityGroupWithLocalId {
    param (
        [string]$GroupName,
        [hashtable]$Headers
    )
    
    $apiUrl = "https://$Organization.visualstudio.com/_apis/IdentityPicker/Identities?api-version=7.1-preview.1"
    
    $requestBody = @{
        query = $GroupName
        identityTypes = @("user", "group")
        operationScopes = @("ims", "source")
        options = @{
            MinResults = 1
            MaxResults = 20
        }
        properties = @(
            "DisplayName", "IsMru", "ScopeName", "SamAccountName", "Active",
            "SubjectDescriptor", "Department", "JobTitle", "Mail", "MailNickname",
            "PhysicalDeliveryOfficeName", "SignInAddress", "Surname", "Guest",
            "TelephoneNumber", "Manager", "Description"
        )
    } | ConvertTo-Json -Depth 3
    
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Post -Body $requestBody
    
    # Find matching group
    foreach ($result in $response.results) {
        foreach ($identity in $result.identities) {
            if ($identity.samAccountName -eq $GroupName -and $identity.entityType -eq "Group") {
                return @{
                    displayName = $identity.displayName
                    localId = $identity.localId        # For approval checks
                    originId = $identity.originId      # For entitlements/security
                    subjectDescriptor = $identity.subjectDescriptor
                    samAccountName = $identity.samAccountName
                    entityType = $identity.entityType
                }
            }
        }
    }
    
    return $null
}
```

**Why IdentityPicker API?** It returns multiple ID types:
- `localId`: Used for approval check configuration
- `originId`: Used for security role assignments and entitlements
- `subjectDescriptor`: Used for certain authorization APIs

#### Get-Environment

```powershell
function Get-Environment {
    param (
        [string]$Name,
        [hashtable]$Headers
    )
    
    $apiUrl = "https://dev.azure.com/$Organization/$encodedProjectName/_apis/distributedtask/environments?api-version=7.1-preview.1"
    
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Get
    
    foreach ($env in $response.value) {
        if ($env.name -eq $Name) {
            return $env
        }
    }
    
    return $null
}
```

#### New-Environment

```powershell
function New-Environment {
    param (
        [string]$Name,
        [hashtable]$Headers
    )
    
    $apiUrl = "https://dev.azure.com/$Organization/$encodedProjectName/_apis/distributedtask/environments?api-version=7.1-preview.1"
    
    $environmentBody = @{
        name = $Name
        description = "Created via automation script"
    } | ConvertTo-Json -Depth 2
    
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Post -Body $environmentBody
    
    return $response
}
```

#### Add-ApprovalCheck

```powershell
function Add-ApprovalCheck {
    param (
        [PSCustomObject]$Environment,
        [PSCustomObject]$RequiredGroup,
        [PSCustomObject]$OptionalGroup,
        [int]$TimeoutInMinutes,
        [hashtable]$Headers
    )
    
    # Create approvers array using localId
    $approvers = @()
    
    if ($null -ne $RequiredGroup) {
        $approvers += @{
            id = $RequiredGroup.localId
            displayName = $RequiredGroup.displayName
        }
    }
    
    if ($null -ne $OptionalGroup) {
        $approvers += @{
            id = $OptionalGroup.localId
            displayName = $OptionalGroup.displayName
        }
    }
    
    # Validate at least one approver
    if ($approvers.Count -eq 0) {
        Write-Error "No valid approvers found"
        return $false
    }
    
    # Create check payload
    $checkPayload = @{
        type = @{
            id = "8C6F20A7-A545-4486-9777-F762FAFE0D4D"  # Approval check type ID
            name = "Approval"
        }
        settings = @{
            executionOrder = 1
            instructions = "Please review the deployment details before approving."
            minRequiredApprovers = 1
            approvers = $approvers
            requesterCannotBeApprover = $false
            approverCount = $approvers.Count
            approvalsRequired = 1
        }
        timeout = $TimeoutInMinutes
        resource = @{
            type = "environment"
            id = $Environment.id.ToString()
            name = $Environment.name
        }
    } | ConvertTo-Json -Depth 10
    
    $apiUrl = "https://dev.azure.com/$Organization/$encodedProjectName/_apis/pipelines/checks/configurations?api-version=7.1-preview.1"
    
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Post -Body $checkPayload
    
    return $true
}
```

**Approval Check Settings:**
- `minRequiredApprovers: 1` → At least 1 approver must approve
- `requesterCannotBeApprover: false` → Requester can self-approve (for automation)
- `timeout: 4320 minutes` → 72 hours (3 days) before timeout
- `executionOrder: 1` → First check to execute

#### Get-EnvironmentChecks

```powershell
function Get-EnvironmentChecks {
    param (
        [PSCustomObject]$Environment,
        [hashtable]$Headers
    )
    
    $apiUrl = "https://dev.azure.com/$Organization/$encodedProjectName/_apis/pipelines/checks/configurations?resourceType=environment&resourceId=$($Environment.id)&api-version=7.1-preview.1"
    
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Get
    
    return $response.value
}
```

#### Remove-EnvironmentCheck

```powershell
function Remove-EnvironmentCheck {
    param (
        [PSCustomObject]$Environment,
        [int]$CheckId,
        [hashtable]$Headers
    )
    
    $apiUrl = "https://dev.azure.com/$Organization/$encodedProjectName/_apis/pipelines/checks/configurations/$CheckId`?api-version=7.1-preview.1"
    
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Delete
    
    return $true
}
```

#### Update-ProjectValidUsersRole

Updates default "Project Valid Users" group role from Reader to Administrator:

```powershell
function Update-ProjectValidUsersRole {
    param (
        [PSCustomObject]$Environment,
        [string]$ProjectId,
        [hashtable]$Headers,
        [string]$ProjectValidUserGroupName = "Project Valid Users",
        [string]$FromRole = "Reader",
        [string]$ToRole = "Administrator"
    )
    
    # Get current environment security
    $currentSecurity = Get-EnvironmentSecurity -Environment $Environment -ProjectId $ProjectId -Headers $Headers
    
    # Find Project Valid Users assignment
    $projectValidUsersAssignment = $null
    foreach ($assignment in $currentSecurity.value) {
        if ($assignment.identity.displayName -like "*$ProjectValidUserGroupName*") {
            $projectValidUsersAssignment = $assignment
            break
        }
    }
    
    if ($null -eq $projectValidUsersAssignment) {
        return $false
    }
    
    # Check if update needed
    if ($projectValidUsersAssignment.role.Name -eq $ToRole) {
        return $true
    }
    
    # Update role
    $updatedAssignments = @(
        @{
            userId = $projectValidUsersAssignment.identity.id
            roleName = $ToRole
        }
    )
    
    $updateSuccess = Set-EnvironmentSecurity -Environment $Environment -ProjectId $ProjectId -RoleAssignments $updatedAssignments -Headers $Headers
    
    return $updateSuccess
}
```

**Why?** By default, "Project Valid Users" (all project members) have Reader role on environments. This prevents them from triggering deployments. Updating to Administrator allows all project members to deploy.

#### Configure-Environment

Main orchestration function:

```powershell
function Configure-Environment {
    param (
        [string]$EnvironmentName,
        [PSCustomObject]$RequiredGroup,
        [PSCustomObject]$OptionalGroup,
        [string]$ProjectId,
        [int]$TimeoutInMinutes,
        [hashtable]$Headers
    )
    
    # Get or create environment
    $environment = Get-Environment -Name $EnvironmentName -Headers $Headers
    
    if ($null -eq $environment) {
        $environment = New-Environment -Name $EnvironmentName -Headers $Headers
    }
    
    # Remove existing approval checks
    $existingChecks = Get-EnvironmentChecks -Environment $environment -Headers $Headers
    if ($null -ne $existingChecks) {
        foreach ($check in $existingChecks) {
            if ($check.type.name -eq "Approval") {
                Remove-EnvironmentCheck -Environment $environment -CheckId $check.id -Headers $Headers
            }
        }
    }
    
    # Add new approval checks
    $approvalSuccess = Add-ApprovalCheck -Environment $environment -RequiredGroup $RequiredGroup -OptionalGroup $OptionalGroup -TimeoutInMinutes $TimeoutInMinutes -Headers $Headers
    
    return $environment
}
```

### Execution Flow

```
1. Validate environment is INT (skip for PRD)
   └── Only INT environments are auto-configured

2. Get authentication token

3. Get project ID

4. Validate security groups using IdentityPicker API
   ├── Required group (must exist)
   └── Optional group (optional)

5. Configure Lifecycle Environment
   ├── Get or create environment
   ├── Remove existing approval checks
   ├── Add approval checks (both groups)
   └── Update Project Valid Users role to Administrator

6. Configure Feature Environment
   ├── Get or create environment
   ├── Remove existing approval checks
   ├── Add approval checks (required group only)
   └── Update Project Valid Users role to Administrator

7. Result
   ├── lifecycleManagementApproval (with 2 approver groups)
   └── featureManagementApproval (with 1 approver group)
```

### Environment Usage in Pipelines

Pipelines reference environments to trigger approval gates:

```yaml
- stage: Deploy
  jobs:
  - deployment: DeployToINT
    environment: lifecycleManagementApproval  # Requires approval
    strategy:
      runOnce:
        deploy:
          steps:
          - script: echo "Deploying to INT..."
```

When pipeline reaches this stage:
1. Pipeline pauses
2. Notification sent to approver groups
3. Member of approver group must approve
4. 72-hour timeout before automatic rejection
5. Pipeline continues after approval

---

## Script 4 Create-ReleasePipeline-ps1

### Purpose
Creates an Azure DevOps pipeline in the target project that points to the infrastructure deployment YAML (`azure-pipelines.yml`) in the release branch.

### Parameters

```powershell
param (
    [Parameter(Mandatory=$true)]
    [string]$Organization,
    
    [Parameter(Mandatory=$true)]
    [string]$Project,
    
    [Parameter(Mandatory=$true)]
    [string]$PipelineName,          # "{Project} - {Subdomain}"
    
    [Parameter(Mandatory=$true)]
    [string]$ReleaseVersion,        # "release/platform-services-v1.0.0"
    
    [Parameter(Mandatory=$true)]
    [string]$RepositoryName,
    
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceName,         # Used for conditional execution
    
    [Parameter(Mandatory=$true)]
    [string]$VariableGroupName,
    
    [Parameter(Mandatory=$false)]
    [string]$YamlPath = "DevOpsServices/pipelines/infrastructure/azure-pipelines.yml"
)
```

### Key Functions

#### Get-Pipeline

```powershell
function Get-Pipeline {
    param (
        [string]$Token,
        [string]$Organization,
        [string]$Project,
        [string]$PipelineName
    )
    
    $headers = @{
        'Authorization' = "Basic $Token"
        'Content-Type' = 'application/json'
    }
    
    $encodedProject = Format-GitUrl -value $Project
    $url = "https://dev.azure.com/$Organization/$encodedProject/_apis/pipelines?api-version=7.1-preview.1"
    
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    
    # Filter by name
    $pipeline = $response.value | Where-Object { $_.name -eq $PipelineName }
    
    return $pipeline
}
```

#### Get-Repository

```powershell
function Get-Repository {
    param (
        [string]$Token,
        [string]$Organization,
        [string]$Project,
        [string]$RepositoryName
    )
    
    $headers = @{
        'Authorization' = "Basic $Token"
        'Content-Type' = 'application/json'
    }
    
    $encodedProject = Format-GitUrl -value $Project
    $encodedRepoName = Format-GitUrl -value $RepositoryName
    
    $url = "https://dev.azure.com/$Organization/$encodedProject/_apis/git/repositories/$encodedRepoName`?api-version=7.1-preview.1"
    
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    
    return $response
}
```

#### Create-Pipeline

```powershell
function Create-Pipeline {
    param (
        [string]$Token,
        [string]$Organization,
        [string]$Project,
        [string]$PipelineName,
        [string]$YamlPath,
        [string]$RepositoryId,
        [string]$BranchName
    )
    
    $headers = @{
        'Authorization' = "Basic $Token"
        'Content-Type' = 'application/json'
    }
    
    $encodedProject = Format-GitUrl -value $Project
    
    $body = @{
        name = $PipelineName
        configuration = @{
            type = "yaml"
            path = $YamlPath
            repository = @{
                id = $RepositoryId
                type = "azureReposGit"
            }
            branchFilters = @(
                "+$BranchName"  # Only trigger on this branch
            )
        }
    }
    
    $url = "https://dev.azure.com/$Organization/$encodedProject/_apis/pipelines?api-version=7.1-preview.1"
    
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 10)
    
    return $response
}
```

**Branch Filters:**
- `+release/platform-services-v1.0.0` → Only trigger on this specific branch
- Prevents pipeline from triggering on other branches

### Execution Flow

```
1. Check if workspace name contains "INT"
   └── Skip if not INT (production safety)

2. Get authentication token

3. Get repository details
   └── Retrieve repository ID

4. Check if pipeline exists
   └── Query by pipeline name

5. If pipeline doesn't exist:
   └── Create pipeline pointing to release branch
   └── Configure branch filter (only release branch)

6. If pipeline exists:
   └── Skip creation (idempotent)

7. (Optional) Set variable group permissions
   └── Commented out in current implementation
```

### Pipeline Configuration

**Created pipeline structure:**
```json
{
  "name": "DnA Claims - Claims Handling",
  "configuration": {
    "type": "yaml",
    "path": "DevOpsServices/pipelines/infrastructure/azure-pipelines.yml",
    "repository": {
      "id": "repo-guid",
      "type": "azureReposGit"
    },
    "branchFilters": [
      "+release/platform-services-v1.0.0"
    ]
  }
}
```

**Key properties:**
- `type: "yaml"` → YAML pipeline (not classic)
- `path` → Location of YAML file in repository
- `repository.type: "azureReposGit"` → Azure Repos Git (not GitHub)
- `branchFilters: ["+release/..."]` → Only trigger on release branch

---

## Script 5 Create-Pipeline-ps1

### Purpose
Creates an Azure DevOps pipeline in the target project for creating subdomain-specific release branches. Nearly identical to `Create-ReleasePipeline.ps1` but targets a different YAML file.

### Parameters

```powershell
param (
    [Parameter(Mandatory=$true)]
    [string]$Organization,
    
    [Parameter(Mandatory=$true)]
    [string]$Project,
    
    [Parameter(Mandatory=$true)]
    [string]$PipelineName,          # "Create subdomain release branch - {Subdomain}"
    
    [Parameter(Mandatory=$true)]
    [string]$ReleaseVersion,
    
    [Parameter(Mandatory=$true)]
    [string]$RepositoryName,
    
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceName,
    
    [Parameter(Mandatory=$true)]
    [string]$VariableGroupName,
    
    [Parameter(Mandatory=$false)]
    [string]$YamlPath               # Passed as parameter (no default)
)
```

### Key Difference from Create-ReleasePipeline.ps1

**Create-ReleasePipeline.ps1:**
- Creates infrastructure deployment pipeline
- Default YAML: `DevOpsServices/pipelines/infrastructure/azure-pipelines.yml`
- Purpose: Deploy Fabric resources (workspaces, lakehouses, notebooks, etc.)

**Create-Pipeline.ps1:**
- Creates release branch creation pipeline
- YAML passed as parameter: `DevOpsServices/pipelines/release/create-subdomain-release-branch.yml`
- Purpose: Create new release branches in subdomain repositories

### Usage in Main Pipeline

```yaml
# Create infrastructure deployment pipeline
- task: PowerShell@2
  displayName: 'Create Subdomain Release Pipeline'
  inputs:
    filePath: 'Create-ReleasePipeline.ps1'
    arguments: >
      -PipelineName "$(targetProject) - $(targetSubDomain)"
      -YamlPath "DevOpsServices/pipelines/infrastructure/azure-pipelines.yml"

# Create release branch creation pipeline
- task: PowerShell@2
  displayName: 'Create subdomain release branch pipeline'
  inputs:
    filePath: 'Create-Pipeline.ps1'
    arguments: >
      -PipelineName "Create subdomain release branch - $(targetSubDomain)"
      -YamlPath "DevOpsServices/pipelines/release/create-subdomain-release-branch.yml"
```

**Why two pipelines?**
- **Infrastructure pipeline**: Triggered manually or on release branch updates to deploy infrastructure
- **Release branch pipeline**: Triggered manually to create new release branches from main/develop branches

---

## Release Branch Lifecycle

### Release Branch Creation

```
1. Platform Team creates release branch in source repository
   └── release/platform-services-v1.0.0 (PlatformServices-Fabric)

2. Platform Team tests infrastructure deployment in INT environment

3. Platform Team approves for promotion to subdomains

4. Deploy-release-subdomain.yml pipeline triggered
   ├── Validates branch name format
   ├── Discovers subdomain configurations
   └── Deploys to all subdomains in parallel

5. Each subdomain receives:
   ├── Release branch copy (release/platform-services-v1.0.0)
   ├── Variable group with customized configuration
   ├── Approval environments
   ├── Infrastructure deployment pipeline
   └── Release branch creation pipeline
```

### Release Branch Updates

**Scenario:** Fix bug in release/platform-services-v1.0.0

```
1. Platform Team commits fix to source release branch
   └── release/platform-services-v1.0.0 (PlatformServices-Fabric)

2. Platform Team re-runs Deploy-release-subdomain.yml

3. Deploy-ReleaseBranch.ps1 overwrites target release branches
   └── force push to release/platform-services-v1.0.0 (all subdomains)

4. Subdomain infrastructure pipelines detect updated branch

5. Subdomain teams approve and deploy updated infrastructure
```

**Important:** Force push overwrites target branch completely. Any subdomain-specific commits are lost.

### Version Increments

**Scenario:** Create new major version

```
1. Platform Team creates new release branch
   └── release/platform-services-v2.0.0 (PlatformServices-Fabric)

2. Platform Team runs Deploy-release-subdomain.yml
   └── Parameter: sourceBranch = "release/platform-services-v2.0.0"

3. Each subdomain receives:
   ├── New release branch (release/platform-services-v2.0.0)
   ├── New variable group ({VariableGroup}-v2.0.0)
   ├── New infrastructure pipeline ({Project} - {Subdomain} - v2.0.0)
   └── Existing v1.0.0 infrastructure remains unchanged

4. Subdomain teams can:
   ├── Continue using v1.0.0
   ├── Test v2.0.0 in parallel
   └── Cut over to v2.0.0 when ready
```

**Benefit:** Side-by-side versioning enables gradual rollout and rollback capability.

---

## Variable Group Management

### Variable Group Structure

Variable groups contain environment-specific configuration consumed by infrastructure deployment pipelines.

**Common Variables:**

| Variable | Description | Example |
|----------|-------------|---------|
| `ENVIRONMENT` | Environment identifier | `"dev"` |
| `WORKSPACE_NAMES` | JSON array of workspace names | `["Claims-ClaimsHandling-DEV"]` |
| `CAPACITY_ID` | Fabric capacity GUID | `"capacity-guid"` |
| `KEYVAULT_NAME` | Key Vault for secrets | `"bhg-dev-claimshdl-eus-kv"` |
| `ADMIN_GROUP_PRINCIPAL_IDS` | JSON array of admin group GUIDs | `["guid-1","guid-2"]` |
| `CONTRIBUTOR_GROUP_PRINCIPAL_IDS` | JSON array of contributor group GUIDs | `["guid-3"]` |
| `VIEWER_GROUP_PRINCIPAL_IDS` | JSON array of viewer group GUIDs | `["guid-4"]` |
| `PARENT_DOMAIN_NAME` | Super domain name | `"Claims"` |
| `CHILD_DOMAIN_NAME` | Subdomain name | `"Claims Handling"` |
| `TARGET_ORGANIZATION` | Target Azure DevOps organization | `"BHGDataAndAnalytics"` |
| `TARGET_PROJECT` | Target Azure DevOps project | `"DnA Claimns"` |
| `TARGET_REPOSITORY` | Target repository | `"DnA Claimns - Claims Handling"` |

**Secret Variables (from Key Vault):**

| Variable | Key Vault Secret | Purpose |
|----------|-----------------|---------|
| `CLIENT_SECRET` | `spn-gdap-fabricpview-secret` | Service principal for Fabric API |
| `SERVICE_ACCOUNT_SECRET` | `FabricDnAServiceAccountProd-password` | Service account password |
| `TEAMS_NOTIFICATION_PASSWORD` | `GUARDDnATeamsNotification-ServiceAccount-password` | Teams notification service account |
| `TEAMS_CLIENT_SECRET` | `spn-gdap-teams-notification-secret` | Teams app service principal |

**PEP Variables (flattened):**

For each private endpoint configuration:
```
pep.{subresourceType}.allowed = "true" | "false"
pep.{subresourceType}.resourceId = "/subscriptions/.../..."
pep.{subresourceType}.subresourceType = "{subresourceType}"
```

Example:
```
pep.blob.allowed = "true"
pep.blob.resourceId = "/subscriptions/sub-guid/resourceGroups/rg-name/providers/Microsoft.Storage/storageAccounts/storageaccount"
pep.blob.subresourceType = "blob"
```

### Variable Group Preservation

When updating an existing variable group, certain variables are preserved:

**Preserved Prefixes:**
- `connection*` → Fabric connection objects (runtime-generated)
- `mngconnection*` → Managed connections
- `sm*` → Semantic model configurations
- `smParameter*` → Semantic model parameters
- `sparkcompute*` → Spark compute settings
- `shortcut*` → Lakehouse shortcut configurations

**Preserved Specific:**
- `DEFAULT_SPARK_ENVIRONMENT_NAME`
- `DEFAULT_SPARK_RUNTIME`
- `TEAMS_CHANNEL_WEB_URL`
- `TEAMS_TAGS`
- `CAPACITY_ID`
- `KEYVAULT_NAME`

**Why?** These values are either:
1. Generated during first deployment (connections, semantic models)
2. Customized by subdomain teams (Spark settings, Teams channels)
3. Environment-specific (capacity ID, Key Vault name)

Overwriting would break existing infrastructure or lose customizations.

---

## Security and Approval Workflows

### Service Principal Authentication

All automation uses service principal (OAuth 2.0 client credentials):

**Environment Variables:**
- `ARM_CLIENT_ID` → Service principal application ID
- `ARM_CLIENT_SECRET` → Service principal secret
- `ARM_TENANT_ID` → Azure AD tenant ID
- `ARM_SUBSCRIPTION_ID` → Azure subscription ID (for Key Vault)

**Scopes:**
- Azure DevOps API: `499b84ac-1321-427f-aa17-267ca6975798`
- Azure Resource Manager: `https://management.azure.com/`
- Key Vault: Inherits from Az.Accounts context

### Approval Gate Workflow

```
1. Pipeline run triggered (manually or on commit)

2. Pipeline reaches environment-protected stage:
   - deployment: DeployToINT
     environment: lifecycleManagementApproval

3. Pipeline pauses

4. Approval request sent to configured security groups:
   ├── Required group (e.g., "Claims-Platform-Admins")
   └── Optional group (e.g., "Claims-Platform-Contributors")

5. Group member reviews deployment:
   ├── View pipeline run details
   ├── View changes being deployed
   └── Check validation/test results

6. Group member takes action:
   ├── Approve → Pipeline continues
   ├── Reject → Pipeline fails
   └── No action → Timeout after 72 hours → Pipeline fails

7. If approved, pipeline executes deployment stages

8. If rejected, pipeline stops and logs reason
```

**Approval Permissions:**
- Any member of approver groups can approve
- Requester can self-approve (for automation scenarios)
- Single approval sufficient (minRequiredApprovers: 1)

### Role-Based Access Control

**Environment Roles:**

| Role | Permissions |
|------|-------------|
| Administrator | View, use, manage environments |
| Reader | View environments only |
| User | Use environments in pipelines |

**Default Configuration:**
- Approver groups → Administrator (can use and manage)
- Project Valid Users → Administrator (all project members can deploy)

**Why Administrator for all?** Simplifies deployment workflows. Teams using INT environments should have deployment permissions.

### Git Credential Security

**Token Lifecycle:**
```
1. Token retrieved at start of script
2. Token configured for specific Git operation
3. Token used for Git operation
4. Token removed immediately after operation
5. Token never persisted to disk or logs
```

**Cleanup Pattern:**
```powershell
try {
    git config --global http.extraHeader "AUTHORIZATION: Bearer $Token"
    git push origin branch
}
finally {
    git config --global --unset-all http.extraheader
    git config --global credential.helper ""
}
```

Always called in `finally` block to ensure cleanup even on error.

---

## Multi-Repository Coordination

### Source-Target Repository Model

**Source Repository (PlatformServices-Fabric):**
- Contains platform infrastructure code
- Managed by central platform team
- Release branches created here
- Single source of truth for infrastructure templates

**Target Repositories (subdomain-specific):**
- DnA Claims - Claims Handling
- DnA Distribution - Del Auth
- (etc.)

Each subdomain has its own repository to enable:
1. **Independent deployment cadence** → Subdomains deploy on their own schedules
2. **Customization** → Subdomains can customize variable groups and configurations
3. **Access control** → Subdomain teams have permissions only to their repositories
4. **Isolation** → Issues in one subdomain don't affect others

### Repository Branching Strategy

**Source Repository:**
```
main (protected)
├── develop (active development)
├── feature/* (feature branches)
└── release/platform-services-v1.0.0 (release branches)
    └── release/platform-services-v1.1.0
        └── release/platform-services-v2.0.0
```

**Target Repositories:**
```
main (protected)
├── develop (subdomain-specific development)
├── feature/* (subdomain feature branches)
└── release/platform-services-v1.0.0 (promoted from source)
    └── release/platform-services-v1.1.0
        └── release/platform-services-v2.0.0
```

**Branch Protection:**
- `main` → Requires pull request and approvals
- `develop` → Requires pull request
- `release/*` → Direct push from automation (no protection)

**Why no protection on release branches?** Automation needs to push directly. Release branches are read-only for humans.

### Multi-Project Coordination

Each subdomain has its own Azure DevOps project:

**Example:**
- Platform Project: `GDAP-Fluidity-PlatformServices`
- Claims Project: `DnA Claims`
- Distribution Project: `DnA Distrubution`

**Benefits:**
1. **Project-level permissions** → Claims team can't access Distribution resources
2. **Project-level dashboards** → Each team has their own views
3. **Project-level settings** → Independent service connections, agent pools
4. **Billing separation** → Usage tracked per project

**Challenges:**
1. **Cross-project dependencies** → Shared libraries must be published to artifacts
2. **Duplicate pipelines** → Each project has its own copy of infrastructure pipelines

### Variable Group Synchronization

Variable groups are copied, not shared:

**Source Variable Group (PlatformServices):**
```
Variables:
- ENVIRONMENT: [source value]
- CAPACITY_ID: [source value]
- WORKSPACE_NAMES: [source value]
```

**Target Variable Groups (per subdomain):**
```
PlatformServices-ClaimsHandling-INT:
- ENVIRONMENT: "int"
- CAPACITY_ID: "claims-capacity-guid"
- WORKSPACE_NAMES: ["Claims-ClaimsHandling-INT"]

PlatformServices-DelegatedAuthority-INT:
- ENVIRONMENT: "int"
- CAPACITY_ID: "distribution-capacity-guid"
- WORKSPACE_NAMES: ["Distribution-DelegatedAuthority-INT"]
```

**Why copy instead of share?**
- Each subdomain needs different values (workspace names, capacity IDs, etc.)
- Changes to source don't automatically propagate (controlled updates)
- Subdomain teams can customize without affecting others

---

## Error Handling and Rollback Strategies

### Error Handling Patterns

#### 1. Fail Fast on Critical Errors

```powershell
# Authentication failure
if (-not $token) {
    Write-Error "Failed to get authentication token"
    exit 1
}

# Source branch validation
if (-not ($sourceBranch -match 'release/platform-services-v\d+\.\d+\.\d+')) {
    Write-Error "Invalid branch name format"
    exit 1
}

# Required security group not found
if ($null -eq $requiredGroup) {
    Write-Error "Required security group not found"
    exit 1
}
```

**When to fail fast:**
- Authentication failures
- Invalid parameters
- Required resources not found
- Configuration errors

#### 2. Continue on Non-Critical Errors

```powershell
# Optional security group not found
if ($null -eq $optionalGroup) {
    Write-Warning "Optional security group not found. Continuing with required group only."
    $optionalGroup = $null
}

# Variable group update failed but pipeline can continue
if (-not $updateSuccess) {
    Write-Warning "Failed to update variable group. Manual update may be required."
}
```

**When to continue:**
- Optional resources not found
- Non-essential operations failed
- Degraded functionality acceptable

#### 3. Cleanup on Error

```powershell
try {
    # Perform Git operations
    git clone $sourceUrl
    git push $targetUrl
}
catch {
    Write-Error "Git operation failed: $_"
    throw
}
finally {
    # Always cleanup, even on error
    Git-Cleanup
    Set-Location $WorkDir
    Remove-Item -Path $tempFolder -Recurse -Force
}
```

**Always cleanup:**
- Git credentials
- Temporary directories
- File handles
- Network connections

### Rollback Strategies

#### 1. Release Branch Rollback

**Scenario:** Release v1.1.0 has critical bug, need to rollback to v1.0.0

```bash
# Option A: Force push previous version
git push origin release/platform-services-v1.0.0:release/platform-services-v1.1.0 --force

# Option B: Re-run Deploy-release-subdomain.yml with v1.0.0
# Parameter: sourceBranch = "release/platform-services-v1.0.0"
```

**Impact:**
- Infrastructure pipeline re-deploys from v1.0.0 branch
- Resources revert to v1.0.0 configuration
- Data not affected (only infrastructure code changes)

### Disaster Recovery

**Scenario:** Entire subdomain deployment corrupted

```
1. Delete target release branch
   └── git push origin :release/platform-services-v1.0.0

2. Delete variable group
   └── Via Azure DevOps UI

3. Delete environments
   └── Via Azure DevOps UI

4. Delete pipelines
   └── Via Azure DevOps UI

5. Re-run Deploy-release-subdomain.yml
   └── Recreates all resources from scratch

6. Re-run infrastructure deployment pipeline
   └── Redeploys Fabric resources
```

**Recovery Time:** ~15-30 minutes (automated recreation)

---

## Conclusion

The Platform Services release promotion architecture implements a sophisticated multi-project deployment model that enables controlled rollout of infrastructure code across numerous independent domains while maintaining security, approval workflows, and configuration isolation.

**Key Capabilities:**

1. **multi-project Support**: Deploy to unlimited subdomains via JSON configuration files
2. **Parallel Execution**: Deploy to 5 subdomains concurrently for faster rollouts
3. **Version Management**: Side-by-side versioning enables gradual rollouts and rollbacks
4. **Approval Gates**: Lifecycle and feature approval environments ensure controlled deployments
5. **Configuration Management**: Automatic variable group customization per subdomain
6. **Security**: Service principal authentication with proper credential cleanup
7. **Git Integration**: Automated branch promotion with bearer token authentication
8. **Idempotency**: Scripts can be re-run safely without side effects
9. **Error Handling**: Graceful degradation with proper cleanup
10. **Rollback Support**: Multiple strategies for reverting problematic deployments

**Deployment Workflow Summary:**

```
Source Repository (Platform Team)
    └── Create release/platform-services-v1.0.0
        └── Test in Platform INT environment
            └── Run Deploy-release-subdomain.yml
                ├── Parallel Deployment (maxParallel: 5)
                │   ├── DnA Distribution
                │   ├── DnA Claims
                └── For each subdomain:
                    ├── Copy release branch
                    ├── Copy & customize variable group
                    ├── Create approval environments
                    ├── Create infrastructure pipeline
                    └── Create release branch pipeline
```

**Total Scripts:** 5 PowerShell automation scripts + 2 YAML pipelines orchestrating multi-project release promotion.

---

**Document Version:** 1.0  
**Last Updated:** January 2026  
**Author:** Platform Services Team
