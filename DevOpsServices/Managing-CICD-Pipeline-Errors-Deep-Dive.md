# Managing CI/CD Pipeline Errors: Microsoft Fabric Deployment Troubleshooting - Deep Dive

---

## Table of Contents

### Foundation
1. [CI/CD Pipeline Error Overview](#cicd-pipeline-error-overview)
2. [Error Classification & Impact](#error-classification--impact)
3. [Common Failure Patterns](#common-failure-patterns)

### Critical Error Categories
4. [GUID Reference Errors](#guid-reference-errors)
6. [API & Authentication Errors](#api--authentication-errors)
7. [JSON & File Format Errors](#json--file-format-errors)
8. [Folder & Organization Errors](#folder--organization-errors)


---

## CI/CD Pipeline Error Overview

Microsoft Fabric CI/CD pipelines orchestrate complex deployments involving multiple artifact types (data pipelines, lakehouses, notebooks, semantic models, reports) with intricate dependencies. When artifacts in the source environment (Platform Services) change, these changes can cascade through dependent subdomain deployments, causing failures.

### The GUID Reference Problem

**Core Issue:** Microsoft Fabric assigns unique GUIDs to artifacts (data pipelines, lakehouses, notebooks, connections). When subdomain data pipelines reference Platform Services artifacts, they store these GUIDs in their configuration. If Platform Services artifacts are recreated or modified, their GUIDs change, breaking subdomain references.

### Architecture Context

```
Platform Services Repository (Source)
├── Data Pipeline A (GUID: abc-123)
│   └── Invokes Pipeline B (GUID: def-456)
├── Lakehouse X (GUID: ghi-789)
└── Notebook Y (GUID: jkl-012)

↓ Deploy to Subdomain

Finance Subdomain Repository (Target)
├── Data Pipeline Finance-Main
│   ├── References Pipeline A (GUID: abc-123) ← Hardcoded reference
│   ├── Uses Lakehouse X (GUID: ghi-789) ← Hardcoded reference
│   └── Calls Notebook Y (GUID: jkl-012) ← Hardcoded reference

⚠️ PROBLEM: If Platform Services recreates Pipeline A
   Old GUID: abc-123 → New GUID: xyz-999
   Finance-Main still references abc-123 (DOES NOT EXIST)
   Result: Pipeline execution fails
```

### Impact Scope

**Affected Stages:**
1. **Build Stage:** Artifact creation failures
2. **Deploy Stage:** Reference resolution failures
3. **Runtime:** Execution failures when invoking non-existent artifacts

**Affected Artifacts:**
- Data Pipelines (InvokePipeline activities)
- Lakehouses (parameters, shortcuts)
- Notebooks (pipeline activities, environment references)
- Semantic Models (connection bindings)
- Reports (semantic model references)

---

## Error Classification & Impact

### Error Severity Levels

#### Critical (Pipeline Stops)
Errors that halt CI/CD pipeline execution immediately:
- Authentication failures
- API endpoint unavailable
- Malformed JSON in artifact definitions
- Missing required files (.platform, pipeline-content.json)
- Workspace not found

#### High (Deployment Fails)
Errors that prevent successful deployment but don't stop pipeline:
- Lakehouse parameter not found
- Notebook reference not resolved
- Connection GUID not found
- Folder creation failures

#### Medium (Degraded Functionality)
Errors that allow deployment but cause runtime failures:
- Invalid pipeline parameter values
- Incorrect workspace ID in nested activities
- Missing optional connections
- Incomplete folder structure

#### Low (Warnings)
Non-blocking issues that should be addressed:
- Deprecated API versions

### Error Categories by Source

| Category | Source | Impact | Example |
|----------|--------|--------|---------|
| **Reference Errors** | GUID changes in Platform Services | High | Data pipeline references non-existent pipeline GUID |
| **Parameter Errors** | Incorrect variable replacement | High | Lakehouse parameter `lh_sales_id` not found in target |
| **API Errors** | Fabric API failures | Critical | 401 Unauthorized, 429 Rate Limit |
| **JSON Errors** | Malformed artifact definitions | Critical | Invalid JSON in pipeline-content.json |
| **File Errors** | Missing or corrupted files | Critical | .platform file not found |
| **Folder Errors** | Folder operations fail | Medium | Cannot move item to target folder |
| **Network Errors** | Connectivity issues | Critical | Timeout connecting to Fabric API |
| **State Errors** | Inconsistent artifact states | Medium | Item exists but in wrong folder |

---

## Common Failure Patterns

### Pattern 1: Cascading GUID Failures

**Scenario:** Platform Services updates a core data pipeline, causing GUID change. Multiple subdomain pipelines reference this pipeline.

```
Platform Services:
- Update Pipeline "Master-ETL" → GUID changes from A to B

Subdomain Impact:
- DnA Distribution references Pipeline A (broken)
- DnA CLaims references Pipeline A (broken)  

Result: 2 subdomain deployments fail simultaneously
```

**Error Message:**
```
Error: The remote server returned an error: (400) Bad Request.

```

### Pattern 2: Parameter Mismatch Chain

**Scenario:** Lakehouse renamed in Platform Services, breaking parameter replacement logic.

```
Platform Services:
- Rename lakehouse "sales_data" logicalId in .platform

Subdomain:
- Replacement logic searches for lakehouse logicalId fails

Result: Parameter replacement fails, invalid GUID in pipeline
```

**Error Message:**
```
Error: The remote server returned an error: (400) Bad Request.
```

### Pattern 3: Connection GUID Stale Reference

**Scenario:** Connection recreated in Platform Services, GUID changes but pipeline still has old GUID.

```
Platform Services:
- Delete connection "AzureSQL-Connection"
- Recreate connection "AzureSQL-Connection" (new GUID)

Subdomain:
- Pipeline has linkedService referencing old connection GUID
- Connection GUID replacement logic fails (connection name match but GUID different)

Result: Pipeline deployed with invalid connection reference
```

**Error Message:**
```
Error: The remote server returned an error: (400) Bad Request.
```

---

## GUID Reference Errors

### Root Cause Analysis

**Why GUIDs Change:**
1. **Artifact Deletion & Recreation:** Deleting and recreating an artifact assigns new GUID
2. **Manual Edits:** Editing JSON files manually can corrupt GUID references

### Affected Reference Types

#### 1. Data Pipeline References (InvokePipeline Activity)

**Location in JSON:**
```json
{
  "name": "Call_Master_ETL",
  "type": "ExecutePipeline",
  "typeProperties": {
    "pipeline": {
      "referenceName": "Master-ETL-Pipeline",
      "type": "PipelineReference"
    },
    "waitOnCompletion": true,
    "parameters": {}
  },
  "policy": {
    "secureInput": false
  },
  "userProperties": [],
  "pipelineReference": {
    "pipelineId": "abc-123-old-guid",  // ← Problem: References old GUID
    "workspaceId": "workspace-guid"
  }
}
```

**Replacement Logic (Setup-FabricDataPipelines.ps1):**
```powershell
    # Replace pipeline logicalIds with ids
    foreach ($replacement in $pipelineReplacements) {
        Write-Host ("##[debug]Replacing logicalId: " + $replacement.logicalId + " with id: " + $replacement.id)
        $contentJson = $contentJson.Replace($replacement.logicalId, $replacement.id)
    }
    
```

**Failure Scenario:**
- Subdomain pipeline original logicalId is not found and no replacement is performed
- Old GUID retained in deployment
- Runtime execution fails

**Resolution:**
- Replace the new platform services pipeline GUID with the subdomain pipeline original GUID using VS Code.

#### 2. Lakehouse References (Parameters & LinkedServices)

**Parameter Pattern:**
```json
{
  "name": "lh_sales_id",
  "type": "string",
  "defaultValue": "abc-123-old-guid" 
}
```

**LinkedService Pattern:**
```json
{
  "name": "LinkedService_Lakehouse_Sales",  // ← Problem: Lakehouse name changed
  "type": "Lakehouse",
  "typeProperties": {
    "workspaceId": "workspace-guid",
    "artifactId": "abc-123-old-guid"  
  }
}
```

**Replacement Logic:**
```powershell
    foreach ($lakehouse in $lakehouses) {
       
        $linkedServicePattern = "name`":\s*`"$($lakehouse.displayName)`"[\s\S]*?`"artifactId`":\s*`"([^`"]+)`""
        if ($contentJson -match $linkedServicePattern) {
            $oldArtifactId = $Matches[1]
            Write-Host "##[debug]Replacing artifactId: $oldArtifactId with: $($lakehouse.id) for lakehouse: $($lakehouse.displayName)"
            $contentJson = $contentJson -replace $oldArtifactId, $lakehouse.id
        }
    }
```

**Failure Scenario:**
- Platform Services has lakehouse: "sales_analytics" name changed
- Name mismatch causes lookup failure
- Old GUID retained or parameter empty
- Pipeline execution fails accessing non-existent lakehouse

**Resolution:**
- Replace the new platform services pipeline lakehouse name with the subdomain pipeline original lakehouse using VS Code.

#### 3. Connection References

**Connection Pattern:**
```json
{
    "type": "InvokePipeline",
    "typeProperties": {
        "parameters": {
        "ELT_Id": {
            "value": "@pipeline().parameters.ELT_Id",
            "type": "Expression"
        },
        "update_elt_log": {
            "value": "false",
            "type": "Expression"
        }
        },
        "waitOnCompletion": false,
        "workspaceId": "00000000-0000-0000-0000-000000000000",
        "pipelineId": "2a9e070f-499f-4495-99fd-1265f1ab07f1",
        "operationType": "InvokeFabricPipeline"
    },
    "externalReferences": {
        "connection": "ed22cf49-cea1-4171-ac69-28ae3fe2b9f1"    // ← Problem: Connection GUID changed
    },
    "policy": {
        "timeout": "0.12:00:00",
        "retry": 0,
        "retryIntervalInSeconds": 30,
        "secureInput": false,
        "secureOutput": false
    },
    "name": "Failed Invoke Process Logs",
    "description": "Notebook to process metadata logs and send alert",
    "dependsOn": [
        {
        "activity": "ForEach Dataset Type",
        "dependencyConditions": [
            "Failed"
        ]
        }
    ]
}

```

**Replacement Logic:**
```powershell
    # Process connection mappings
    write-host ("##[debug]Processing connection mappings")
    write-host ("##[debug]Fabric Connections: " + (ConvertTo-Json -InputObject $fabricConnections))
    Write-Host ("##[debug]Fabric Managed Connections: " + (ConvertTo-Json -InputObject $fabricManagedConnections))

    foreach ($mapping in $fabricManagedConnections) {
        $connection = $fabricConnections | Where-Object { $_.displayName -eq $mapping.new_name }
        if ($connection) {
            Write-Host ("##[debug]Replacing connection name from " + $mapping.original_name + " to " + $mapping.new_name)
            Write-Host ("##[debug]Replacing connection ID from " + $mapping.guid + " to " + $connection.id)
            $contentJson = $contentJson.Replace($mapping.original_name, $mapping.new_name)
            $contentJson = $contentJson.Replace($mapping.guid, $connection.id)
        }
    }
```

**Failure Scenario:**
- Platform Services deletes and recreates connection
- Connection name identical but GUID different
- Subdomain deployment updates connection GUID
- BUT: Other pipelines in subdomain still reference old GUID
- Result: Some pipelines work, others fail (inconsistent state)

***Resolution***

Three variable group key/value pairs are used to manage and remap connections:

- **Key:** `mngConnection.<any-name>.guid`  -> original guid
- **Value:** `<GUID>`

- **Key:** `mngConnection.<any-name>.new-name`  
- **Value:** `<connection-name>`

- **Key:** `mngConnection.<any-name>.original-name`  
- **Value:** `<connection-name>`

## API & Authentication Errors

### Fabric API Rate Limiting

**Error:**
```
429 Too Many Requests
Retry-After: 60
```

**Root Cause:**
- Deploying many artifacts rapidly
- Multiple concurrent deployments
- High-frequency API polling

**Solution (Exponential Backoff):**
```powershell
function Invoke-FabricApiWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$MaxRetries = 5,
        [int]$InitialDelaySeconds = 5
    )
    
    $attempt = 0
    $delay = $InitialDelaySeconds
    
    while ($attempt -lt $MaxRetries) {
        try {
            $response = Invoke-RestMethod -Uri $Uri -Headers $Headers
            return $response
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            
            if ($statusCode -eq 429) {
                $attempt++
                
                # Get retry-after header if available
                $retryAfter = $_.Exception.Response.Headers["Retry-After"]
                if ($retryAfter) {
                    $delay = [int]$retryAfter
                }
                
                if ($attempt -lt $MaxRetries) {
                    Write-Warning "Rate limited (attempt $attempt/$MaxRetries). Waiting $delay seconds..."
                    Start-Sleep -Seconds $delay
                    
                    # Exponential backoff
                    $delay = $delay * 2
                } else {
                    throw "Max retries exceeded"
                }
            } else {
                throw
            }
        }
    }
}
```

### Workspace Permission Errors

**Error:**
```
403 Forbidden
You do not have permission to perform this action on workspace 'workspace-guid'
```

**Root Cause:**
- Service principal lacks Admin/Contributor role
- Workspace capacity paused
- Workspace deleted

---

## JSON & File Format Errors

### Missing .platform Files

**Error:**
```
Get-Content: Cannot find path 'C:\...\MyPipeline.DataPipeline\.platform'
```

**Cause:**
- .platform file not committed to Git
- File deleted accidentally
- Incorrect folder structure


### Base64 Encoding Errors

**Error:**
```
Invalid length for a Base-64 char array or string
```

**Cause:**
- Incorrect Base64 encoding of pipeline definition
- Truncated payload

---

## Folder & Organization Errors

### Folder Not Found

**Error:**
```
Cannot move item to folder: Folder 'Analytics' not found in workspace
```

**Cause:**
- Folder doesn't exist in target workspace
- Folder name mismatch
- Case sensitivity

**Resolution:**
- Item or artifact remains current folder or root folder.

---