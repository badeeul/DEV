param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory=$false)]
    [string[]]$AdminGroupPrincipalIds = @(),
   
    [Parameter(Mandatory=$false)]
    [string[]]$ViewerGroupPrincipalIds = @(),
   
    [Parameter(Mandatory=$false)]
    [string[]]$ContributorGroupPrincipalIds = @(),
   
    [Parameter(Mandatory=$false)]
    [string[]]$AdminSpPrincipalIds = @(),
   
    [Parameter(Mandatory=$false)]
    [string[]]$AdminUserPrincipalIds = @()
    
)

function Get-FabricAccessToken {
    try {
        Write-Host "##[section]Retrieving Fabric access token using Azure CLI"
       
        # Get service principal credentials from environment variables
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
       
        # Get access token for Fabric API
        Write-Host "##[debug]Retrieving access token for Fabric API"
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

function Get-WorkspaceRoleAssignments {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$true)]
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Retrieving existing role assignments for workspace: $WorkspaceId"
       
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/roleAssignments"
       
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET -ErrorAction Stop
       
        Write-Host "##[debug]Found $($response.value.Count) existing role assignments"
        # Display existing assignments for debugging
        foreach ($assignment in $response.value) {
            Write-Host "##[debug] - Principal ID: $($assignment.principal.id), Type: $($assignment.principal.type), Role: $($assignment.role)"
        }  
       
        return $response.value
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Host "##[debug]No existing role assignments found (or workspace not found)"
            return @()
        }
        Write-Warning "Failed to get existing role assignments: $_"
        return @()
    }
}

function Test-RoleAssignmentExists {
    param(
        [Parameter(Mandatory=$true)]
        [array]$ExistingAssignments,
       
        [Parameter(Mandatory=$true)]
        [string]$PrincipalId,
       
        [Parameter(Mandatory=$true)]
        [string]$Role
    )
   
    $exists = $ExistingAssignments | Where-Object {
        $_.principal.id -eq $PrincipalId -and $_.role -eq $Role
    }
   
    return ($null -ne $exists)
}

function Add-WorkspaceRoleAssignment {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$true)]
        [string]$PrincipalId,
       
        [Parameter(Mandatory=$true)]
        [ValidateSet("User", "Group", "ServicePrincipal")]
        [string]$PrincipalType,
       
        [Parameter(Mandatory=$true)]
        [ValidateSet("Admin", "Member", "Contributor", "Viewer")]
        [string]$Role,
       
        [Parameter(Mandatory=$true)]
        [string]$Token
    )
   
    try {
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/roleAssignments"
       
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        $body = @{
            principal = @{
                id = $PrincipalId
                type = $PrincipalType
            }
            role = $Role
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 5
       
        Write-Host "##[debug]Adding role assignment: $Role for $PrincipalType $PrincipalId"
       
        $response = Invoke-RestMethod `
            -Uri $apiUrl `
            -Headers $headers `
            -Method POST `
            -Body $jsonBody `
            -ErrorAction Stop
       
        Write-Host "##[debug] Successfully added $Role role for $PrincipalType $PrincipalId" -ForegroundColor Green
       
        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorMessage = $_.Exception.Message
       
        if ($statusCode -eq 409) {
            Write-Host "##[debug]  Role assignment already exists for $PrincipalType $PrincipalId with role $Role" -ForegroundColor Yellow
            return @{ AlreadyExists = $true; Success = $true }
        }
       
        Write-Host "##[debug] Failed to add role assignment for $PrincipalType $PrincipalId with role $Role. StatusCode=$statusCode, Message=$errorMessage" -ForegroundColor Red
        throw
    }
}

function Try-Add-WorkspaceRoleAssignment {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,

        [Parameter(Mandatory=$true)]
        [string]$PrincipalId,

        [Parameter(Mandatory=$true)]
        [ValidateSet("User", "Group", "ServicePrincipal")]
        [string]$PrincipalType,

        [Parameter(Mandatory=$true)]
        [ValidateSet("Admin", "Member", "Contributor", "Viewer")]
        [string]$Role,

        [Parameter(Mandatory=$true)]
        [string]$Token
    )

    $allTypes = @("User", "Group", "ServicePrincipal")
    $typesToTry = @($PrincipalType) + ($allTypes | Where-Object { $_ -ne $PrincipalType })

    foreach ($type in $typesToTry) {
        try {
            Write-Host "##[debug]Attempting to add role using principal type: $type"
            $resp = Add-WorkspaceRoleAssignment -WorkspaceId $WorkspaceId -PrincipalId $PrincipalId -PrincipalType $type -Role $Role -Token $Token
            return $resp
        }
        catch {
            $statusCode = $null
            if ($_.Exception -and $_.Exception.Response) {
                try { $statusCode = $_.Exception.Response.StatusCode.value__ } catch {}
            }
            $msg = $_.Exception.Message

            if ($statusCode -eq 404 -or $statusCode -eq 400 -or $msg -match "not found" -or $msg -match "Principal not found" -or $msg -match "Could not find" -or $msg -match "Response status code does not indicate success") {
                Write-Host "##[debug]Principal $PrincipalId not found as type $type, trying next type" -ForegroundColor Yellow
                continue
            }

            throw
        }
    }

    throw "Failed to locate principal $PrincipalId as any of types: $($allTypes -join ', ')"
}

function Remove-WorkspaceRoleAssignment {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$true)]
        [string]$PrincipalId,
       
        [Parameter(Mandatory=$true)]
        [string]$Token
    )
   
    try {
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/roleAssignments/$PrincipalId"
       
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        Write-Host "##[debug]Removing role assignment for principal: $PrincipalId"
       
        $response = Invoke-RestMethod `
            -Uri $apiUrl `
            -Headers $headers `
            -Method DELETE `
            -ErrorAction Stop
       
        Write-Host "##[debug] Successfully removed role assignment for principal $PrincipalId" -ForegroundColor Green
       
        return $response
    }
    catch {
        Write-Warning "Failed to remove role assignment for principal $PrincipalId`: $_"
        throw
    }
}

