
param(
    [Parameter(Mandatory = $true)]
    [string]$workspaceId,
    [Parameter(Mandatory = $true)]
    [string]$lakehouseName
)

$script:graphApiVersion = "7.1-preview.1"

function Get-FabricAccessToken {
    param(
        [string]$audience = "https://api.fabric.microsoft.com/"
    )

    try {
        Write-Host "Retrieving Fabric access token using Azure CLI"
        
        # Login to Azure using service principal
        $clientId = $env:ARM_CLIENT_ID
        $clientSecret = $env:ARM_CLIENT_SECRET
        $tenantId = $env:ARM_TENANT_ID
        
        if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($clientSecret) -or [string]::IsNullOrEmpty($tenantId)) {
            Write-Error "Client ID, Client Secret, and Tenant ID variables must be set"
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
        $tokenResult = az account get-access-token --resource $audience --query accessToken --output tsv 2>&1

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

function Enable-OneLakeSecurityFeature {
    param(
        [string]$workspaceId,
        [string]$lakehouseId,
        [string]$Token
    )
   
    try {
        Write-Host "Enabling OneLake security features for lakehouse: $lakehouseId in workspace: $workspaceId"
       
        # Construct API URL
        $apiUrl = "https://onelake.dfs.fabric.microsoft.com/v1.0/workspaces/$workspaceId/artifacts/$lakehouseId/security/enable"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type"  = "application/json"
        }

        $body = @{
            enableOneSecurity = $true
        }
       
        # Send request to enable OneLake security features
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method POST -Body ($body | ConvertTo-Json)

        Write-Host "##[debug]Successfully enabled OneLake security features for lakehouse: $lakehouseId"
        return $response
    }
    catch {
        Write-Error "Failed to enable OneLake security features for lakehouse: $lakehouseId : $_"
        exit 1
    }
}

function Get-LakehouseList {
    param(
        [string]$WorkspaceId,
        [string]$Token
    )
   
    try {
        Write-Host "Getting list of lakehouses from workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type"  = "application/json"
        }
       
        # Send request to get lakehouses
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET

        Write-Host "##[debug]Successfully retrieved $($response.value.Count) lakehouse(s)"
        return $response.value
    }
    catch {
        Write-Error "Failed to get lakehouse list: $_"
        exit 1
    }
}

function Get-DataAccessRoles {
    param(
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$Token
    )
    
    try {
        Write-Host "##[debug]Looking up data access roles for Lakehouse: $LakehouseId in Workspace: $WorkspaceId"
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$LakehouseId/dataAccessRoles"
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type"  = "application/json"
        }
        
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
            
        Write-Host "##[debug]Data access roles retrieved for Lakehouse: $LakehouseId in Workspace: $WorkspaceId"
        return $response
    }
    catch {
        Write-Error "Failed to lookup data access roles for Lakehouse: $LakehouseId in Workspace: $WorkspaceId : $_"
        throw
    }
}

function Get-NewMembersToDataAccessRole {
    param(
        [string]$lakehouseName
    )

    try {
        Write-Host "##[debug]Getting members for Data Access Role: $lakehouseName"
       
        $lakehouseAccessConfig = Get-ChildItem env: | 
        Where-Object { $_.Name -match "LAKEHOUSE_DEFAULTREADERS_LAKEHOUSE_\d+_NAME*" } | 
        Sort-Object Name
        
        if (-not $lakehouseAccessConfig) {
            Write-Error "No lakehouse default readers configuration found in environment variables"
            throw "No lakehouse default readers configuration found"
        }

        $members = @()
        foreach ($envVar in $lakehouseAccessConfig) {
            if ($envVar.Name -match "LAKEHOUSE_DEFAULTREADERS_LAKEHOUSE_(\d+)_NAME") {
                $id = $Matches[1]
                if ($envVar.Value -eq $lakehouseName) {
                    Write-Host "##[debug]Found lakehouse config: $($envVar.Name) with value: $($envVar.Value)"
                    $readerkey = "LAKEHOUSE_DEFAULTREADERS_LAKEHOUSE_${id}_READERMEMBERS"
                    $readerMembers = [System.Environment]::GetEnvironmentVariable($readerkey)
                    Write-Host "##[debug]Checking lakehouse config $($envVar.Name) for: $($envVar.Value) with members: $readerMembers"
                
                    $members = $readerMembers -split "," | ForEach-Object { $_.Trim() }
                    break
                }
            }
        }

        Write-Host "##[debug]Found $($members.Count) Members to be added for Data Access Role: $lakehouseName"
        return $members
    }
    catch {
        Write-Error "Failed to get members for Data Access Role: $lakehouseName : $_"
        throw
    }
}

