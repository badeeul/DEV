param (
    [Parameter(Mandatory = $true)]
    [string]$Organization,
   
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
   
    [Parameter(Mandatory = $true)]
    [string]$RequiredSecurityGroup,
   
    [Parameter(Mandatory = $false)]
    [string]$OptionalSecurityGroup = "",

    [Parameter(Mandatory = $false)]
    [string]$Environment = "INT", # Default to INT, can be overridden in pipeline

    [string]$LifecycleEnvironmentName = "lifecycleManagementApproval",
    [string]$FeatureEnvironmentName = "featureManagementApproval",
    [string]$ProductionEnvironmentName = "productionManagementApproval",
    [int]$TimeoutInMinutes = 4320 # Default 3 days
)

function Get-DevOpsAuthToken {
    try {
        $resource = "499b84ac-1321-427f-aa17-267ca6975798"
        $authUrl = "https://login.microsoftonline.com/$env:ARM_TENANT_ID/oauth2/token"

        # Construct token request
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $env:ARM_CLIENT_ID
            client_secret = $env:ARM_CLIENT_SECRET              
            resource      = $resource
        }

        # Get token
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

# Function to create authorization headers
function Get-AuthorizationHeader {
    param (
        [string]$Token
    )
   
    $headers = @{
        Authorization  = "Basic $Token"
        Accept         = "application/json"
        "Content-Type" = "application/json"
    }
    return $headers
}

function Format-GitUrl {
    param ([string]$value)
    return $value.Replace(' ', '%20')
}

function Add-EnvironmentSecurity {
    param (
        [PSCustomObject]$Environment,
        [PSCustomObject]$SecurityGroup,
        [string]$ProjectId,
        [hashtable]$Headers,
        [string]$RoleName = "Administrator"
    )
   
    Write-Host "##[debug]Adding environment security for group: $($SecurityGroup.displayName)"
   
    # Get User ID from entitlements for the security group
    $userId = $SecurityGroup.originId
   
    if ($null -eq $userId) {
        Write-Warning "Could not find user ID for group '$($SecurityGroup.displayName)' in entitlements. Skipping role assignment."
        return $false
    }
   
    # Construct Security Roles API URL
    $resourceIdentifier = "${ProjectId}_$($Environment.id)"
    $apiUrl = "https://dev.azure.com/$Organization/_apis/securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/$resourceIdentifier`?api-version=5.0-preview.1"
   
    Write-Host "##[debug]Security Roles API URL: $apiUrl"
   
    # Create role assignment payload
    $roleAssignment = @(
        @{
            userId   = $userId
            roleName = $RoleName
        }
    )
   
    $roleAssignmentBody = "[$($roleAssignment | ConvertTo-Json -Depth 3)]"
    Write-Host "##[debug]Role assignment body: $roleAssignmentBody" 
   
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Put -Body $roleAssignmentBody -ErrorAction Stop
        Write-Host "##[debug]Role assignment response: $($response | ConvertTo-Json -Depth 10)"
       
        Write-Host "##[debug]Successfully added '$($SecurityGroup.displayName)' as $RoleName to environment '$($Environment.name)'"
        return $true
    }
    catch {
        Write-Error "Failed to add environment security for group '$($SecurityGroup.displayName)': $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        return $false
    }
}

function Get-EnvironmentSecurity {
    param (
        [PSCustomObject]$Environment,
        [string]$ProjectId,
        [hashtable]$Headers
    )
   
    Write-Host "##[debug]Getting environment security for: $($Environment.name)"
   
    # Construct Security Roles API URL to GET current assignments
    $resourceIdentifier = "${ProjectId}_$($Environment.id)"
    $apiUrl = "https://dev.azure.com/$Organization/_apis/securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/$resourceIdentifier`?api-version=7.1-preview.1"
   
    Write-Host "##[debug]Environment Security API URL: $apiUrl"
   
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Get -ErrorAction Stop
        Write-Host "##[debug]Environment security response: $($response | ConvertTo-Json -Depth 10)"
       
        if ($response -and $response.Count -gt 0) {
            Write-Host "##[debug]Found $($response.Count) security role assignments for environment '$($Environment.name)'"
           
            foreach ($assignment in $response.value) {
                Write-Host "##[debug]  Role Assignment:"
                Write-Host "##[debug]    Display Name: $($assignment.identity.displayName)"
                Write-Host "##[debug]    Role: $($assignment.role.Name)"
            }
        }
        else {
            Write-Host "##[debug]No security role assignments found for environment '$($Environment.name)'"
        }
       
        return $response
    }
    catch {
        Write-Error "Error getting environment security: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        return $null
    }
}

