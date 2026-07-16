param(
    [Parameter(Mandatory = $true)]
    [string]$VariableGroupName,
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
    [Parameter(Mandatory = $true)]
    [string]$VariableGroupAdmins
)

function Get-DevOpsAuthToken {
    try {
        $resource = "499b84ac-1321-427f-aa17-267ca6975798"
        $authUrl = "https://login.microsoftonline.com/$env:ARM_TENANT_ID/oauth2/token"

        $body = @{
            grant_type    = "client_credentials"
            client_id     = $env:ARM_CLIENT_ID
            client_secret = $env:ARM_CLIENT_SECRET
            resource      = $resource
        }

        $response = Invoke-RestMethod -Method Post -Uri $authUrl -Body $body
        $token = $response.access_token
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token"))

        return $base64AuthInfo
    }
    catch {
        Write-Error "Failed to get Azure DevOps token: $_"
        throw
    }
}

function Get-ProjectId {
    param(
        [string]$ProjectName
    )
    try {
        $projUrl = "${collectionUri}_apis/projects/${ProjectName}?api-version=6.0"
        $projResp = Invoke-RestMethod -Uri $projUrl -Headers @{ Authorization = $authHeader } -Method Get
        if (-not $projResp.id) {
            throw "Project '$ProjectName' not found."
        }
        return $projResp.id
    }
    catch {
        Write-Error "Failed to get project id for '$ProjectName': $_"
        throw
    }
}

function Get-VariableGroupId {
    param(
        [string]$VariableGroupName,
        [string]$ProjectId
    )
    try {
        $vgUrl = "${collectionUri}${ProjectId}/_apis/distributedtask/variablegroups?api-version=6.0-preview.2"
        $vgResp = Invoke-RestMethod -Uri $vgUrl -Headers @{ Authorization = $authHeader } -Method Get
        $vg = $vgResp.value | Where-Object { $_.name -eq $VariableGroupName }
        if (-not $vg) {
            throw "Variable group '$VariableGroupName' not found in project '$ProjectId'."
        }
        return $vg.id
    }
    catch {
        Write-Error "Failed to get variable group id for '$VariableGroupName' in project '$ProjectId': $_"
        throw
    }

}

function Set-VariableGroupInheritPermissions {
    param(
        [PSCustomObject]$VariableGroup,
        [string]$ProjectId,
        [bool]$InheritPermissions
    )
    try {
        if (-not $VariableGroup) {
            throw "Variable group is null or empty."
        }
        if (-not $ProjectId) {
            throw "Project ID is null or empty."
        }
        if ($InheritPermissions -ne $true -and $InheritPermissions -ne $false) {
            throw "InheritPermissions must be a boolean value."
        }

        $variableGroupId = $VariableGroup.id
        if (-not $variableGroupId) {
            throw "Variable group ID is null or empty."
        }

        Write-Host "##[debug]Setting inherit permissions for variable group '$($VariableGroup.name)' in project '$ProjectId' to '$InheritPermissions'"

        $resourceIdentifier = "${ProjectId}`$$variableGroupId"
        Write-host "Resource Identifier for variable group security: $resourceIdentifier"
        $apiUrl = "${collectionUri}_apis/securityroles/scopes/distributedtask.variablegroup/roleassignments/resources/$resourceIdentifier`?inheritPermissions=$InheritPermissions"
        Write-Host "##[debug]Constructed variable group security API URL: $apiUrl"
   
        $headers = @{
            "Authorization" = $authHeader
            "Content-Type"  = "application/json"
            "Accept"        = "application/json;api-version=7.2-preview.1;excludeUrls=true"
        }

        if (-not $authHeader) {
            throw "Authorization header is null or empty."
        }

        Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Patch -ErrorAction Stop
        Write-Host "##[debug]Successfully set inherit permissions for variable group '$($VariableGroup.name)' to '$InheritPermissions'"
        return $true
    }
    catch {
        Write-Error "Failed to set inherit permissions for variable group '$($VariableGroup.name)': $_"
        return $false
    }
}