function Set-WorkspaceRoleAssignmentsBatch {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$true)]
        [array]$PrincipalIds,
       
        [Parameter(Mandatory=$true)]
        [ValidateSet("User", "Group", "ServicePrincipal")]
        [string]$PrincipalType,
       
        [Parameter(Mandatory=$true)]
        [ValidateSet("Admin", "Member", "Contributor", "Viewer")]
        [string]$Role,
       
        [Parameter(Mandatory=$true)]
        [string]$Token,
       
        [Parameter(Mandatory=$false)]
        [switch]$SkipExisting
    )
   
    if ($PrincipalIds.Count -eq 0) {
        Write-Host "##[debug]No principals provided for $Role role with type $PrincipalType, skipping" -ForegroundColor Gray
        return @{
            Processed = 0
            Added = 0
            Skipped = 0
            Failed = 0
        }
    }
   
    Write-Host "##[section]Processing $($PrincipalIds.Count) $PrincipalType principal(s) for $Role role"
   
    $results = @{
        Processed = 0
        Added = 0
        Skipped = 0
        Failed = 0
        Details = @()
    }
   
    # Get existing assignments if checking for duplicates
    $existingAssignments = @()
    if ($SkipExisting) {
        $existingAssignments = Get-WorkspaceRoleAssignments -WorkspaceId $WorkspaceId -Token $Token
    }
   
    foreach ($principalId in $PrincipalIds) {
        $results.Processed++
       
        try {
            # Check if assignment already exists
            if ($SkipExisting) {
                if (Test-RoleAssignmentExists -ExistingAssignments $existingAssignments -PrincipalId $principalId -Role $Role) {
                    Write-Host "##[debug] Skipping $principalId - already has $Role role" -ForegroundColor Gray
                    $results.Skipped++
                    $results.Details += @{
                        PrincipalId = $principalId
                        Status = "Skipped"
                        Reason = "Already exists"
                    }
                    continue
                }
            }
           
            # Add role assignment (try alternate principal types if not found)
            $response = Try-Add-WorkspaceRoleAssignment `
                -WorkspaceId $WorkspaceId `
                -PrincipalId $principalId `
                -PrincipalType $PrincipalType `
                -Role $Role `
                -Token $Token
           
            if ($response.AlreadyExists) {
                $results.Skipped++
                $results.Details += @{
                    PrincipalId = $principalId
                    Status = "Skipped"
                    Reason = "Already exists"
                }
            }
            else {
                $results.Added++
                $results.Details += @{
                    PrincipalId = $principalId
                    Status = "Added"
                    Response = $response
                }
            }
        }
        catch {
            $results.Failed++
            $results.Details += @{
                PrincipalId = $principalId
                Status = "Failed"
                Error = $_.Exception.Message
            }
            Write-Warning "Failed to add role assignment for $principalId`: $_"
        }
    }
   
    Write-Host "##[debug]Batch processing complete: $($results.Added) added, $($results.Skipped) skipped, $($results.Failed) failed" -ForegroundColor Cyan
   
    return $results
}

