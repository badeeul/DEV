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
    [string]$SourceProjectName,
   
    [Parameter(Mandatory=$true)]
    [string]$SourceTeamName,
   
    [Parameter(Mandatory=$true)]
    [string]$DestinationProjectName,
   
    [Parameter(Mandatory=$true)]
    [string]$DestinationTeamName,

    [Parameter(Mandatory=$false)]
    [string]$WorkItemType = "Goal",
    
    [Parameter(Mandatory=$false)]
    [string]$ParentWorkItemTitle,

    [Parameter(Mandatory=$false)]
    [string]$WorkItemTitle,

    [Parameter(Mandatory=$false)]
    [string]$RenameWorkItemTitle = "",

    [Parameter(Mandatory=$false)]
    [int]$MaxRetries = 3,
   
    [Parameter(Mandatory=$false)]
    [int]$BaseRetryDelaySeconds = 5
)

#region Global Variables

# Load required assembly for URL encoding
Add-Type -AssemblyName System.Web

$script:accessToken = $null
$script:headers = $null
$script:apiVersion = "7.1"
$script:workItemMapping = @{}  # Maps source work item IDs to destination work item IDs

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
        "Content-Type" = "application/json-patch+json"
    }
}

function Invoke-AzDoApiWithRetry {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        [int]$MaxRetries = 3
    )
   
    $attempt = 1
   
    while ($attempt -le $MaxRetries) {
        try {
            $requestHeaders = $script:headers.Clone()
            if ($ContentType) {
                $requestHeaders["Content-Type"] = $ContentType
            }
           
            $requestParams = @{
                Uri = $Uri
                Headers = $requestHeaders
                Method = $Method
            }
           
            if (-not [string]::IsNullOrEmpty($Body)) {
                $requestParams.Body = $Body
            }
           
            $response = Invoke-RestMethod @requestParams
            return $response
        }
        catch {
            if ($attempt -eq $MaxRetries) {
                throw
            }
           
            $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Host "##[warning]API call failed (attempt $attempt), retrying in $retryDelay seconds"
            Start-Sleep -Seconds $retryDelay
            $attempt++
        }
    }
}

function Get-ProjectProcess {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName
    )
   
    try {
        Write-Host "##[debug]Getting process template for project: $ProjectName"
       
        # Get project details which includes process information
        $projectUri = "$OrganizationUrl/_apis/projects/$ProjectName`?includeCapabilities=true&api-version=$script:apiVersion"
        $project = Invoke-AzDoApiWithRetry -Uri $projectUri -Method GET
       
        if ($project.capabilities -and $project.capabilities.processTemplate) {
            $processId = $project.capabilities.processTemplate.templateTypeId
            $processName = $project.capabilities.processTemplate.templateName
           
            Write-Host "##[command]Project process: $processName" -ForegroundColor Green
            Write-Host "##[debug]Process ID: $processId"
           
            return @{
                id = $processId
                name = $processName
            }
        }
        else {
            Write-Warning "Could not get process template information from project"
            return $null
        }
    }
    catch {
        Write-Warning "Could not get project process: $_"
        return $null
    }
}