function Update-ProjectValidUsersRole {
    param (
        [PSCustomObject]$Environment,
        [string]$ProjectId,
        [hashtable]$Headers,
        [string]$ProjectValidUserGroupName = "Project Valid Users",
        [string]$FromRole = "Reader",
        [string]$ToRole = "Administrator"
    )
   
    Write-Host "##[debug]Looking for '$ProjectValidUserGroupName' to update role from '$FromRole' to '$ToRole'"
   
    # Get current environment security
    $currentSecurity = Get-EnvironmentSecurity -Environment $Environment -ProjectId $ProjectId -Headers $Headers
   
    if ($null -eq $currentSecurity -or $currentSecurity.Count -eq 0) {
        Write-Warning "No security assignments found for environment '$($Environment.name)'"
        return $false
    }
   
    # Find Project Valid Users group
    $projectValidUsersAssignment = $null
    foreach ($assignment in $currentSecurity.value) {
        $displayName = $assignment.identity.displayName
        $currentRole = $assignment.role.Name
       
        Write-Host "##[debug]Checking assignment: '$displayName' with role '$currentRole'"
       
        # Check if this is the Project Valid Users group (case-insensitive partial match)
        if ($displayName -like "*$ProjectValidUserGroupName*" -or
            $displayName -like "*Project Valid Users*" -or
            $displayName -eq $ProjectValidUserGroupName) {
           
            Write-Host "##[debug]Found Project Valid Users group: '$displayName' with role: '$currentRole'"
            $projectValidUsersAssignment = $assignment
            break
        }
    }
   
    if ($null -eq $projectValidUsersAssignment) {
        Write-Warning "Project Valid Users group not found in environment security for '$($Environment.name)'"
        return $false
    }
   
    # Check if role update is needed
    if ($projectValidUsersAssignment.role.Name -eq $ToRole) {
        Write-Host "##[debug] Project Valid Users already has '$ToRole' role in environment '$($Environment.name)'"
        return $true
    }
   
    if ($projectValidUsersAssignment.role.Name -ne $FromRole) {
        Write-Warning "Project Valid Users has role '$($projectValidUsersAssignment.role.Name)' instead of expected '$FromRole'. Updating anyway..."
    }
   
    # Create updated role assignments - keep all existing assignments but update the Project Valid Users role
    $updatedAssignments = @()

    $updatedAssignments += @{
        userId   = $projectValidUsersAssignment.identity.id
        roleName = $ToRole
    }  
   
    # Apply the updated role assignments
    $updateSuccess = Set-EnvironmentSecurity -Environment $Environment -ProjectId $ProjectId -RoleAssignments $updatedAssignments -Headers $Headers
   
    if ($updateSuccess) {
        Write-Host "##[debug] Successfully updated Project Valid Users role from '$FromRole' to '$ToRole' in environment '$($Environment.name)'"
        return $true
    }
    else {
        Write-Error "Failed to update Project Valid Users role in environment '$($Environment.name)'"
        return $false
    }
}

function Set-EnvironmentSecurity {
    param (
        [PSCustomObject]$Environment,
        [string]$ProjectId,
        [array]$RoleAssignments,
        [hashtable]$Headers
    )
   
    Write-Host "##[debug]Setting environment security with $($RoleAssignments.Count) assignments"
   
    # Construct Security Roles API URL
    $resourceIdentifier = "${ProjectId}_$($Environment.id)"
    $apiUrl = "https://dev.azure.com/$Organization/_apis/securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/$resourceIdentifier`?api-version=7.1-preview.1"
   
    Write-Host "##[debug]Security Roles API URL: $apiUrl"
   
    # Convert role assignments to JSON array (handle single item array issue)
    if ($RoleAssignments.Count -eq 1) {
        # Force array format for single item
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $roleAssignmentBody = $RoleAssignments | ConvertTo-Json -Depth 3 -AsArray
        }
        else {
            $singleObjectJson = $RoleAssignments[0] | ConvertTo-Json -Depth 3
            $roleAssignmentBody = "[$singleObjectJson]"
        }
    }
    else {
        # Multiple items naturally create an array
        $roleAssignmentBody = $RoleAssignments | ConvertTo-Json -Depth 3
    }
   
    Write-Host "##[debug]Role assignments body: $roleAssignmentBody"
   
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Put -Body $roleAssignmentBody -ErrorAction Stop
        Write-Host "##[debug]Role assignment response: $($response | ConvertTo-Json -Depth 10)"
       
        Write-Host "##[debug]Successfully updated environment security for '$($Environment.name)'"
        return $true
    }
    catch {
        Write-Error "Failed to set environment security: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        Write-Host "##[debug]Failed request body: $roleAssignmentBody"
        return $false
    }
}

