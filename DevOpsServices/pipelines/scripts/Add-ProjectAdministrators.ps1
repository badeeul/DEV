param(
    [Parameter(Mandatory=$true)]
    [string]$OrganizationUrl,
   
    [Parameter(Mandatory=$true)]
    [string]$ClientId,
   
    [Parameter(Mandatory=$true)]
    [string]$ClientSecret,
   
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
   
    [Parameter(Mandatory=$true)]
    [string]$ProjectName,
   
    [Parameter(Mandatory=$true)]
    [string]$SecurityGroups,
   
    [Parameter(Mandatory=$false)]
    [int]$MaxRetries = 3,
   
    [Parameter(Mandatory=$false)]
    [int]$BaseRetryDelaySeconds = 5
)

#region Global Variables

$script:accessToken = $null
$script:headers = $null
$script:apiVersion = "7.1-preview.1"
$script:graphApiVersion = "7.1-preview.1"

#endregion

#region Helper Functions

function Write-Section {
    param([string]$Title)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Get-AzureAdAccessToken {
    param(
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$TenantId,
        [int]$MaxRetries = 3
    )
   
    $attempt = 1
   
    while ($attempt -le $MaxRetries) {
        try {
            Write-Host "##[debug]Acquiring Azure AD access token (Attempt $attempt of $MaxRetries)"
           
            # Azure DevOps resource ID
            $resource = "499b84ac-1321-427f-aa17-267ca6975798"
           
            $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/token"
           
            $body = @{
                grant_type    = "client_credentials"
                client_id     = $ClientId
                client_secret = $ClientSecret
                resource      = $resource
            }
           
            $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
           
            Write-Host "##[command]Successfully acquired access token"
            return $response.access_token
        }
        catch {
            if ($attempt -eq $MaxRetries) {
                Write-Error "Failed to acquire access token after $MaxRetries attempts"
                throw "Failed to authenticate with Azure AD: $_"
            }
           
            $retryDelay = 5 * [math]::Pow(2, $attempt - 1)
            Write-Host "##[debug]Waiting $retryDelay seconds before retry..."
            Start-Sleep -Seconds $retryDelay
            $attempt++
        }
    }
}

function Initialize-Headers {
    param([string]$AccessToken)
   
    $script:headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }
}

function Invoke-AzDoApiWithRetry {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [int]$MaxRetries = 3,
        [int]$BaseRetryDelaySeconds = 5
    )
   
    $attempt = 1
   
    while ($attempt -le $MaxRetries) {
        try {
            Write-Host "##[debug]API call attempt $attempt of $MaxRetries"
           
            if ($attempt -gt 1) {
                $script:accessToken = Get-AzureAdAccessToken -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId -MaxRetries 2
                Initialize-Headers -AccessToken $script:accessToken
            }
           
            $requestParams = @{
                Uri = $Uri
                Headers = $script:headers
                Method = $Method
            }
           
            if (-not [string]::IsNullOrEmpty($Body)) {
                $requestParams.Body = $Body
            }
           
            $response = Invoke-RestMethod @requestParams
            Write-Host "##[debug]API call successful"
            return $response
        }
        catch {
            $errorResponse = $null
           
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
           
            if ($attempt -eq $MaxRetries) {
                Write-Error "API call failed after $MaxRetries attempts. Last error: $_"
                if ($errorResponse) {
                    Write-Error "Response body: $errorResponse"
                }
                throw
            }
           
            $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Host "##[warning]API call failed (attempt $attempt), retrying in $retryDelay seconds"
            Start-Sleep -Seconds $retryDelay
            $attempt++
        }
    }
}

function Get-ProjectByName {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName
    )
   
    try {
        Write-Host "##[debug]Looking up project: $ProjectName"
       
        $listUri = "$OrganizationUrl/_apis/projects?api-version=7.0"
        $projectsList = Invoke-AzDoApiWithRetry -Uri $listUri -Method GET
       
        $project = $projectsList.value | Where-Object { $_.name -eq $ProjectName }
       
        if ($project) {
            Write-Host "##[debug]Found project ID: $($project.id)"
            return $project
        }
        else {
            throw "Project '$ProjectName' not found in organization"
        }
    }
    catch {
        Write-Error "Failed to get project: $_"
        throw
    }
}