function Get-WorkItemTypes {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName
    )
   
    try {
        Write-Host "##[debug]Getting work item types for project: $ProjectName"
       
        # Method 1: Try to get work item types directly from the project
        $witUri = "$OrganizationUrl/$ProjectName/_apis/wit/workitemtypes?api-version=$script:apiVersion"
        # display uri
        Write-Host "##[debug]URI: $witUri"
           
        try {
            $workItemTypes = Invoke-AzDoApiWithRetry -Uri $witUri -Method GET
           
            if ($workItemTypes.value -and $workItemTypes.value.Count -gt 0) {
                Write-Host "##[command]Found $($workItemTypes.value.Count) work item type(s) in project" -ForegroundColor Green
               
                foreach ($wit in $workItemTypes.value) {
                    Write-Host "##[debug]  - $($wit.name)"
                }
               
                return $workItemTypes.value
            }
        }
        catch {
            Write-Host "##[debug]Could not get work item types from project API: $_"
        }
       
        # Method 2: Get from process template
        Write-Host "##[debug]Attempting to get work item types from process template..."
       
        $process = Get-ProjectProcess -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
       
        if ($process -and $process.id) {
            # Get work item types from the process
            $processWitUri = "$OrganizationUrl/_apis/work/processes/$($process.id)/workitemtypes?api-version=7.1-preview.2"
           
            try {
                $processWorkItemTypes = Invoke-AzDoApiWithRetry -Uri $processWitUri -Method GET
               
                if ($processWorkItemTypes.value -and $processWorkItemTypes.value.Count -gt 0) {
                    Write-Host "##[command]Found $($processWorkItemTypes.value.Count) work item type(s) from process template" -ForegroundColor Green
                   
                    foreach ($wit in $processWorkItemTypes.value) {
                        Write-Host "##[debug]  - $($wit.name) (Ref: $($wit.referenceName))"
                    }
                   
                    return $processWorkItemTypes.value
                }
            }
            catch {
                Write-Warning "Could not get work item types from process: $_"
            }
        }
       
        # Method 3: Query for work items to infer types
        Write-Host "##[debug]Attempting to infer work item types from existing work items..."
       
        $wiqlQuery = "SELECT [System.WorkItemType] FROM WorkItems WHERE [System.TeamProject] = '$ProjectName'"
       
        $wiql = @{
            query = $wiqlQuery
        } | ConvertTo-Json
       
        try {
            $wiqlUri = "$OrganizationUrl/$ProjectName/_apis/wit/wiql?api-version=$script:apiVersion"
            $result = Invoke-AzDoApiWithRetry -Uri $wiqlUri -Method POST -Body $wiql -ContentType "application/json"
           
            if ($result.workItems -and $result.workItems.Count -gt 0) {
                # Get unique work item types from existing work items
                $types = @()
                $uniqueTypes = @{}
               
                foreach ($wi in $result.workItems | Select-Object -First 100) {
                    $details = Get-WorkItemDetails -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName -WorkItemId $wi.id
                    $typeName = $details.fields.'System.WorkItemType'
                   
                    if (-not $uniqueTypes.ContainsKey($typeName)) {
                        $uniqueTypes[$typeName] = $true
                        $types += @{ name = $typeName }
                        Write-Host "##[debug]  - $typeName (inferred from work items)"
                    }
                }
               
                if ($types.Count -gt 0) {
                    Write-Host "##[command]Inferred $($types.Count) work item type(s) from existing work items" -ForegroundColor Yellow
                    return $types
                }
            }
        }
        catch {
            Write-Warning "Could not infer work item types: $_"
        }
       
        Write-Warning "No work item types found using any method"
        return @()
    }
    catch {
        Write-Warning "Could not get work item types: $_"
        return @()
    }
}

function Test-WorkItemTypeExists {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [string]$WorkItemType
    )
   
    try {
        $workItemTypes = Get-WorkItemTypes -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName
       
        if ($workItemTypes.Count -eq 0) {
            Write-Warning "Could not retrieve work item types for validation"
            Write-Host "##[debug]Proceeding without validation (work item type may or may not exist)"
            return $true  # Assume it exists if we can't validate
        }
       
        $exists = $workItemTypes | Where-Object { $_.name -eq $WorkItemType }
       
        if ($exists) {
            Write-Host "##[command]Work item type '$WorkItemType' exists in destination project" -ForegroundColor Green
            return $true
        }
        else {
            Write-Warning "Work item type '$WorkItemType' does NOT exist in destination project"
            Write-Host "##[debug]Available work item types: $($workItemTypes.name -join ', ')"
            return $false
        }
    }
    catch {
        Write-Warning "Could not verify work item type: $_"
        return $false
    }
}

function Get-WorkItemDetails {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [int]$WorkItemId
    )
   
    try {
        $wiUri = "$OrganizationUrl/$ProjectName/_apis/wit/workitems/$WorkItemId`?`$expand=all&api-version=$script:apiVersion"
        Write-Host "##[debug]Getting details for work item $WorkItemId..."
        # display uri
        Write-Host "##[debug]URI: $wiUri"

        $workItem = Invoke-AzDoApiWithRetry -Uri $wiUri -Method GET

        # Display Work item for debugging
        Write-Host "##[debug]Work Item Details: $(ConvertTo-Json $workItem -Depth 5)"

        return $workItem
    }
    catch {
        Write-Error "Failed to get work item $WorkItemId : $_"
        throw
    }
}

function Get-WorkItemChildren {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [int]$ParentWorkItemId
    )
   
    try {
        Write-Host "##[debug]Getting children for work item $ParentWorkItemId..."
       
        # Get work item with relations
        $wiUri = "$OrganizationUrl/$ProjectName/_apis/wit/workitems/$ParentWorkItemId`?`$expand=relations&api-version=$script:apiVersion"
        Write-Host "##[debug]URI: $wiUri"
        $workItem = Invoke-AzDoApiWithRetry -Uri $wiUri -Method GET
       
        # Display Work item for debugging
        Write-Host "##[debug]Work Item Details: $(ConvertTo-Json $workItem -Depth 5)"

        $children = @()
       
        if ($workItem.relations) {
            foreach ($relation in $workItem.relations) {
                if ($relation.rel -eq "System.LinkTypes.Hierarchy-Forward") {
                    # Extract work item ID from URL
                    $childId = [int]($relation.url -split '/')[-1]
                    $children += $childId
                }
            }
        }
       
        Write-Host "##[debug]Found $($children.Count) children"
        return $children
    }
    catch {
        Write-Warning "Could not get children for work item $ParentWorkItemId : $_"
        return @()
    }
}