# get security group using IdentityPicker API
function Get-SecurityGroupWithLocalId {
    param (
        [string]$GroupName,
        [hashtable]$Headers
    )
   
    if ([string]::IsNullOrEmpty($GroupName)) {
        Write-Warning "Group name cannot be empty"
        return $null
    }
   
    Write-Host "##[debug]Looking up security group using IdentityPicker API: $GroupName in organization: $Organization"
   
    # Construct IdentityPicker API URL
    $apiUrl = "https://$Organization.visualstudio.com/_apis/IdentityPicker/Identities?api-version=7.1-preview.1"
   
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
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Post -Body $requestBody -ErrorAction Stop
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

# Function to check if an environment exists
function Get-Environment {
    param (
        [string]$Name,
        [hashtable]$Headers
    )
   
    Write-Host "##[debug]Checking if environment '$Name' exists..."

    $apiUrl = "https://dev.azure.com/$Organization/$encodedProjectName/_apis/distributedtask/environments?api-version=7.1-preview.1"
    Write-Host "##[debug]API URL: $apiUrl"
   
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Get -ErrorAction Stop
        Write-Host "##[debug]Response: $($response | ConvertTo-Json -Depth 10)"

        foreach ($env in $response.value) {
            if ($env.name -eq $Name) {
                Write-Host "##[debug]Environment '$Name' found with ID: $($env.id)"
                return $env
            }
        }
       
        Write-Host "##[debug]Environment '$Name' not found"
        return $null
    }
    catch {
        Write-Error "Error querying environments: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        return $null
    }
}

# Function to create a new environment
function New-Environment {
    param (
        [string]$Name,
        [hashtable]$Headers
    )
   
    Write-Host "##[debug]Creating new environment: $Name"

    $apiUrl = "https://dev.azure.com/$Organization/$encodedProjectName/_apis/distributedtask/environments?api-version=7.1-preview.1"
    Write-Host "##[debug]API URL: $apiUrl"
   
    $environmentBody = @{
        name        = $Name
        description = "Created via automation script"
    } | ConvertTo-Json -Depth 2
   
    Write-Host "##[debug]Request Body: $environmentBody"
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Post -Body $environmentBody -ErrorAction Stop
        Write-Host "##[debug]Response: $($response | ConvertTo-Json -Depth 10)"
       
        Write-Host "##[debug]Environment created successfully with ID: $($response.id)"
        return $response
    }
    catch {
        Write-Error "Error creating environment: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        return $null
    }
}