function Get-SecurityGroups {
    param(
        [string]$OrganizationUrl,
        [string[]]$GroupNames
    )
   
    try {
        Write-Host "##[debug]Searching for security groups in organization..."
       
        # Step 1: Get the Group Descriptor using vssps subdomain
        $groupsUri = "$OrganizationUrl/_apis/graph/groups?api-version=$script:graphApiVersion"
        $groups = Invoke-AzDoApiWithRetry -Uri $groupsUri -Method GET
       
        Write-Host "##[debug]Found $($groups.value.Count) total groups in organization"
        Write-Host "##[debug]Security groups: $($groups.value | ConvertTo-Json -Depth 3)"

        $foundGroups = New-Object System.Collections.ArrayList

        foreach ($groupName in $GroupNames) {
            $trimmedName = $groupName.Trim()
           
            if ([string]::IsNullOrEmpty($trimmedName)) {
                continue
            }
           
            # Try exact match first
            $matchedGroup = $groups.value | Where-Object {
                $_.principalName -eq "[TEAM FOUNDATION]\$trimmedName" 
 
            }
           
            if ($matchedGroup) {
                # If multiple matches, take the first one and warn
                if ($matchedGroup -is [array]) {
                    Write-Warning "Multiple groups matched '$trimmedName', using: $($matchedGroup[0].displayName)"
                    $matchedGroup = $matchedGroup[0]
                }
               
                Write-Host "##[command]Found security group: $trimmedName" -ForegroundColor Green
                Write-Host "##[debug]  Display Name: $($matchedGroup.displayName)"
                Write-Host "##[debug]  Principal Name: $($matchedGroup.principalName)"
                Write-Host "##[debug]  Descriptor: $($matchedGroup.descriptor)"

                [void]$foundGroups.Add($matchedGroup)
            }
            else {
                Write-Warning "Security group not found: $trimmedName"
            }
        }

        $resultArray = $foundGroups.ToArray()
        return $resultArray
    }
    catch {
        Write-Error "Failed to get security groups: $_"
        throw
    }
}

function Get-SecurityGroupsProjectAdministrator {
  param(
        [string]$OrganizationUrl,
        [string]$ProjectName
    )
   
    try {
        Write-Host "##[debug]Searching for security groups in organization..."
       
        # Step 1: Get the Group Descriptor using vssps subdomain
        $groupsUri = "$OrganizationUrl/_apis/graph/groups?api-version=$script:graphApiVersion"
        $groups = Invoke-AzDoApiWithRetry -Uri $groupsUri -Method GET
       
        Write-Host "##[debug]Found $($groups.value.Count) total groups in organization"
        Write-Host "##[debug]Security groups: $($groups.value | ConvertTo-Json -Depth 3)"
            
        $matchedGroup = $groups.value | Where-Object {
            $_.principalName -eq "[$ProjectName]\Project Administrators" 
        }
        
        if ($matchedGroup) {

            Write-Host "##[command]Found security group: [$ProjectName]\Project Administrators" -ForegroundColor Green
            Write-Host "##[debug]  Display Name: $($matchedGroup.displayName)"
            Write-Host "##[debug]  Principal Name: $($matchedGroup.principalName)"
            Write-Host "##[debug]  Descriptor: $($matchedGroup.descriptor)"
        
        }
        else {
            Write-Warning "Security group not found: [$ProjectName]\Project Administrators"
        }
       
        return $matchedGroup
    }
    catch {
        Write-Error "Failed to get security groups: $_"
        throw
    }    
}


function Get-AllSecurityNamespaces {
    param(
        [string]$OrganizationUrl
    )
   
    try {
        Write-Host "##[debug]Getting all security namespaces..."
       
        $namespacesUri = "$OrganizationUrl/_apis/securitynamespaces?api-version=$script:apiVersion"
        $namespaces = Invoke-AzDoApiWithRetry -Uri $namespacesUri -Method GET

        Write-Host "##[debug]Found $($namespaces.value.Count) security namespace(s)"
        Write-Host "##[debug]Security namespaces: $($namespaces.value | ConvertTo-Json -Depth 3)"
       
        return $namespaces.value
    }
    catch {
        Write-Warning "Could not get security namespaces: $_"
        return @()
    }
}

