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
    [string]$projectTeamsFilePath,
   
    [Parameter(Mandatory=$false)]
    [int]$MaxRetries = 3,
   
    [Parameter(Mandatory=$false)]
    [int]$BaseRetryDelaySeconds = 5
)

#region Global Variables

$script:accessToken = $null
$script:headers = $null
$script:apiVersion = "7.1"
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
       
        $listUri = "$OrganizationUrl/_apis/projects?api-version=$script:apiVersion"
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
        if ($GroupNames.Count -eq 0) {
            return @()
        }
       
        Write-Host "##[debug]Searching for $($GroupNames.Count) security group(s) in organization..."
       
        # Get all groups in the organization
        $groupsUri = "$OrganizationUrl/_apis/graph/groups?api-version=$script:graphApiVersion"
        $groups = Invoke-AzDoApiWithRetry -Uri $groupsUri -Method GET
       
        Write-Host "##[debug]Found $($groups.value.Count) total groups in organization"
       
        $foundGroups = @()
       
        foreach ($groupName in $GroupNames) {
            $trimmedName = $groupName.Trim()
           
            if ([string]::IsNullOrEmpty($trimmedName)) {
                continue
            }
           
            # Try exact match first
            $matchedGroup = $groups.value | Where-Object {
                $_.displayName -eq $trimmedName -or
                $_.principalName -eq $trimmedName -or
                $_.principalName -like "*\$trimmedName" -or
                $_.displayName -like "*$trimmedName*"
            }
           
            if ($matchedGroup) {
                # If multiple matches, take the first one and warn
                if ($matchedGroup -is [array]) {
                    Write-Warning "Multiple groups matched '$trimmedName', using: $($matchedGroup[0].displayName)"
                    $matchedGroup = $matchedGroup[0]
                }
               
                Write-Host "##[command]Found security group: $trimmedName" -ForegroundColor Green
                Write-Host "##[debug]  Display Name: $($matchedGroup.displayName)"
                Write-Host "##[debug]  Descriptor: $($matchedGroup.descriptor)"
               
                $foundGroups += $matchedGroup
            }
            else {
                Write-Warning "Security group not found: $trimmedName"
            }
        }
       
        return $foundGroups
    }
    catch {
        Write-Error "Failed to get security groups: $_"
        throw
    }
}

function Get-Users {
    param(
        [string]$OrganizationUrl,
        [string[]]$UserIdentifiers
    )
   
    try {
        if ($UserIdentifiers.Count -eq 0) {
            return @()
        }
       
        Write-Host "##[debug]Searching for $($UserIdentifiers.Count) user(s) in organization..."
       
        # Get all users in the organization
        $usersUri = "$OrganizationUrl/_apis/graph/users?api-version=$script:graphApiVersion"
        $users = Invoke-AzDoApiWithRetry -Uri $usersUri -Method GET
       
        Write-Host "##[debug]Found $($users.value.Count) total users in organization"
       
        $foundUsers = @()
       
        foreach ($userIdentifier in $UserIdentifiers) {
            $trimmedIdentifier = $userIdentifier.Trim()
           
            if ([string]::IsNullOrEmpty($trimmedIdentifier)) {
                continue
            }
           
            # Try to match by principal name, display name, or mail address
            $matchedUser = $users.value | Where-Object {
                $_.principalName -eq $trimmedIdentifier -or
                $_.displayName -eq $trimmedIdentifier -or
                $_.mailAddress -eq $trimmedIdentifier -or
                $_.principalName -like "*$trimmedIdentifier*"
            }
           
            if ($matchedUser) {
                # If multiple matches, take the first one and warn
                if ($matchedUser -is [array]) {
                    Write-Warning "Multiple users matched '$trimmedIdentifier', using: $($matchedUser[0].displayName)"
                    $matchedUser = $matchedUser[0]
                }
               
                Write-Host "##[command]Found user: $trimmedIdentifier" -ForegroundColor Green
                Write-Host "##[debug]  Display Name: $($matchedUser.displayName)"
                Write-Host "##[debug]  Principal Name: $($matchedUser.principalName)"
                Write-Host "##[debug]  Descriptor: $($matchedUser.descriptor)"
               
                $foundUsers += $matchedUser
            }
            else {
                Write-Warning "User not found: $trimmedIdentifier"
            }
        }
       
        return $foundUsers
    }
    catch {
        Write-Error "Failed to get users: $_"
        throw
    }
}