# Function to configure environment with approval checks AND security
function Configure-Environment {
    param (
        [string]$EnvironmentName,
        [object[]]$RequiredGroup,
        [PSCustomObject]$OptionalGroup,
        [string]$ProjectId,
        [int]$TimeoutInMinutes,
        [hashtable]$Headers
    )
   
    Write-Host "##[section]Configuring environment: $EnvironmentName"
   
    # Get or create environment
    $environment = Get-Environment -Name $EnvironmentName -Headers $Headers
   
    if ($null -eq $environment) {
        $environment = New-Environment -Name $EnvironmentName -Headers $Headers
       
        if ($null -eq $environment) {
            Write-Error "Failed to create environment '$EnvironmentName'."
            return $false
        }
    }
   
    # Remove existing approval checks
    $existingChecks = Get-EnvironmentChecks -Environment $environment -Headers $Headers
    if ($null -ne $existingChecks) {      
        foreach ($check in $existingChecks) {
            Write-Host "##[debug]Found existing checks in $EnvironmentName. Removing..."
            if ($check.type.name -eq "Approval") {
                $removed = Remove-EnvironmentCheck -Environment $environment -CheckId $check.id -Headers $Headers
               
                if (-not $removed) {
                    Write-Warning "Failed to remove existing approval check. Will attempt to update."
                }
            }
        }
    }
   
    # Add approval checks
    $approvalSuccess = Add-ApprovalCheck -Environment $environment -RequiredGroup $RequiredGroup -OptionalGroup $OptionalGroup -TimeoutInMinutes $TimeoutInMinutes -Headers $Headers
   
    # if (-not $approvalSuccess) {
    #     Write-Error "Failed to configure approval checks for environment '$EnvironmentName'"
    #     return $false
    # }
   
    # Write-Host "##[debug]Adding environment security roles..."
   
    # $requiredSecuritySuccess = Add-EnvironmentSecurity -Environment $environment -SecurityGroup $RequiredGroup -ProjectId $ProjectId -Headers $Headers -RoleName "Administrator"
   
    # if (-not $requiredSecuritySuccess) {
    #     Write-Warning "Failed to add required group as environment administrator, but continuing..."
    # }
   
    # # Add environment security for optional group (if exists)
    # if ($null -ne $OptionalGroup) {
    #     $optionalSecuritySuccess = Add-EnvironmentSecurity -Environment $environment -SecurityGroup $OptionalGroup -ProjectId $ProjectId -Headers $Headers -RoleName "Administrator"
       
    #     if (-not $optionalSecuritySuccess) {
    #         Write-Warning "Failed to add optional group as environment administrator, but continuing..."
    #     }
    # }
      
    Write-Host "##[section] Environment '$EnvironmentName' configured successfully!" -ForegroundColor Green
    return $environment
}

function Add-ApprovalCheck {
    param (
        [PSCustomObject]$Environment,
        [object[]]$RequiredGroup,
        [PSCustomObject]$OptionalGroup,
        [int]$TimeoutInMinutes,
        [hashtable]$Headers
    )
   
    Write-Host "##[debug]Adding approval check to environment '$($Environment.name)'..."
   
    # Create approvers array using localId (correct approver ID)
    $approvers = @()

    # Add required groups (supporting multiple groups)
    if ($null -ne $RequiredGroup) {
        foreach ($rg in $RequiredGroup) {
            if ($null -eq $rg) { continue }
            if ($null -eq $rg.localId) {
                Write-Warning "Required group '$($rg.displayName)' does not have a localId. Skipping."
                continue
            }
            $approvers += @{
                id          = $rg.localId
                displayName = $rg.displayName
            }
            Write-Host "##[debug]Added required approver: $($rg.displayName) with ID: $($rg.localId)"
        }
    }

    # Add optional group to approvers if it exists using localId
    if ($null -ne $OptionalGroup) {
        if ($null -ne $OptionalGroup.localId) {
            $approvers += @{
                id          = $OptionalGroup.localId
                displayName = $OptionalGroup.displayName
            }
            Write-Host "##[debug]Added optional approver: $($OptionalGroup.displayName) with ID: $($OptionalGroup.localId)"
        }
        else {
            Write-Warning "Optional group '$($OptionalGroup.displayName)' does not have a localId. Skipping."
        }
    }
   
    # Validate that we have at least one approver
    if ($approvers.Count -eq 0) {
        Write-Error "No valid approvers found. Cannot create approval check."
        return $false
    }
   
    # Create check payload
    $checkPayload = @{
        type     = @{
            id   = "8C6F20A7-A545-4486-9777-F762FAFE0D4D" # ID for approval check
            name = "Approval"
        }
        settings = @{
            executionOrder            = 1
            instructions              = "Please review the deployment details before approving."
            minRequiredApprovers      = 1
            approvers                 = $approvers
            requesterCannotBeApprover = $false
            approverCount             = $approvers.Count
            approvalsRequired         = 1  
        }
        timeout  = $TimeoutInMinutes
        resource = @{
            type = "environment"
            id   = $Environment.id.ToString()
            name = $Environment.name
        }
    } | ConvertTo-Json -Depth 10
   
    $apiUrl = "https://dev.azure.com/$Organization/$encodedProjectName/_apis/pipelines/checks/configurations?api-version=7.1-preview.1"
    Write-Host "##[debug]API URL: $apiUrl"
    Write-Host "##[debug]Request Body: $checkPayload"
   
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Post -Body $checkPayload -ErrorAction Stop
        Write-Host "##[debug]Response: $($response | ConvertTo-Json -Depth 10)"
       
        Write-Host "##[debug]Approval check added successfully to environment '$($Environment.name)'"
        return $true
    }
    catch {
        Write-Error "Failed to add approval check: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        return $false
    }
}