function Get-TeamAreaPath {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [string]$TeamName
    )
   
    try {
        Write-Host "##[debug]Getting area path for team: $TeamName"
       
        # Get team settings
        $teamUri = "$OrganizationUrl/_apis/projects/$ProjectName/teams/$TeamName`?api-version=$script:apiVersion"
       
        Write-Host "##[debug]Team URI: $teamUri"
       
        $team = Invoke-AzDoApiWithRetry -Uri $teamUri -Method GET
       
        Write-Host "##[debug]Team ID: $($team.id)"
        Write-Host "##[debug]Team Name: $($team.name)"
       
        # Get team field values (area paths)
        $teamFieldUri = "$OrganizationUrl/$ProjectName/$($team.id)/_apis/work/teamsettings/teamfieldvalues?api-version=$script:apiVersion"
       
        Write-Host "##[debug]Team field URI: $teamFieldUri"
       
        try {
            $teamFields = Invoke-AzDoApiWithRetry -Uri $teamFieldUri -Method GET
           
            if ($teamFields.defaultValue) {
                Write-Host "##[command]Team default area path: $($teamFields.defaultValue)" -ForegroundColor Green
                return $teamFields.defaultValue
            }
        }
        catch {
            Write-Warning "Could not get team field values: $_"
        }
       
        # Fallback: use project name as area path
        Write-Host "##[debug]Using project name as area path: $ProjectName"
        return $ProjectName
    }
    catch {
        Write-Warning "Could not get team area path: $_"
        Write-Host "##[debug]Falling back to project name: $ProjectName"
        return $ProjectName
    }
}

function Find-WorkItemsByTitle {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [string]$TeamName,
        [string]$TitlePattern,
        [string]$WorkItemType,
        [int]$WorkItemId
    )
   
    try {
        Write-Host "##[debug]Searching for work items with title pattern: $TitlePattern and type: $WorkItemType"
       
        # Get team's area path to scope the query
        $teamAreaPath = Get-TeamAreaPath -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName -TeamName $TeamName
       
        Write-Host "##[debug]Filtering by team area path: $teamAreaPath"
       
        # Build simple WIQL query - get all work items of the type in the team area
        # We'll filter by title in PowerShell
        $wiqlQuery = @"
SELECT [System.Id], [System.Title], [System.WorkItemType], [System.AreaPath]
FROM WorkItems
WHERE [System.TeamProject] = '$ProjectName'
  AND [System.AreaPath] UNDER '$teamAreaPath'
  AND [System.WorkItemType] = '$WorkItemType'
  AND [System.Id] >= $WorkItemId
ORDER BY [System.Id]
"@
       
        Write-Host "##[debug]WIQL Query: $wiqlQuery"
       
        $wiql = @{
            query = $wiqlQuery
        } | ConvertTo-Json
       
        Write-Host "##[debug]WIQL JSON: $wiql"
       
        $wiqlUri = "$OrganizationUrl/$ProjectName/_apis/wit/wiql?api-version=$script:apiVersion"
       
        Write-Host "##[debug]WIQL URI: $wiqlUri"
       
        $result = Invoke-AzDoApiWithRetry -Uri $wiqlUri -Method POST -Body $wiql -ContentType "application/json"
       
        $workItems = @()
       
        if ($result.workItems -and $result.workItems.Count -gt 0) {
            Write-Host "##[debug]Query returned $($result.workItems.Count) work item(s) of type '$WorkItemType'"
           
            # Filter by title pattern in PowerShell
            Write-Host "##[debug]Filtering by title pattern: $TitlePattern"

            foreach ($wi in $result.workItems) {
                # Get work item details to check title
                try {
                    $workItemDetails = Get-WorkItemDetails -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName -WorkItemId $wi.id
                    $title = $workItemDetails.fields.'System.Title'

                    Write-Host "##[debug]  Checking: $title"

                    if ($title -like $TitlePattern) {
                        Write-Host "##[debug]     Match found!" -ForegroundColor Green
                        $workItems += $wi.id
                    }
                    else {
                        Write-Host "##[debug]     No match"
                    }
                }
                catch {
                    Write-Warning "Could not get details for work item $($wi.id): $_"
                }
            }
        }
        else {
            Write-Host "##[debug]No work items found of type '$WorkItemType' in team area path '$teamAreaPath'"
        }

        Write-Host "##[command]Found $($workItems.Count) work item(s) matching pattern '$TitlePattern' in team '$TeamName'" -ForegroundColor Green
        
        return $workItems
    }
    catch {
        Write-Error "Failed to find work items: $_"
        Write-Host "##[debug]Error details: $($_.Exception.Message)"
        if ($_.Exception.Response) {
            Write-Host "##[debug]Response: $($_.Exception.Response)"
        }
        throw
    }
}