function Get-ProjectTeam {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [string]$TeamName
    )
   
    try {
        Write-Host "##[debug]Checking if team '$TeamName' already exists..."
       
        # Get all teams in the project
        $teamsUri = "$OrganizationUrl/_apis/projects/$ProjectId/teams?api-version=$script:apiVersion"
        $teams = Invoke-AzDoApiWithRetry -Uri $teamsUri -Method GET
       
        # Find team by name (case-insensitive)
        $existingTeam = $teams.value | Where-Object {
            $_.name -eq $TeamName
        }
       
        if ($existingTeam) {
            Write-Host "##[command]Team '$TeamName' already exists" -ForegroundColor Yellow
            Write-Host "##[debug]  Team ID: $($existingTeam.id)"
            Write-Host "##[debug]  Description: $($existingTeam.description)"
            return $existingTeam
        }
        else {
            Write-Host "##[debug]Team '$TeamName' does not exist"
            return $null
        }
    }
    catch {
        Write-Warning "Could not check for existing team: $_"
        return $null
    }
}

function Get-ProjectTeamDescriptor {
  param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [string]$TeamName
    )
   
    try {
        Write-Host "##[debug]Searching for security groups in organization..."
       
        # Step 1: Get the Group Descriptor using vssps subdomain
        $groupsUri = "$OrganizationUrl/_apis/graph/groups?api-version=$script:graphApiVersion"
        $groups = Invoke-AzDoApiWithRetry -Uri $groupsUri -Method GET
       
        Write-Host "##[debug]Found $($groups.value.Count) total groups in organization"
            
        $matchedGroup = $groups.value | Where-Object {
            $_.principalName -eq "[$ProjectName]\$TeamName"
        }
        
        if ($matchedGroup) {

            Write-Host "##[command]Found security group: [$ProjectName]\$TeamName" -ForegroundColor Green
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


function New-ProjectTeam {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [string]$TeamName,
        [string]$TeamDescription,
        [array]$Members
    )
   
    try {
        # Check if team already exists
        $existingTeam = Get-ProjectTeam -OrganizationUrl $OrganizationUrl -ProjectId $ProjectId -TeamName $TeamName
        $organizationName = $OrganizationUrl.Split('/')[-1]
        if ($existingTeam) {
            Write-Host "##[command]Team already exists, updating team..." -ForegroundColor Cyan

            # get project teams descriptor
            $projectTeamDescriptor = Get-ProjectTeamDescriptor -OrganizationUrl "https://vssps.dev.azure.com/$organizationName" -ProjectName $ProjectName -TeamName $TeamName
            if ($Members.Count -gt 0) {
                Write-Host "##[debug]Adding/Updating $($Members.Count) member(s) to team"
                $memberDescriptors = @($Members | ForEach-Object {
                    
                    $membershipUri = "https://vssps.dev.azure.com/$organizationName/_apis/graph/memberships/$($_.descriptor)/$($projectTeamDescriptor.descriptor)?api-version=7.1-preview.1"
                    Write-Host "##[debug]Adding member with descriptor $($_.descriptor) via URI: $membershipUri"

                    # Make the PUT API call (no body needed for membership)
                    $response = Invoke-AzDoApiWithRetry -Uri $membershipUri -Method PUT
                    Write-Host "##[command]Successfully updated team: $TeamName" -ForegroundColor Green
                })                
  
            }
        }
        else {
            Write-Host "##[debug]Creating new team: $TeamName"
           
            # Build the Teams API URI for creation
            $teamsUri = "$OrganizationUrl/_apis/projects/$ProjectId/teams?api-version=$script:apiVersion"
           
            # Build request body for POST
            $body = @{
                name = $TeamName
            }
           
            if (-not [string]::IsNullOrEmpty($TeamDescription)) {
                $body.description = $TeamDescription
            }
           
            # Add members to the identity object if provided
            if ($Members.Count -gt 0) {
                Write-Host "##[debug]Adding $($Members.Count) member(s) to team creation request"
               
            $memberDescriptors = $Members | ForEach-Object {
                $descriptorParts = $_.descriptor -split '\.'
               
                @{
                    # identityType = if ($descriptorParts.Length -gt 0) { $descriptorParts[0] } else { "aad" }
                    identifier = $_.descriptor
                }
            }  
                Write-Host "##[debug]Member descriptors count: $($memberDescriptors.Count)"
               
                $body.identity = @{
                    members = $memberDescriptors
                }
            }
           
            $bodyJson = $body | ConvertTo-Json -Depth 10
           
            Write-Host "##[debug]Request URI: $teamsUri"
            Write-Host "##[debug]Request method: POST"
            Write-Host "##[debug]Request body: $bodyJson"
           
            # Make the POST API call
            $team = Invoke-AzDoApiWithRetry -Uri $teamsUri -Method POST -Body $bodyJson
           
            Write-Host "##[command]Successfully created team: $TeamName" -ForegroundColor Green
            Write-Host "##[debug]Team ID: $($team.id)"
           
            $projectTeamDescriptor = Get-ProjectTeamDescriptor -OrganizationUrl "https://vssps.dev.azure.com/$organizationName" -ProjectName $ProjectName -TeamName $TeamName
            if ($Members.Count -gt 0) {
                Write-Host "##[debug]Adding/Updating $($Members.Count) member(s) to team"
                $memberDescriptors = @($Members | ForEach-Object {
                    
                    $membershipUri = "https://vssps.dev.azure.com/$organizationName/_apis/graph/memberships/$($_.descriptor)/$($projectTeamDescriptor.descriptor)?api-version=7.1-preview.1"
                    Write-Host "##[debug]Adding member with descriptor $($_.descriptor) via URI: $membershipUri"

                    # Make the PUT API call (no body needed for membership)
                    $response = Invoke-AzDoApiWithRetry -Uri $membershipUri -Method PUT
                    Write-Host "##[command]Successfully updated team: $TeamName" -ForegroundColor Green
                })                
  
            }
                       
            if ($Members.Count -gt 0) {
                Write-Host "##[command]Added $($Members.Count) member(s) during team creation" -ForegroundColor Green
            }
        
        }
    }
    catch {
        Write-Error "Failed to create/update team '$TeamName': $_"
        throw
    }
}


function Get-TeamMembers {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [string]$TeamId
    )
   
    try {
        Write-Host "##[debug]Retrieving team members..."
       
        # Get team members
        $membersUri = "$OrganizationUrl/_apis/projects/$ProjectId/teams/$TeamId/members?api-version=$script:apiVersion"
        $members = Invoke-AzDoApiWithRetry -Uri $membersUri -Method GET
       
        return $members.value
    }
    catch {
        Write-Warning "Could not retrieve team members: $_"
        return @()
    }
}