function Get-SecurityNamespaceInfo {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName
    )
   
    try {
        Write-Host "##[debug]Getting security namespaces..."
       
        # Step 2: Get the Security Namespaces
        $namespacesUri = "$OrganizationUrl/$ProjectName/_apis/securitynamespaces?api-version=$script:apiVersion"
        # display uri for debug
        Write-Host "##[debug]Security namespaces URI: $namespacesUri"

        $namespaces = Invoke-AzDoApiWithRetry -Uri $namespacesUri -Method GET
       
        Write-Host "##[debug]Found $($namespaces.value.Count) security namespace(s)"
       
        # Look for the appropriate namespace for project-level permissions
        # The distributedtask.project scope is commonly used for project administrator assignments
        $projectScope = $namespaces.value | Where-Object {
            $_.name -like "*Project*" -or $_.name -like "*DistributedTask*"
        }
       
        if ($projectScope) {
            if ($projectScope -is [array]) {
                $projectScope = $projectScope[0]
            }
           
            Write-Host "##[command]Found security namespace" -ForegroundColor Green
            Write-Host "##[debug]  Name: $($projectScope.name)"
            Write-Host "##[debug]  Namespace ID: $($projectScope.namespaceId)"
           
            return $projectScope
        }
        else {
            Write-Warning "Could not find appropriate security namespace, using default scope"
            return $null
        }
    }
    catch {
        Write-Warning "Could not get security namespaces: $_"
        return $null
    }
}

function Verify-ProjectAdministrators {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [array]$SecurityGroups
    )
   
    try {
        Write-Host "##[debug]Verifying Project Administrator role assignments..."
       
        # Get role assignments for the project
        $scopeId = "distributedtask.project"
        $resourceId = $ProjectId
        $rolesUri = "$OrganizationUrl/_apis/securityroles/scopes/$scopeId/roleassignments/resources/$resourceId?api-version=$script:apiVersion"
       
        $roleAssignments = Invoke-AzDoApiWithRetry -Uri $rolesUri -Method GET
       
        Write-Host "`nProject Administrator Role Assignments:" -ForegroundColor Cyan
       
        $verifiedCount = 0
        foreach ($group in $SecurityGroups) {
            # Check if this group has the Administrator role
            $assignment = $roleAssignments.value | Where-Object {
                $_.identity.id -eq $group.descriptor -and
                $_.role.name -eq "Administrator"
            }
           
            if ($assignment) {
                Write-Host "   $($group.displayName)" -ForegroundColor Green
                $verifiedCount++
            }
            else {
                Write-Host "   $($group.displayName) (not verified)" -ForegroundColor Yellow
            }
        }
       
        Write-Host "`nVerified: $verifiedCount of $($SecurityGroups.Count) groups" -ForegroundColor Cyan
       
        return $verifiedCount -eq $SecurityGroups.Count
    }
    catch {
        Write-Warning "Could not verify administrator assignments: $_"
        return $false
    }
}