function Set-VariableGroupSecurity {
    param (
        [PSCustomObject]$VariableGroup,
        [string]$ProjectId,
        [object[]]$AdminGroups,
        [object[]]$UserGroups
    )
    Write-Host "##[debug]Setting variable group security for variable group: $($VariableGroup.name)"
    Write-Host "##[debug]Variable group id: $($VariableGroup.id)"
    Write-Host "##[debug]Project ID: $ProjectId"
    $variableGroupId = $VariableGroup.id
    if (-not $variableGroupId) {
        throw "Variable group ID is null or empty."
    }
    if (-not $ProjectId) {
        throw "Project ID is null or empty."
    }
    if (-not $AdminGroups -or $AdminGroups.Count -eq 0) {
        throw "Admin security groups are null or empty."
    }

    $resourceIdentifier = "${ProjectId}`$$variableGroupId"
    Write-host "Resource Identifier for variable group security: $resourceIdentifier"
    $apiUrl = "${collectionUri}_apis/securityroles/scopes/distributedtask.variablegroup/roleassignments/resources/$resourceIdentifier"
    Write-Host "##[debug]Constructed variable group security API URL: $apiUrl"
   
    $headers = @{
        "Authorization" = $authHeader
        "Content-Type"  = "application/json"
        "Accept"        = "application/json;api-version=7.2-preview.1;excludeUrls=true"
    }

    if (-not $authHeader) {
        throw "Authorization header is null or empty."
    }

    $roleAssignmentBody = @(
        foreach ($group in $AdminGroups) {
            @{
                roleName = "Administrator"
                userId   = $group.localId
            }
        }
        foreach ($group in $UserGroups) {
            @{
                roleName = "User"
                userId   = $group.localId
            }
        }

    ) | ConvertTo-Json -Depth 10

    Write-Host "##[debug]Role assignment body: $($roleAssignmentBody)"

    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Put -Body $roleAssignmentBody -ErrorAction Stop
        Write-Host "##[debug]Role assignment response: $($response | ConvertTo-Json -Depth 10)"
       
        Write-Host "##[debug]Successfully updated variable group security for '$($VariableGroup.name)'"
        return $true
    }
    catch {
        Write-Error "Failed to set variable group security: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        Write-Host "##[debug]Failed request body: $roleAssignmentBody"
        return $false
    }
}

function Get-SecurityGroupWithLocalId {
    param (
        [string]$GroupName
    )
   
    if ([string]::IsNullOrEmpty($GroupName)) {
        Write-Warning "Group name cannot be empty"
        return $null
    }
   
    Write-Host "##[debug]Looking up security group using IdentityPicker API: $GroupName in organization: $Organization"
   
    # Construct IdentityPicker API URL
    $apiUrl = "https://dev.azure.com/BHGDataAndAnalytics/_apis/IdentityPicker/Identities?api-version=7.2-preview.1"
   
    $headers = @{
        "Authorization" = $authHeader
        "Content-Type"  = "application/json"
    }

    # Create request body for IdentityPicker API
    $requestBody = @{
        query           = $GroupName
        identityTypes   = @("user", "group")
        operationScopes = @("ims", "source")
        options         = @{
            MinResults = 1
            MaxResults = 20
        }
        properties      = @(
            "DisplayName", "IsMru", "ScopeName", "SamAccountName", "Active",
            "SubjectDescriptor", "Department", "JobTitle", "Mail", "MailNickname",
            "PhysicalDeliveryOfficeName", "SignInAddress", "Surname", "Guest",
            "TelephoneNumber", "Manager", "Description"
        )
    } | ConvertTo-Json -Depth 3
   
    Write-Host "##[debug]Using IdentityPicker API URL: $apiUrl"
    Write-Host "##[debug]Request Body: $requestBody"
   
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Post -Body $requestBody -ErrorAction Stop
        Write-Host "##[debug]IdentityPicker Response: $($response | ConvertTo-Json -Depth 10)"
       
        # Parse response to find matching group
        if ($response.results -and $response.results.Count -gt 0) {
            foreach ($result in $response.results) {
                if ($result.identities -and $result.identities.Count -gt 0) {
                    foreach ($identity in $result.identities) {
                        # display identity for debugging
                        Write-Host "##[debug]Identity: $($identity | ConvertTo-Json -Depth 10)"

                        if ($null -eq $identity.samAccountName) {
                            Write-Warning "Identity does not have a samAccountName property. Skipping."
                            continue
                        }
                        $samAccountNameMatch = $identity.samAccountName -eq $GroupName
                       
                        if ($samAccountNameMatch -and $identity.entityType -eq "Group") {
                            Write-Host "##[debug]Found security group: $GroupName"
                            Write-Host "##[debug]  Display Name: $($identity.displayName)"
                            Write-Host "##[debug]  Local ID (approver ID): $($identity.localId)"
                            Write-Host "##[debug]  Origin ID: $($identity.originId)"
                            Write-Host "##[debug]  Subject Descriptor: $($identity.subjectDescriptor)"
                            Write-Host "##[debug]  SAM Account Name: $($identity.samAccountName)"
                           
                            return @{
                                displayName       = $identity.displayName
                                localId           = $identity.localId  # For approval checks
                                originId          = $identity.originId  # For entitlements lookup
                                subjectDescriptor = $identity.subjectDescriptor
                                samAccountName    = $identity.samAccountName
                                entityType        = $identity.entityType
                            }
                        }
                    }
                }
            }
        }
       
        Write-Warning "Security group not found using IdentityPicker API: $GroupName"
        return $null
    }
    catch {
        Write-Error "Error querying security groups using IdentityPicker API: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        return $null
    }
}