function Add-MembersToDataAccessRole {
    param(
        [string]$workspaceId,
        [string]$lakehouseId,
        [string]$RoleName,
        [array]$ExistingRoles,
        [array]$MemberObjectIds,
        [string]$Token,
        [string]$tenantId
    )
    
    try {

        if ($MemberObjectIds.Count -eq 0) {
            Write-Warning "No member object IDs provided to add to Data Access Role: $RoleName in Lakehouse: $lakehouseId of Workspace: $workspaceId"
            return "NoMembers"
        }

        Write-Host "##[debug]Adding members to Data Access Role: $RoleName in Lakehouse: $lakehouseId of Workspace: $workspaceId"
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items/$lakehouseId/dataAccessRoles"

        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type"  = "application/json"
        }

        $microsoftEntraMembers = @()
        foreach ($objectId in $MemberObjectIds) {
            $microsoftEntraMembers += @{
                objectId   = $objectId
                objectType = "user"
                tenantId   = $tenantId
            }
        }
        
        $body = $ExistingRoles;
        $matchingRole = $body.value | Where-Object { $_.name -eq $RoleName }
        # Update members of the matching role by adding new members without duplicates
        if($matchingRole)
        {
            if(-not $matchingRole.members.microsoftEntraMembers)
            {
                $matchingRole.members | Add-Member -MemberType NoteProperty -Name microsoftEntraMembers -Value @()
            }
            $existingMembers = $matchingRole.members.microsoftEntraMembers
            Write-Host "##[debug]Existing Members Count: $($existingMembers.Count)"
            foreach ($member in $microsoftEntraMembers) {
                if (-not ($existingMembers | Where-Object { $_.objectId -eq $member.objectId })) {
                    $existingMembers += $member
                }
            }
            Write-Host "##[debug]Updated Members Count: $($existingMembers.Count)"
            $matchingRole.members.microsoftEntraMembers = $existingMembers
        }
        
        $jsonBody = $body | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method PUT -Body $jsonBody
        Write-Host "##[debug]Successfully updated members for Data Access Role: $RoleName in Lakehouse: $lakehouseId of Workspace: $workspaceId"
        return "Success"
    }
    catch {
        Write-Error "Failed to add members to Data Access Role: $RoleName in Lakehouse: $lakehouseId of Workspace: $workspaceId : $_"
        throw
    }
}

try {
    Write-Host "Starting data access role assignment for Lakehouse: $lakehouseName in Workspace: $workspaceId"

    # Get members to be added to DefaultReader role
    $newMembersToAdd = Get-NewMembersToDataAccessRole -lakehouseName $lakehouseName
    if ($newMembersToAdd.Count -eq 0) {
        Write-Warning "No members found to add to Data Access Role 'DefaultReader' for Lakehouse: $lakehouseName in Workspace: $workspaceId"
        exit 0
    }

    # Get Fabric token
    $token = Get-FabricAccessToken
    $tenantId = $env:ARM_TENANT_ID

    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "FABRIC_TOKEN environment variable is not set"
        exit 1
    }

    $lakehouses = Get-LakehouseList -WorkspaceId $workspaceId -Token $token
    $matchingLakehouse = $lakehouses | Where-Object { $_.displayName -eq $lakehouseName }
    if ($null -eq $matchingLakehouse) {
        Write-Error "Lakehouse with name '$lakehouseName' not found in Workspace: $workspaceId"
        exit 1
    }

    $lakehouseId = $matchingLakehouse.id

    # Enable OneLake security features
    Write-Host "Enabling OneLake security features for Lakehouse: $lakehouseId in Workspace: $workspaceId"
    $oneLakeToken = Get-FabricAccessToken -audience "https://storage.azure.com/"
    Enable-OneLakeSecurityFeature -workspaceId $workspaceId -lakehouseId $lakehouseId -Token $oneLakeToken
    Write-Host "OneLake security features enabled for Lakehouse: $lakehouseId in Workspace: $workspaceId"

    # Get existing data access roles
    $roleName = "DefaultReader"
    $dataAccessRoles = Get-DataAccessRoles -WorkspaceId $workspaceId -LakehouseId $lakehouseId -Token $token
    $matchingRole = $dataAccessRoles.value | Where-Object { $_.name -eq $roleName }
    if ($null -ne $matchingRole) {
        Write-Host "##[debug]Found existing Data Access Role ID: $($matchingRole.id) for Lakehouse: $lakehouseId in Workspace: $workspaceId"
    }
    else {
        Write-Error "Data Access Role '$roleName' not found for Lakehouse: $lakehouseId in Workspace: $workspaceId"
        exit 1
    }
    
    # Add members to the DefaultReader role
    $memberObjectIds = $newMembersToAdd -split "," | ForEach-Object { $_.Trim() }
    Write-Host "##[debug]Member Object IDs to be added: $($memberObjectIds -join ', ')"
    Add-MembersToDataAccessRole -workspaceId $workspaceId -lakehouseId $lakehouseId -RoleName $roleName -ExistingRoles $dataAccessRoles -MemberObjectIds $memberObjectIds -Token $token -tenantId $tenantId
    Write-Host "Data access role assignment process completed for Lakehouse: $lakehouseId in Workspace: $workspaceId"
}
catch {
    Write-Error "Error in data access role assignment for Lakehouse: $lakehouseId in Workspace: $workspaceId : $_"
    exit 1
}