function Get-ProjectAdministratorsInfo {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [hashtable]$Headers
    )
   
    try {
        Write-Host "Getting Project Administrators group information..." -ForegroundColor Cyan
       
        # 1. Get Project Administrators Group
        $groupsUri = "$OrganizationUrl/_apis/graph/groups?scopeDescriptor=scp.$ProjectId&api-version=7.1-preview.1"
        #  display uri for debug
        Write-Host "##[debug]Groups URI: $groupsUri"

        $groups = Invoke-RestMethod -Uri $groupsUri -Headers $Headers -Method GET
       
        # display all groups for debug
        Write-Host "##[debug]Groups found: $($groups.value | ConvertTo-Json -Depth 3)"

        $adminGroup = $groups.value | Where-Object {
            $_.principalName -like "*\Project Administrators"
        }
       
        if (-not $adminGroup) {
            throw "Project Administrators group not found"
        }
       
        Write-Host "  Group Name: $($adminGroup.displayName)" -ForegroundColor Green
        Write-Host "  Descriptor: $($adminGroup.descriptor)" -ForegroundColor Green
        Write-Host "  Origin ID: $($adminGroup.originId)" -ForegroundColor Green
       
        # 2. Get Security Namespace for Project permissions
        $namespacesUri = "https://vssps.dev.azure.com/$OrganizationName/_apis/securitynamespaces?api-version=7.1-preview.1"
        $namespaces = Invoke-RestMethod -Uri $namespacesUri -Headers $Headers -Method GET
        # display all namespaces for debug
        Write-Host "##[debug]Namespaces found: $($namespaces.value | ConvertTo-Json -Depth 3)"
       
        $projectNamespace = $namespaces.value | Where-Object {
            $_.name -eq "Project"
        }
       
        Write-Host "  Security Namespace ID: $($projectNamespace.namespaceId)" -ForegroundColor Green
        Write-Host "  Security Namespace Name: $($projectNamespace.name)" -ForegroundColor Green
       
        # 3. Build the token for project-level permissions
        $token = "`$PROJECT:$ProjectId"
        Write-Host "  Token (for ACL): $token" -ForegroundColor Green
       
        return @{
            Group = $adminGroup
            Descriptor = $adminGroup.descriptor
            OriginId = $adminGroup.originId
            SecurityNamespaceId = $projectNamespace.namespaceId
            Token = $token
        }
    }
    catch {
        Write-Error "Failed to get Project Administrators info: $_"
        throw
    }
}


#endregion

#region Main Execution

function Add-ProjectAdministrator {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [object]$SecurityGroup,
        [object]$ProjectAdministratorsGroup
    )
   
    try {
        $groupName = $SecurityGroup.displayName
        Write-Host "##[command]Adding '$groupName' to Project Administrators group..." -ForegroundColor Cyan
       
        Write-Host "##[debug]Security Group Descriptor: $($SecurityGroup.descriptor)"
        Write-Host "##[debug]Project Administrators Group Descriptor: $($ProjectAdministratorsGroup.descriptor)"
       
        # Use Graph API to add member to group
        # PUT /_apis/graph/memberships/{memberDescriptor}/{containerDescriptor}
        $membershipUri = "$OrganizationUrl/_apis/graph/memberships/$($SecurityGroup.descriptor)/$($ProjectAdministratorsGroup.descriptor)?api-version=7.1-preview.1"
       
        Write-Host "##[debug]Membership URI: $membershipUri"
       
        # Make the PUT API call (no body needed for membership)
        $response = Invoke-AzDoApiWithRetry -Uri $membershipUri -Method PUT
       
        Write-Host "##[command]Successfully added '$groupName' to Project Administrators" -ForegroundColor Green
        Write-Host "##[debug]Response: $($response | ConvertTo-Json -Depth 2)"
       
        return $response
    }
    catch {
        Write-Error "Failed to add '$groupName' as administrator: $_"
        throw
    }
}