function Find-ParentWorkItemsByTitle {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [string]$TeamName,
        [string]$ParentTitlePattern,
        [string]$WorkItemType = "Goal"
    )
   
    try {
        Write-Host "##[debug]Searching for work items with title pattern: $ParentTitlePattern and type: $WorkItemType"
       
        # Get team's area path to scope the query
        $teamAreaPath = Get-TeamAreaPath -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName -TeamName $TeamName
       
        Write-Host "##[debug]Filtering by team area path: $teamAreaPath"
       
        # Build simple WIQL query - get all work items of the type in the team area
        # We'll filter by title in PowerShell
        $wiqlQuery = @"
SELECT [System.Id], [System.Title], [System.WorkItemType], [System.AreaPath]
FROM WorkItems
WHERE [System.TeamProject] = '$ProjectName'
  AND [System.AreaPath] UNDER '$teamAreaPath'
  AND [System.WorkItemType] = 'GOAL'
ORDER BY [System.Id]
"@
       
        Write-Host "##[debug]WIQL Query: $wiqlQuery"
       
        $wiql = @{
            query = $wiqlQuery
        } | ConvertTo-Json
       
        Write-Host "##[debug]WIQL JSON: $wiql"
       
        $wiqlUri = "$OrganizationUrl/$ProjectName/_apis/wit/wiql?api-version=$script:apiVersion"
       
        Write-Host "##[debug]WIQL URI: $wiqlUri"
       
        $result = Invoke-AzDoApiWithRetry -Uri $wiqlUri -Method POST -Body $wiql -ContentType "application/json"
       
        $workItems = @()
       
        if ($result.workItems -and $result.workItems.Count -gt 0) {
            Write-Host "##[debug]Query returned $($result.workItems.Count) work item(s) of type '$WorkItemType'"
           
            # Filter by title pattern in PowerShell
            Write-Host "##[debug]Filtering by title pattern: $ParentTitlePattern"

            foreach ($wi in $result.workItems) {
                # Get work item details to check title
                try {
                    $workItemDetails = Get-WorkItemDetails -OrganizationUrl $OrganizationUrl -ProjectName $ProjectName -WorkItemId $wi.id
                    $title = $workItemDetails.fields.'System.Title'

                    Write-Host "##[debug]  Checking: $title"

                    if ($title -like $ParentTitlePattern) {
                        Write-Host "##[debug]     Match found!" -ForegroundColor Green
                        return $wi.id
                    }
                    else {
                        Write-Host "##[debug]     No match"
                    }
                }
                catch {
                    Write-Warning "Could not get details for work item $($wi.id): $_"
                }
            }
        }
        else {
            Write-Host "##[debug]No work items found of type '$WorkItemType' in team area path '$teamAreaPath'"
        }

        Write-Host "##[command]Found $($workItems.Count) work item(s) matching pattern '$ParentTitlePattern' in team '$TeamName'" -ForegroundColor Green
        # return work item ID
        return $null
    }
    catch {
        Write-Error "Failed to find work items: $_"
        Write-Host "##[debug]Error details: $($_.Exception.Message)"
        if ($_.Exception.Response) {
            Write-Host "##[debug]Response: $($_.Exception.Response)"
        }
        throw
    }
}

function Get-TeamBacklogs {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [string]$TeamName
    )
   
    try {
        Write-Host "##[debug]Getting backlogs for team: $TeamName"
       
        # Get all backlogs for the team
        $backlogsUri = "$OrganizationUrl/$ProjectName/$TeamName/_apis/work/backlogs?api-version=$script:apiVersion"
        $backlogs = Invoke-AzDoApiWithRetry -Uri $backlogsUri -Method GET
       
        Write-Host "##[debug]Found $($backlogs.count) backlog level(s)"
       
        foreach ($backlog in $backlogs.value) {
            Write-Host "##[debug]  Backlog: $($backlog.name) (ID: $($backlog.id), Rank: $($backlog.rank))"
        }
       
        return $backlogs.value
    }
    catch {
        Write-Warning "Could not get team backlogs: $_"
        return @()
    }
}

function Get-BacklogWorkItems {
    param(
        [string]$OrganizationUrl,
        [string]$ProjectName,
        [string]$TeamName,
        [string]$BacklogId
    )
   
    try {
        Write-Host "##[debug]Getting work items for backlog: $BacklogId"
       
        # Get work items in the backlog
        $workItemsUri = "$OrganizationUrl/$ProjectName/$TeamName/_apis/work/backlogs/$BacklogId/workItems?api-version=$script:apiVersion"
        $result = Invoke-AzDoApiWithRetry -Uri $workItemsUri -Method GET
       
        $workItems = @()
       
        if ($result.workItems) {
            foreach ($wi in $result.workItems) {
                if ($wi.target -and $wi.target.id) {
                    $workItems += $wi.target.id
                }
            }
        }
       
        Write-Host "##[debug]Found $($workItems.Count) work item(s) in backlog"
        return $workItems
    }
    catch {
        Write-Warning "Could not get backlog work items: $_"
        return @()
    }
}