function Sync-WorkspaceRoleAssignments {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
       
        [Parameter(Mandatory=$true)]
        [hashtable]$DesiredState,
       
        [Parameter(Mandatory=$true)]
        [string]$Token,
       
        [Parameter(Mandatory=$false)]
        [bool]$RemoveUnmanaged=$true
    )
   
    Write-Host "##[section]Synchronizing workspace role assignments"
    Write-Host "##[debug]Workspace ID: $WorkspaceId"
   
    # Get current state
    $currentAssignments = Get-WorkspaceRoleAssignments -WorkspaceId $WorkspaceId -Token $Token
   
    Write-Host "##[debug]Current state: $($currentAssignments.Count) role assignments"
    Write-Host "##[debug]Desired state: $($DesiredState.Keys.Count) configuration groups"
   
    $syncResults = @{
        Added = 0
        Skipped = 0
        Removed = 0
        Failed = 0
        Groups = @()
    }
   
    # Process each desired configuration
    foreach ($configKey in $DesiredState.Keys) {
        $config = $DesiredState[$configKey]
       
        if ($config.PrincipalIds.Count -eq 0) {
            Write-Host "##[debug]Skipping $configKey - no principals configured" -ForegroundColor Gray
            continue
        }
       
        Write-Host "##[debug]Processing: $configKey $($config.PrincipalIds.Count) principals" -ForegroundColor Cyan
       
        $batchResult = Set-WorkspaceRoleAssignmentsBatch `
            -WorkspaceId $WorkspaceId `
            -PrincipalIds $config.PrincipalIds `
            -PrincipalType $config.PrincipalType `
            -Role $config.Role `
            -Token $Token `
            -SkipExisting
       
        $syncResults.Added += $batchResult.Added
        $syncResults.Skipped += $batchResult.Skipped
        $syncResults.Failed += $batchResult.Failed
        $syncResults.Groups += @{
            Name = $configKey
            Result = $batchResult
        }
    }
   
    # Optionally remove unmanaged assignments
    if ($RemoveUnmanaged -and $ENVIRONMENT -eq "PRD") {
        Write-Host "##[section]Checking for unmanaged role assignments to remove"
       
        # Build list of managed principal IDs
        $managedPrincipals = @()
        foreach ($config in $DesiredState.Values) {
            $managedPrincipals += $config.PrincipalIds
        }
       
        foreach ($assignment in $currentAssignments) {
            if ($assignment.principal.id -notin $managedPrincipals) {
                Write-Host "##[debug]Found unmanaged assignment: $($assignment.principal.id) with role $($assignment.role)" -ForegroundColor Yellow
               
                try {
                    Remove-WorkspaceRoleAssignment `
                        -WorkspaceId $WorkspaceId `
                        -PrincipalId $assignment.principal.id `
                        -Token $Token 
                   
                    $syncResults.Removed++
                }
                catch {
                    Write-Warning "Failed to remove unmanaged assignment: $_"
                    $syncResults.Failed++
                }
            }
        }
    }
   
    return $syncResults
}

try {

    Write-Host "##[section]Starting workspace role assignment configuration"
    Write-Host "##[debug]Parameters received:"
    Write-Host "##[debug] - WorkspaceId: $WorkspaceId"
    Write-Host "##[debug] - Admin Groups: $($AdminGroupPrincipalIds.Count)"
    Write-Host "##[debug] - Viewer Groups: $($ViewerGroupPrincipalIds.Count)"
    Write-Host "##[debug] - Contributor Groups: $($ContributorGroupPrincipalIds.Count)"
    Write-Host "##[debug] - Admin Service Principals: $($AdminSpPrincipalIds.Count)"
    Write-Host "##[debug] - Admin Users: $($AdminUserPrincipalIds.Count)"
    Write-Host ""
   
    # Get Fabric token
    $token = Get-FabricAccessToken
    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "Failed to retrieve Fabric access token"
        exit 1
    }
   
    # Define desired state (mirrors Terraform configuration)
    $desiredState = @{
        "admins-group" = @{
            PrincipalIds = $AdminGroupPrincipalIds
            PrincipalType = "Group"
            Role = "Admin"
        }
        "viewers-group" = @{
            PrincipalIds = $ViewerGroupPrincipalIds
            PrincipalType = "Group"
            Role = "Viewer"
        }
        "contributor-group" = @{
            PrincipalIds = $ContributorGroupPrincipalIds
            PrincipalType = "Group"
            Role = "Contributor"
        }
        "admins-sp" = @{
            PrincipalIds = $AdminSpPrincipalIds
            PrincipalType = "ServicePrincipal"
            Role = "Admin"
        }
        "user-sp" = @{
            PrincipalIds = $AdminUserPrincipalIds
            PrincipalType = "User"
            Role = "Admin"
        }
    }
   
    # Synchronize role assignments
    $syncResult = Sync-WorkspaceRoleAssignments `
        -WorkspaceId $WorkspaceId `
        -DesiredState $desiredState `
        -Token $token 

    Write-Host ""
    Write-Host "Summary:"
    Write-Host "  Added: $($syncResult.Added)" 
    Write-Host "  Skipped: $($syncResult.Skipped)" 
    Write-Host "  Removed: $($syncResult.Removed)"
    Write-Host "  Failed: $($syncResult.Failed)" 
   
    if ($syncResult.Removed -gt 0) {
        Write-Host "  Removed: $($syncResult.Removed)" -ForegroundColor Yellow
    }
   
    Write-Host ""
   
    # Return results as JSON for pipeline consumption
    $syncResult | ConvertTo-Json -Depth 10
   
    if ($syncResult.Failed -gt 0) {
        Write-Warning "Some role assignments failed - check logs above"
        exit 1
    }
}
catch {
    Write-Error "Error in workspace role assignment configuration: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
}