try {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Add Project Administrators" -ForegroundColor Green
    Write-Host "Using Service Principal Authentication" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host "  Organization URL: $OrganizationUrl"
    Write-Host "  Project Name:     $ProjectName"
    Write-Host "  Security Groups:  $SecurityGroups"
    Write-Host ""
   
    # Extract organization name from URL
    $organizationName = $OrganizationUrl.Split('/')[-1]
    Write-Host "##[debug]Organization Name: $organizationName"
   
    # Parse security groups
    $groupNames = $SecurityGroups -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    Write-Host "##[debug]Parsed $($groupNames.Count) security group(s)"
   
    # Step 0: Authenticate
    Write-Section "Step 0: Authenticating with Azure AD"
   
    $script:accessToken = Get-AzureAdAccessToken -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId -MaxRetries $MaxRetries
    Initialize-Headers -AccessToken $script:accessToken
   
    Write-Host "##[command]Authentication successful" -ForegroundColor Green
   
    # Get all security namespaces for debug, may be used later for editing project permissions level
    # $allNamespaces = Get-AllSecurityNamespaces -OrganizationUrl $OrganizationUrl
    # Write-Host "##[debug]All Security Namespaces: $($allNamespaces | ConvertTo-Json -Depth 3)"

    # Step 1: Get Project
    Write-Section "Step 1: Getting Project Information"
   
    $project = Get-ProjectByName -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
   
    Write-Host "##[command]Project found: $($project.name)" -ForegroundColor Green
    Write-Host "##[debug]Project ID: $($project.id)"
   
    # Step 2: Get Group Project Administrators Descriptor
    Write-Section "Step 2: Getting Group Project Administrators Descriptor"
   
    $organizationUrlVssp = "https://vssps.dev.azure.com/$organizationName"

    $projectAdministratorsGroup = Get-SecurityGroupsProjectAdministrator -OrganizationUrl $organizationUrlVssp -ProjectName $ProjectName

    # display project administrators group info for debug
    Write-Host "##[debug]Project Administrators Group: $($projectAdministratorsGroup | ConvertTo-Json -Depth 3)"


    $groups = Get-SecurityGroups -OrganizationUrl $organizationUrlVssp -GroupNames $groupNames
    # display security groups info for debug
    Write-Host "##[debug]Security Groups to Add: $($groups | ConvertTo-Json -Depth 3)"

    if ($groups.Count -eq 0) {
        throw "No security groups found. Please verify the group names."
    }
    Write-Host "##[command]Found $($groups.Count) security group(s)" -ForegroundColor Green

    # Step 3: Add as Project Administrators
    Write-Section "Step 3: Assigning Administrator Role to Security Groups"
   
    $successCount = 0
    $failureCount = 0

    foreach ($group in $groups) {
        try {
            # display group info for debug
            Write-Host "##[debug]Adding Security Group: $($group | ConvertTo-Json -Depth 3)"
            # display security group origin id, display name for debug
            Write-Host "##[debug]  Origin ID: $($group.originId)"   
            Write-Host "##[debug]  Display Name: $($group.displayName)"
            # display project administrators group origin id, display name, descriptor for debug
            Write-Host "##[debug]  Project Administrators Group Origin ID: $($projectAdministratorsGroup.originId)"   
            Write-Host "##[debug]  Project Administrators Group Display Name: $($projectAdministratorsGroup.displayName)"
            Write-Host "##[debug]  Project Administrators Group Descriptor: $($projectAdministratorsGroup.descriptor)"

            Add-ProjectAdministrator -OrganizationUrl $organizationUrlVssp -ProjectId $project.id -SecurityGroup $group -ProjectAdministratorsGroup $projectAdministratorsGroup
        
            $successCount++
        }
        catch {
            Write-Error "Failed to add '$($group.displayName)': $_"
            $failureCount++
        }
    }
   
    # Step 4: Verify Assignments
    Write-Section "Step 4: Verifying Administrator Role Assignments"

    $verified = Verify-ProjectAdministrators -OrganizationUrl $OrganizationUrl -ProjectId $project.id -SecurityGroups $securityGroups
   
    # Summary
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Summary" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Project: $($project.name)" -ForegroundColor Cyan
    Write-Host "Successfully Added: $successCount" -ForegroundColor Green
    Write-Host "Failed: $failureCount" -ForegroundColor $(if ($failureCount -gt 0) { "Red" } else { "Green" })
    Write-Host "Verified: $(if ($verified) { 'Yes' } else { 'Partial' })" -ForegroundColor $(if ($verified) { "Green" } else { "Yellow" })
   
    if ($successCount -gt 0) {
        Write-Host "`n Project administrators added successfully" -ForegroundColor Green
    }
   
    if ($failureCount -gt 0) {
        Write-Warning "Some security groups could not be added. Check the errors above."
        exit 1
    }
}
catch {
    Write-Error "##[error]Failed to add project administrators: $_"
    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Verify Service Principal has 'vso.security_manage' scope" -ForegroundColor White
    Write-Host "  2. Check that security groups exist in Azure DevOps organization" -ForegroundColor White
    Write-Host "  3. Ensure Service Principal is Project Collection Administrator" -ForegroundColor White
    Write-Host "  4. Verify project name is correct" -ForegroundColor White
    Write-Host "  5. Verify the project has the correct permissions configuration" -ForegroundColor White
    Write-Host ""
    exit 1
}

#endregion