# Function to get existing checks on an environment
function Get-EnvironmentChecks {
    param (
        [PSCustomObject]$Environment,
        [hashtable]$Headers
    )
   
    Write-Host "##[debug]Getting existing checks for environment '$($Environment.name)'..."
   
    $apiUrl = "https://dev.azure.com/$Organization/$encodedProjectName/_apis/pipelines/checks/configurations?resourceType=environment&resourceId=$($Environment.id)&api-version=7.1-preview.1"
    Write-Host "##[debug]API URL: $apiUrl"
   
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Get -ErrorAction Stop
        Write-Host "##[debug]Response: $($response | ConvertTo-Json -Depth 10)"
       
        return $response.value
    }
    catch {
        Write-Error "Error querying environment checks: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        return $null
    }
}

# Function to delete an existing check
function Remove-EnvironmentCheck {
    param (
        [PSCustomObject]$Environment,
        [int]$CheckId,
        [hashtable]$Headers
    )
   
    Write-Host "##[debug]Removing check ID $CheckId from environment '$($Environment.name)'..."
   
    $apiUrl = "https://dev.azure.com/$Organization/$encodedProjectName/_apis/pipelines/checks/configurations/$CheckId`?api-version=7.1-preview.1"
    Write-Host "##[debug]API URL: $apiUrl"
   
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Delete -ErrorAction Stop
        Write-Host "##[debug]Response: $($response | ConvertTo-Json -Depth 10)"

        Write-Host "##[debug]Check removed successfully"
        return $true
    }
    catch {
        Write-Error "Error deleting check: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        return $false
    }
}

function Get-ProjectId {
    param (
        [string]$Organization,
        [string]$ProjectName,
        [hashtable]$Headers
    )
   
    Write-Host "##[debug]Looking up Project ID for: $ProjectName"
   
    # Construct API URL to get project details
    $apiUrl = "https://dev.azure.com/$Organization/_apis/projects?api-version=7.0"
    Write-Host "##[debug]API URL: $apiUrl"
   
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Get -ErrorAction Stop

        # Filter response by project name
        $project = $response.value | Where-Object { $_.name -eq $ProjectName }
       
        if ($null -eq $project) {
            throw "Project '$ProjectName' not found in organization '$Organization'"
        }
       
        Write-Host "##[debug]Found project response: $($project | ConvertTo-Json -Depth 3)"
        $projectId = $project.id
        Write-Host "##[debug]Found Project ID: $projectId"
       
        return $projectId
    }
    catch {
        Write-Error "Error getting project ID: $_"
        if ($_.ErrorDetails.Message) {
            Write-Error "Details: $($_.ErrorDetails.Message)"
        }
        throw
    }
}