function Verify-TeamMembers {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectId,
        [string]$TeamId,
        [array]$ExpectedMembers
    )
   
    try {
        Write-Host "##[debug]Verifying team membership..."
       
        $actualMembers = Get-TeamMembers -OrganizationUrl $OrganizationUrl -ProjectId $ProjectId -TeamId $TeamId
       
        Write-Host "`nTeam Members:" -ForegroundColor Cyan
       
        $verifiedCount = 0
        foreach ($expectedMember in $ExpectedMembers) {
            $found = $actualMembers | Where-Object { $_.identity.id -eq $expectedMember.descriptor }
           
            $memberName = $expectedMember.displayName
           
            if ($found) {
                Write-Host "  $memberName" -ForegroundColor Green
                $verifiedCount++
            }
            else {
                Write-Host "  $memberName (not verified)" -ForegroundColor Yellow
            }
        }
       
        Write-Host "`nVerified: $verifiedCount of $($ExpectedMembers.Count) members" -ForegroundColor Cyan
       
        return $verifiedCount -eq $ExpectedMembers.Count
    }
    catch {
        Write-Warning "Could not verify team members: $_"
        return $false
    }
}

function Parse-ProjectTeamsJson {
    param(
        [string]$JsonString
    )
   
    try {
        Write-Host "##[debug]Parsing project teams JSON configuration..."
       
        $config = $JsonString | ConvertFrom-Json
       
        if (-not $config) {
            throw "JSON must contain 'projectTeams' array"
        }
       
        # Group by team name to consolidate members
        $teamDefinitions = @{}
       
        foreach ($entry in $config) {
            $teamName = $entry.name
            $memberType = $entry.type
            $members = $entry.members
           
            if ([string]::IsNullOrEmpty($teamName)) {
                Write-Warning "Skipping entry with empty team name"
                continue
            }
           
            if (-not $teamDefinitions.ContainsKey($teamName)) {
                $teamDefinitions[$teamName] = @{
                    name = $teamName
                    description = if ($entry.description) { $entry.description } else { "" }
                    groupMembers = @()
                    userMembers = @()
                }
            }
           
            # Parse comma-delimited members
            if (-not [string]::IsNullOrEmpty($members)) {
                $memberList = $members -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
               
                if ($memberType -eq "group") {
                    $teamDefinitions[$teamName].groupMembers += $memberList
                }
                elseif ($memberType -eq "user") {
                    $teamDefinitions[$teamName].userMembers += $memberList
                }
                else {
                    Write-Warning "Unknown member type '$memberType' for team '$teamName'. Expected 'group' or 'user'."
                }
            }
        }
       
        Write-Host "##[debug]Parsed $($teamDefinitions.Count) unique team(s)"
       
        return $teamDefinitions
    }
    catch {
        Write-Error "Failed to parse project teams JSON: $_"
        throw
    }
}

#endregion

#region Main Execution