function Copy-WorkItem {
    param(
        [string]$OrganizationUrl,
        [string]$SourceProjectName,
        [string]$DestinationProjectName,
        [string]$DestinationTeamAreaPath,
        [int]$SourceWorkItemId,
        [int]$ParentDestinationWorkItemId = $null,
        [string]$RenameWorkItemTitle = "",
        [int]$Level = 0
    )
   
    try {
        # Get source work item details
        $sourceWorkItem = Get-WorkItemDetails -OrganizationUrl $OrganizationUrl -ProjectName $SourceProjectName -WorkItemId $SourceWorkItemId
       
        $workItemType = $sourceWorkItem.fields.'System.WorkItemType'
       
        Write-Host "##[command]Copying work item: $($sourceWorkItem.fields.'System.Title')" -ForegroundColor Cyan
        Write-Host "##[debug]  Source ID: $SourceWorkItemId"
        Write-Host "##[debug]  Type: $workItemType"
       
        # Test-WorkItemTypeExists -OrganizationUrl $OrganizationUrl -ProjectName $SourceProjectName -WorkItemType $workItemType

        # Check if work item type exists in destination project
        $typeExists = Test-WorkItemTypeExists -OrganizationUrl $OrganizationUrl -ProjectName $DestinationProjectName -WorkItemType $workItemType
       
        if (-not $typeExists) {
            throw "Work item type '$workItemType' does not exist in destination project '$DestinationProjectName'. Please ensure the process template includes this work item type."
        }

        # Build JSON Patch document for creating work item
        $patchDocument = @()
       
        # Add core fields
        $fieldsToCopy = @(
            "System.Title",
            "System.Description",
            "System.State",
            "System.Priority",
            "System.Effort",
            "System.BusinessValue",
            "System.ValueArea",
            "System.Tags",
            "Microsoft.VSTS.Common.BusinessValue",
            "Microsoft.VSTS.Common.ValueArea",
            "Microsoft.VSTS.Scheduling.Effort",
            "Microsoft.VSTS.Scheduling.StoryPoints",
            "Microsoft.VSTS.Scheduling.OriginalEstimate",
            "Microsoft.VSTS.Scheduling.RemainingWork",
            "Microsoft.VSTS.Scheduling.CompletedWork",
            "System.AreaPath",
            "System.TeamProject",            
            "Microsoft.VSTS.Scheduling.TargetDate",
            "Microsoft.VSTS.Scheduling.StartDate",
            "Microsoft.VSTS.Scheduling.FinishDate",
            "System.IterationPath",
            "System.WorkItemType"            
        )
        $encodedProjectname = [Uri]::EscapeDataString($DestinationProjectName)
        foreach ($fieldName in $fieldsToCopy) {
            if ($sourceWorkItem.fields.PSObject.Properties.Name -contains $fieldName) {
                $fieldValue = $sourceWorkItem.fields.$fieldName
               
                if ($null -ne $fieldValue) {
                    # Adjust AreaPath and IterationPath for destination project
                    if ($fieldName -eq "System.IterationPath" -or $fieldName -eq "System.AreaPath" -or $fieldName -eq "System.TeamProject") {
                        $fieldValue = $DestinationProjectName
                    }
                    
                    # if Level == 0 and RenameWorkItemTitle is set, rename the work item
                    if ($Level -eq 0 -and -not [string]::IsNullOrEmpty($RenameWorkItemTitle) -and $RenameWorkItemTitle -ne " ") {
                        if ($fieldName -eq "System.Title") {
                            $fieldValue = $RenameWorkItemTitle
                        }
                    }

                    $patchDocument += @{
                        op = "add"
                        path = "/fields/$fieldName"
                        value = $fieldValue
                    }
                }
            }
        }
       
        # Copy ALL custom fields from source (to handle Custom.Current and other custom fields)
        Write-Host "##[debug]Checking for custom fields..."
        foreach ($field in $sourceWorkItem.fields.PSObject.Properties) {
            $fieldName = $field.Name
           
            # Skip if already in the standard fields list
            if ($fieldsToCopy -contains $fieldName) {
                continue
            }
           
            # Skip system fields that shouldn't be copied
            if ($fieldName -match "^System\.(Id|Rev|RevisedDate|ChangedDate|ChangedBy|CreatedDate|CreatedBy|AuthorizedDate|PersonId|Watermark|BoardColumn|BoardColumnDone|BoardLane)$") {
                continue
            }
           
            # Copy custom fields (Custom.* or other non-system fields)
            if ($fieldName -like "Custom.*" -or ($fieldName -like "Microsoft.VSTS.*" -and $fieldsToCopy -notcontains $fieldName)) {
                $fieldValue = $field.Value
               
                if ($null -ne $fieldValue -and $fieldValue -ne "") {
                    Write-Host "##[debug]  Copying custom field: $fieldName = $fieldValue"
                   
                    $patchDocument += @{
                        op = "add"
                        path = "/fields/$fieldName"
                        value = $fieldValue
                    }
                }
            }
        }
       
        # Set AreaPath to destination team's area path
        # $patchDocument += @{
        #     op = "add"
        #     path = "/fields/System.AreaPath"
        #     value = $DestinationTeamAreaPath
        # }
       
        # Add parent link if provided
        if ($null -ne $ParentDestinationWorkItemId -and $ParentDestinationWorkItemId -gt 0) {
            $patchDocument += @{
                op = "add"
                path = "/relations/-"
                value = @{
                    rel = "System.LinkTypes.Hierarchy-Reverse"
                    url = "$OrganizationUrl/$encodedProjectname/_apis/wit/workitems/$ParentDestinationWorkItemId"
                }
            }
        }
       
        $patchJson = $patchDocument | ConvertTo-Json -Depth 10
       
        # Create work item in destination
        # encode work item type for URL so that spaces are %20 etc.
        $encodedWorkItemType = [Uri]::EscapeDataString($workItemType)

        $createUri = "$OrganizationUrl/$encodedProjectname/_apis/wit/workitems/`$${encodedWorkItemType}?api-version=$script:apiVersion"

        Write-Host "##[debug]Creating work item in destination project..."
        Write-Host "##[debug]  Work Item Type: $workItemType"
        Write-Host "##[debug]  Encoded Type: $encodedWorkItemType"
        Write-Host "##[debug]  URI: $createUri"
        Write-Host "##[debug]  JSON: $patchJson"

        $newWorkItem = Invoke-AzDoApiWithRetry -Uri $createUri -Method POST -Body $patchJson -ContentType "application/json-patch+json"
       
        Write-Host "##[command]Successfully created work item" -ForegroundColor Green
        Write-Host "##[debug]  Destination ID: $($newWorkItem.id)"
        Write-Host "##[debug]  Title: $($newWorkItem.fields.'System.Title')"
        Write-Host "##[debug]  Area Path: $($newWorkItem.fields.'System.AreaPath')"

        # Store mapping
        $script:workItemMapping[$SourceWorkItemId] = $newWorkItem.id
       
        return $newWorkItem
    }
    catch {
        # Parse validation errors if available
        $errorMessage = $_.Exception.Message
       
        if ($errorMessage -match "TF401320.*Required.*InvalidEmpty") {
            Write-Host "##[error]Required field validation error!" -ForegroundColor Red
            Write-Host "##[error]The destination project has required fields that are missing from the source work item." -ForegroundColor Red
           
            # Try to parse JSON error if available
            try {
                if ($_.ErrorDetails.Message) {
                    $errorJson = $_.ErrorDetails.Message | ConvertFrom-Json
                   
                    if ($errorJson.customProperties.RuleValidationErrors) {
                        Write-Host "##[error]Required fields that are missing:" -ForegroundColor Red
                        foreach ($validationError in $errorJson.customProperties.RuleValidationErrors) {
                            Write-Host "##[error]  - $($validationError.fieldReferenceName): $($validationError.errorMessage)" -ForegroundColor Red
                        }
                    }
                }
            }
            catch {
                # Ignore JSON parsing errors
            }
           
            Write-Host "##[debug]Source work item fields:" -ForegroundColor Yellow
            $sourceWorkItem.fields.PSObject.Properties | ForEach-Object {
                Write-Host "##[debug]  $($_.Name) = $($_.Value)"
            }
        }
       
        Write-Error "Failed to copy work item $SourceWorkItemId : $_"
        throw
    }
}