# Main script execution
try {
    Write-Host "##[section]Starting Azure DevOps Environment Creation"
    Write-Host "##[debug]Organization: $Organization"
    Write-Host "##[debug]Project: $ProjectName"
    Write-Host "##[debug]Required Security Group: $RequiredSecurityGroup"
    Write-Host "##[debug]Optional Security Group: $OptionalSecurityGroup"
   
    # only execute for environment with INT or PRD
    if (-not ($Environment -eq 'INT' -or $Environment -eq 'PRD')) {
        Write-Host "Skipping environment creation for $Environment"
        exit 0
    }

    $token = Get-DevOpsAuthToken
    $headers = Get-AuthorizationHeader -Token $token
    $encodedProjectName = Format-GitUrl $ProjectName

    $projectId = Get-ProjectId -Organization $Organization -ProjectName $ProjectName -Headers $headers
    Write-Host "##[debug]Project ID: $projectId"

    # Validate security groups using IdentityPicker API
    Write-Host "##[section]Step 1: Validating Security Groups"

    # Support comma-separated list of required groups
    $requiredGroupNames = @()
    if (-not [string]::IsNullOrEmpty($RequiredSecurityGroup)) {
        $requiredGroupNames = $RequiredSecurityGroup -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrEmpty($_) }
    }

    if ($requiredGroupNames.Count -eq 0) {
        Write-Error "No required security groups provided in \$RequiredSecurityGroup"
        exit 1
    }

    $requiredGroups = @()
    foreach ($name in $requiredGroupNames) {
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
   
    $optionalGroup = $null
    if (-not [string]::IsNullOrEmpty($OptionalSecurityGroup)) {
        $optionalGroup = Get-SecurityGroupWithLocalId -GroupName $OptionalSecurityGroup -Headers $headers
       
        if ($null -eq $optionalGroup) {
            Write-Warning "Optional security group '$OptionalSecurityGroup' not found. Continuing with only required group."
        }
        else {
            Write-Host "##[debug] Optional group validated:"
            Write-Host "##[debug]  Name: $($optionalGroup.displayName)"
            Write-Host "##[debug]  Approver ID (localId): $($optionalGroup.localId)"
            Write-Host "##[debug]  Origin ID: $($optionalGroup.originId)"
        }
    }
   
    if ($Environment -eq 'INT') {
        # Configure Lifecycle Environment (with both approval and security)
        Write-Host "##[section]Step 2: Configuring Lifecycle Environment"
        $lifecycleSuccess = Configure-Environment -EnvironmentName $LifecycleEnvironmentName -RequiredGroup $requiredGroups -OptionalGroup $optionalGroup -ProjectId $projectId -TimeoutInMinutes $TimeoutInMinutes -Headers $headers
   
        if (-not $lifecycleSuccess) {
            Write-Error "Failed to configure lifecycle environment"
            exit 1
        }

        Update-ProjectValidUsersRole -Environment $lifecycleSuccess -ProjectId $projectId -Headers $headers -ProjectValidUserGroupName "Project Valid Users" -FromRole "Reader" -ToRole "Administrator"

        # Configure Feature Environment (with approval and security, required group only)
        Write-Host "##[section]Step 3: Configuring Feature Environment"
        $featureSuccess = Configure-Environment -EnvironmentName $FeatureEnvironmentName -RequiredGroup $requiredGroups -OptionalGroup $null -ProjectId $projectId -TimeoutInMinutes $TimeoutInMinutes -Headers $headers
   
        if (-not $featureSuccess) {
            Write-Error "Failed to configure feature environment"
            exit 1
        }
   
        Update-ProjectValidUsersRole -Environment $featureSuccess -ProjectId $projectId -Headers $headers -ProjectValidUserGroupName "Project Valid Users" -FromRole "Reader" -ToRole "Administrator"

        Write-Host "##[section] All environments configured successfully with approvals AND security!" -ForegroundColor Green
        Write-Host "##[debug]Summary:"
        Write-Host "##[debug]   $LifecycleEnvironmentName Configured with both groups as approvers and administrators"
        Write-Host "##[debug]   $FeatureEnvironmentName Configured with required group as approver and administrator"
    }
    elseif ($Environment -eq 'PRD') {
        # Configure Production Environment (with approval and security, required group only)
        Write-Host "##[section]Step 2: Configuring Production Environment"
        $productionSuccess = Configure-Environment -EnvironmentName $ProductionEnvironmentName -RequiredGroup $requiredGroups -OptionalGroup $optionalGroup -ProjectId $projectId -TimeoutInMinutes $TimeoutInMinutes -Headers $headers
   
        if (-not $productionSuccess) {
            Write-Error "Failed to configure production environment"
            exit 1
        }
   
        Update-ProjectValidUsersRole -Environment $productionSuccess -ProjectId $projectId -Headers $headers -ProjectValidUserGroupName "Project Valid Users" -FromRole "Reader" -ToRole "Administrator"

        Write-Host "##[section] Production environment configured successfully with approvals AND security!" -ForegroundColor Green
        Write-Host "##[debug]Summary:"
        Write-Host "##[debug]   $ProductionEnvironmentName Configured with required group as approver and administrator"
    }

}
catch {
    Write-Error "An error occurred: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
}