try {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Add Project Teams" -ForegroundColor Green
    Write-Host "Using Service Principal Authentication" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host "  Organization URL: $OrganizationUrl"
    Write-Host "  Project Name:     $ProjectName"
    Write-Host ""
   
    $organizationName = $OrganizationUrl.Split('/')[-1]
    # Step 0: Parse JSON Configuration
    Write-Section "Step 0: Parsing Team Configuration"

    if (-not [string]::IsNullOrWhiteSpace($projectTeamsFilePath) -and (Test-Path $projectTeamsFilePath)) {
        Write-Host "##[debug]Reading Project Teams JSON from file: $projectTeamsFilePath"
        $projectTeamsJson = Get-Content -Path $projectTeamsFilePath -Raw
    } 
    
    # Display the JSON being used for transparency
    Write-Host "##[debug]Project Teams JSON Configuration:`n$projectTeamsJson"

    $teamDefinitions = Parse-ProjectTeamsJson -JsonString $projectTeamsJson

    Write-Host "##[command]Parsed $($teamDefinitions.Count) team(s) from configuration" -ForegroundColor Green
   
    foreach ($teamName in $teamDefinitions.Keys) {
        $team = $teamDefinitions[$teamName]
        Write-Host "##[debug]Team: $teamName"
        Write-Host "##[debug]  Group Members: $($team.groupMembers.Count)"
        Write-Host "##[debug]  User Members: $($team.userMembers.Count)"
    }
   
    # Step 1: Authenticate
    Write-Section "Step 1: Authenticating with Azure AD"
   
    $script:accessToken = Get-AzureAdAccessToken -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId -MaxRetries $MaxRetries
    Initialize-Headers -AccessToken $script:accessToken
   
    Write-Host "##[command]Authentication successful" -ForegroundColor Green
   
    # Step 2: Get Project
    Write-Section "Step 2: Getting Project Information"
   
    $project = Get-ProjectByName -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
   
    Write-Host "##[command]Project found: $($project.name)" -ForegroundColor Green
    Write-Host "##[debug]Project ID: $($project.id)"
   
    # Step 3: Process Each Team
    $teamsCreated = 0
    $teamsFailed = 0
    $teamResults = @{}
   
    foreach ($teamName in $teamDefinitions.Keys) {
        try {
            $teamDef = $teamDefinitions[$teamName]
           
            Write-Section "Step 3.$($teamsCreated + $teamsFailed + 1): Processing Team '$teamName'"
           
            # Find Security Groups
            $securityGroups = @()
            $organizationUrlVssp = "https://vssps.dev.azure.com/$organizationName"
            if ($teamDef.groupMembers.Count -gt 0) {
                Write-Host "##[command]Finding Security Groups..." -ForegroundColor Cyan
                $securityGroups = Get-SecurityGroups -OrganizationUrl $organizationUrlVssp -GroupNames $teamDef.groupMembers
                Write-Host "##[command]Found $($securityGroups.Count) security group(s)" -ForegroundColor Green
            }
           
            # Find Users
            $users = @()
            if ($teamDef.userMembers.Count -gt 0) {
                Write-Host "##[command]Finding Users..." -ForegroundColor Cyan
                $users = Get-Users -OrganizationUrl $organizationUrlVssp -UserIdentifiers $teamDef.userMembers
                Write-Host "##[command]Found $($users.Count) user(s)" -ForegroundColor Green
            }
           
            # Combine all members
            $allMembers = @()
            $allMembers += $securityGroups
            $allMembers += $users
           
            if ($allMembers.Count -eq 0) {
                Write-Warning "No members found for team '$teamName'. Creating team without members."
            }
            else {
                Write-Host "##[debug]Total members to add: $($allMembers.Count)"
            }
           
            # Create team with members
            $team = New-ProjectTeam -OrganizationUrl $OrganizationUrl -ProjectId $project.id -TeamName $teamName -TeamDescription $teamDef.description -Members $allMembers
              
            $teamsCreated++
        }
        catch {
            Write-Error "Failed to process team '$teamName': $_"
            $teamResults[$teamName] = @{
                success = $false
                error = $_.Exception.Message
            }
            $teamsFailed++
        }
    }
   
   
    if ($teamsCreated -gt 0) {
        Write-Host " Team creation completed successfully" -ForegroundColor Green
    }
   
    if ($teamsFailed -gt 0) {
        Write-Warning "Some teams could not be created. Check the errors above."
        exit 1
    }
}
catch {
    Write-Error "##[error]Failed to create project teams: $_"
    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Verify Service Principal has appropriate team management permissions" -ForegroundColor White
    Write-Host "  2. Check that security groups and users exist in Azure DevOps" -ForegroundColor White
    Write-Host "  3. Verify project name is correct" -ForegroundColor White
    Write-Host "  4. Ensure JSON configuration is valid" -ForegroundColor White
    Write-Host "  5. Check that team names are unique within the project" -ForegroundColor White
    Write-Host ""
    exit 1
}

#endregion