function Copy-WorkItemHierarchy {
    param(
        [string]$OrganizationUrl,
        [string]$SourceProjectName,
        [string]$DestinationProjectName,
        [string]$DestinationTeamAreaPath,
        [int]$SourceWorkItemId,
        [int]$ParentDestinationWorkItemId = $null,
        [string]$RenameWorkItemTitle = "",
        [int]$Level = 0
    )
   
    try {
        $indent = "  " * $Level
       
        # Copy current work item
        $newWorkItem = Copy-WorkItem `
            -OrganizationUrl $OrganizationUrl `
            -SourceProjectName $SourceProjectName `
            -DestinationProjectName $DestinationProjectName `
            -DestinationTeamAreaPath $DestinationTeamAreaPath `
            -SourceWorkItemId $SourceWorkItemId `
            -ParentDestinationWorkItemId $ParentDestinationWorkItemId `
            -RenameWorkItemTitle $RenameWorkItemTitle `
            -Level $Level

        # if work item exists exit
        if ($null -eq $newWorkItem) {
            Write-Host "$indent##[debug]Work item $SourceWorkItemId already exists. Skipping children."
            return $null
        }

        # Get children of source work item
        $children = Get-WorkItemChildren `
            -OrganizationUrl $OrganizationUrl `
            -ProjectName $SourceProjectName `
            -ParentWorkItemId $SourceWorkItemId
       
        if ($children.Count -gt 0) {
            Write-Host "$indent##[debug]Processing $($children.Count) children..."
           
            foreach ($childId in $children) {
                # Recursively copy children
                Copy-WorkItemHierarchy `
                    -OrganizationUrl $OrganizationUrl `
                    -SourceProjectName $SourceProjectName `
                    -DestinationProjectName $DestinationProjectName `
                    -DestinationTeamAreaPath $DestinationTeamAreaPath `
                    -SourceWorkItemId $childId `
                    -ParentDestinationWorkItemId $newWorkItem.id `
                    -Level ($Level + 1)
            }
        }
       
        return $newWorkItem
    }
    catch {
        Write-Error "Failed to copy work item hierarchy for $SourceWorkItemId : $_"
        throw
    }
}