function Get-VariableGroupSecurity {
    param (
        [PSCustomObject]$VariableGroup,
        [string]$ProjectId
    )
   
    Write-Host "##[debug]Getting variable group security for: $($VariableGroup.name)"
    Write-Host "##[debug]Variable group id: $($VariableGroup.id)"
    Write-Host "##[debug]Project ID: $ProjectId"
    $variableGroupId = $VariableGroup.id
    $resourceIdentifier = "${ProjectId}`$$variableGroupId"
    Write-host "Resource Identifier for variable group security: $resourceIdentifier"
    $apiUrl = "${collectionUri}_apis/securityroles/scopes/distributedtask.variablegroup/roleassignments/resources/$resourceIdentifier`?api-version=7.2-preview.1"
    Write-Host "##[debug]Constructed variable group security API URL: $apiUrl"
   
    $headers = @{
        "Authorization" = $authHeader
        "Content-Type"  = "application/json"
    }

    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get -ErrorAction Stop
        if (-not $response) {
            Write-Host "##[debug]No response received from variable group security API."
        }

        return $response
    }
    catch {
        Write-Error "Error getting variable group security: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        return $null
    }
}

# Set permissions for a variable group in Azure DevOps
try {
    Write-Host "##[section]Starting set variable group permissions script"
    Write-Host "Setting permissions for variable group '$VariableGroupName' in project '$ProjectName' for security group '$VariableGroupAdmins'"

    $collectionUri = "https://dev.azure.com/BHGDataAndAnalytics/"
    $token = Get-DevOpsAuthToken

    if (-not $collectionUri) {
        Write-Error "Missing SYSTEM_TEAMFOUNDATIONCOLLECTIONURI environment variable."; exit 1
    }

    if (-not $token) {
        Write-Error "Failed to obtain Azure DevOps token."; exit 1
    }

    $authHeader = "Basic $token"

    
    $adminGroupNames = @()
    if (-not [string]::IsNullOrEmpty($VariableGroupAdmins)) {
        $adminGroupNames = $VariableGroupAdmins -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrEmpty($_) }
    }

    if ($adminGroupNames.Count -eq 0) {
        Write-Error "No admin security groups provided in \$VariableGroupAdmins"
        exit 1
    }

    $requiredGroups = @()
    foreach ($name in $adminGroupNames) {
        $g = Get-SecurityGroupWithLocalId -GroupName $name -Headers $headers
        if ($null -eq $g) {
            Write-Error "Required security group '$name' not found using IdentityPicker API."
            exit 1
        }
        $requiredGroups += $g
        Write-Host "##[debug]Required group validated:"
        Write-Host "##[debug]  Name: $($g.displayName)"
        Write-Host "##[debug]  Approver ID (localId): $($g.localId)"
        Write-Host "##[debug]  Origin ID: $($g.originId)"
    }

    if ($requiredGroups.Count -eq 0) {
        Write-Error "No valid admin security groups found to set permissions."
        exit 1
    }

    $targetProjectId = Get-ProjectId -ProjectName $ProjectName
    Write-Host "Target project id for '$ProjectName' is: $targetProjectId" -ForegroundColor Green
    
    $variableGroupId = Get-VariableGroupId -VariableGroupName $VariableGroupName -ProjectId $targetProjectId
    Write-Host "Variable group id for '$VariableGroupName' in project '$ProjectName' is: $variableGroupId" -ForegroundColor Green

    $securityResponse = Get-VariableGroupSecurity -VariableGroup @{ id = $variableGroupId; name = $VariableGroupName } -ProjectId $targetProjectId
    $userGroups = @()
    if ($securityResponse -and $securityResponse.value) {
        foreach ($assignment in $securityResponse.value) {

            if ($assignment.identity -and $assignment.identity.displayName -and ($assignment.role.Name -eq "Administrator" -or $assignment.role.Name -eq "User")) {
                Write-Host "##[debug]  Found administrator assignment:"
                Write-Host "##[debug]    Display Name: $($assignment.identity.displayName)"
                Write-Host "##[debug]    Role: $($assignment.role.Name)"
                Write-Host "##[debug]    Identity Local ID: $($assignment.identity.id)"

                if (!$requiredGroups.Where({ $_.localId -eq $assignment.identity.id })) {
                    $userGroups += @{ localId = $assignment.identity.id; role = "Administrator"; displayName = $assignment.identity.displayName }
                }
            }
        }
    }
    $variableGroup = @{ id = $variableGroupId; name = $VariableGroupName }
    Set-VariableGroupInheritPermissions -VariableGroup $variableGroup -ProjectId $targetProjectId -InheritPermissions $false
    Set-VariableGroupSecurity -VariableGroup $variableGroup -ProjectId $targetProjectId  -AdminGroups $requiredGroups -UserGroups $userGroups
    Write-Host "Successfully set permissions for variable group '$VariableGroupName' in project '$ProjectName' for security group '$VariableGroupAdmins'" -ForegroundColor Green
}
catch {
    Write-Error "An error occurred while setting variable group permissions: $_"
    if ($_.ErrorDetails.Message) {
        Write-Error "Details: $($_.ErrorDetails.Message)"
    }
    exit 1
}