#endregion

#region Main Execution

try {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Copy Project Backlogs (Work Item Hierarchy)" -ForegroundColor Green
    Write-Host "Using Service Principal Authentication" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
   
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host "  Organization URL:         $OrganizationUrl"
    Write-Host "  Source Project:           $SourceProjectName"
    Write-Host "  Source Team:              $SourceTeamName"
    Write-Host "  Destination Project:      $DestinationProjectName"
    Write-Host "  Destination Team:         $DestinationTeamName"
    Write-Host "  Parent Work Item Pattern: $ParentWorkItemTitle"
    Write-Host "  Work Item Type:           $WorkItemType"
    Write-Host "  Backlog Work Item Title:  $WorkItemTitle"
    Write-Host ""
   
    # Step 0: Authenticate
    Write-Section "Step 0: Authenticating with Azure AD"
   
    $script:accessToken = Get-AzureAdAccessToken -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId -MaxRetries $MaxRetries
    Initialize-Headers -AccessToken $script:accessToken
   
    Write-Host "##[command]Authentication successful" -ForegroundColor Green
   
    # Step 1: Get Source Team Information
    Write-Section "Step 1: Getting Source Team Information"
   
    $sourceTeamAreaPath = Get-TeamAreaPath `
        -OrganizationUrl $OrganizationUrl `
        -ProjectName $SourceProjectName `
        -TeamName $SourceTeamName
   
    Write-Host "##[command]Source team area path: $sourceTeamAreaPath" -ForegroundColor Green
   
    # Optional: Get backlogs for the source team
    $sourceBacklogs = Get-TeamBacklogs `
        -OrganizationUrl $OrganizationUrl `
        -ProjectName $SourceProjectName `
        -TeamName $SourceTeamName
   
    Write-Host "##[command]Source team has $($sourceBacklogs.Count) backlog level(s)" -ForegroundColor Green
   
    # Step 2: Find Parent Work Items in Source Team
    Write-Section "Step 2: Finding Parent Work Items in Source Team"
   
    $lastProcessedWorkItemId = Find-ParentWorkItemsByTitle `
        -OrganizationUrl $OrganizationUrl `
        -ProjectName $SourceProjectName `
        -TeamName $SourceTeamName `
        -ParentTitlePattern $ParentWorkItemTitle 

    # Display last processed work item ID
    Write-Host "##[command]Last processed work item ID: $lastProcessedWorkItemId" -ForegroundColor Green

    $sourceWorkItemIds = Find-WorkItemsByTitle `
        -OrganizationUrl $OrganizationUrl `
        -ProjectName $SourceProjectName `
        -TeamName $SourceTeamName `
        -TitlePattern $WorkItemTitle `
        -WorkItemType $WorkItemType `
        -WorkItemId $lastProcessedWorkItemId


    if (-not $sourceWorkItemIds) {
        throw "No work items found matching pattern: $WorkItemTitle in team: $SourceTeamName"
    }
   
    # Find work item by title pattern for destination project, if exists skip copying
    # $destinationWorkItemIds = Find-WorkItemsByTitle `
    #     -OrganizationUrl $OrganizationUrl `
    #     -ProjectName $DestinationProjectName `
    #     -TeamName $DestinationTeamName `
    #     -TitlePattern $ParentWorkItemTitle `
    #     -WorkItemType $WorkItemType
    
    # if ($destinationWorkItemIds.Count -gt 0) {
    #     Write-Host "##[command]Found $($destinationWorkItemIds.Count) matching work item(s) in destination project. Skipping copy." -ForegroundColor Yellow
    #     exit 0
    # }

    Write-Host "##[command]Found $($sourceWorkItemIds.Count) parent work item(s) to copy" -ForegroundColor Green
    # Step 3: Verify Destination Project Has Required Work Item Types
    Write-Section "Step 3: Verifying Destination Project Work Item Types"
   
    $destinationWorkItemTypes = Get-WorkItemTypes -OrganizationUrl $OrganizationUrl -ProjectName $DestinationProjectName
   
    Write-Host "##[command]Destination project has $($destinationWorkItemTypes.Count) work item type(s)" -ForegroundColor Green
   
    # Check if work item type exists
    $workItemTypeExists = $destinationWorkItemTypes | Where-Object { $_.name -eq $WorkItemType }

    if (-not $workItemTypeExists) {
        Write-Warning "Work item type '$WorkItemType' not found in destination project"
        Write-Warning "This may cause issues when copying work items"
        Write-Host "##[debug]Available types: $($destinationWorkItemTypes.name -join ', ')"
    }
   
    # Step 4: Get Destination Team Information
    Write-Section "Step 4: Getting Destination Team Information"
   
    $destinationTeamAreaPath = Get-TeamAreaPath `
        -OrganizationUrl $OrganizationUrl `
        -ProjectName $DestinationProjectName `
        -TeamName $DestinationTeamName
   
    Write-Host "##[command]Destination team area path: $destinationTeamAreaPath" -ForegroundColor Green
   
    # Step 5: Copy Work Item Hierarchies
    Write-Section "Step 5: Copying Work Item Hierarchies"
   
    $copiedCount = 0
    $failedCount = 0
    $copyResults = @{}
   
    foreach ($sourceWorkItemId in $sourceWorkItemIds) {
        try {
            Write-Host "`n--- Processing Work Item $sourceWorkItemId ---" -ForegroundColor Yellow
           
            $result = Copy-WorkItemHierarchy `
                -OrganizationUrl $OrganizationUrl `
                -SourceProjectName $SourceProjectName `
                -DestinationProjectName $DestinationProjectName `
                -DestinationTeamAreaPath $destinationTeamAreaPath `
                -SourceWorkItemId $sourceWorkItemId `
                -ParentDestinationWorkItemId $null `
                -RenameWorkItemTitle $RenameWorkItemTitle `
                -Level 0
           
            if ($result -eq $null) {
                Write-Host "##[debug]Work item $sourceWorkItemId already exists in destination. Skipping." -ForegroundColor Yellow
               
                $copyResults[$sourceWorkItemId] = @{
                    status = "skipped"
                    message = "Work item already exists in destination"
                }
               
                continue
            }
            $copyResults[$sourceWorkItemId] = @{
                status = "success"
                newWorkItemId = $result.id
                title = $result.fields.'System.Title'
            }
           
            $copiedCount++
           
            Write-Host "##[command] Successfully copied work item hierarchy" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to copy work item hierarchy for $sourceWorkItemId : $_"
           
            $copyResults[$sourceWorkItemId] = @{
                status = "failed"
                error = $_.Exception.Message
            }
           
            $failedCount++
        }
    }
   
    # Step 6: Summary
    Write-Section "Step 6: Copy Summary"
   
    Write-Host "Source Project: $SourceProjectName" -ForegroundColor Cyan
    Write-Host "Destination Project: $DestinationProjectName" -ForegroundColor Cyan
    Write-Host "Total Work Items Processed: $($script:workItemMapping.Count)" -ForegroundColor Cyan
    Write-Host "Parent Work Items Copied: $copiedCount" -ForegroundColor Green
    Write-Host "Parent Work Items Failed: $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "Green" })
    Write-Host ""
   
    Write-Host "Work Item Mapping:" -ForegroundColor Cyan
    foreach ($sourceId in $copyResults.Keys) {
        $result = $copyResults[$sourceId]
       
        if ($result.status -eq "success") {
            Write-Host "      Source: $sourceId - Destination: $($result.newWorkItemId)" -ForegroundColor Green
            Write-Host "      Title: $($result.title)" -ForegroundColor White
        }
        else {
            Write-Host "     Source: $sourceId - Failed" -ForegroundColor Red
            Write-Host "     Error: $($result.error)" -ForegroundColor Red
        }
    }
   
    Write-Host ""
    Write-Host "Detailed Mapping (All Work Items):" -ForegroundColor Cyan
    Write-Host "Total mapped work items: $($script:workItemMapping.Count)" -ForegroundColor White
   
    if ($failedCount -eq 0) {
        Write-Host "`n All work item hierarchies copied successfully" -ForegroundColor Green
        Write-Host ""
        Write-Host "View copied work items in destination project:" -ForegroundColor Cyan
        Write-Host "  $OrganizationUrl/$DestinationProjectName/_workitems" -ForegroundColor Yellow
    }
    else {
        Write-Warning "Some work item hierarchies could not be copied. Check the errors above."
        exit 1
    }
}
catch {
    Write-Error "##[error]Failed to copy project backlogs: $_"
    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Verify Service Principal has work item read permissions on source project" -ForegroundColor White
    Write-Host "  2. Verify Service Principal has work item write permissions on destination project" -ForegroundColor White
    Write-Host "  3. Check that work item types exist in destination project" -ForegroundColor White
    Write-Host "  4. Verify area paths and iteration paths exist in destination project" -ForegroundColor White
    Write-Host "  5. Check parent work item title pattern is correct" -ForegroundColor White
    Write-Host ""
    exit 1
}

#endregion