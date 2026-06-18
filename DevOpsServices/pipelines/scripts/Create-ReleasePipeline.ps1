param (
    [Parameter(Mandatory=$true)]
    [string]$Organization,
   
    [Parameter(Mandatory=$true)]
    [string]$Project,
   
    [Parameter(Mandatory=$true)]
    [string]$PipelineName,
   
    [Parameter(Mandatory=$true)]
    [string]$ReleaseVersion,
   
    [Parameter(Mandatory=$true)]
    [string]$RepositoryName,

    [Parameter(Mandatory=$true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory=$true)]
    [string]$VariableGroupName,  
   
    [Parameter(Mandatory=$false)]
    [string]$YamlPath = "DevOpsServices/pipelines/infrastructure/azure-pipelines.yml"

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

function Format-GitUrl {
    param ([string]$value)
    return $value.Replace(' ', '%20')
}

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
    $encodedPipelineName = Format-GitUrl -value $PipelineName
   
    $url = "https://dev.azure.com/$Organization/$encodedProject/_apis/pipelines?api-version=7.1-preview.1"
    Write-Host "##[debug]Checking for existing pipelines: $url"
   
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
       
        # Filter pipelines by name
        $pipeline = $response.value | Where-Object { $_.name -eq $PipelineName }
       
        if ($pipeline) {
            Write-Host "##[debug]Found existing pipeline: $($pipeline.id)"
            return $pipeline
        }
       
        Write-Host "##[debug]Pipeline '$PipelineName' not found"
        return $null
    }
    catch {
        Write-Error "Failed to get pipeline: $_"
        throw
    }
}

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
    Write-Host "##[debug]Getting repository details: $url"
   
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        Write-Host "##[debug]Found repository: $($response.id)"
        return $response
    }
    catch {
        Write-Error "Failed to get repository details: $_"
        throw
    }
}

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
                "+$BranchName"
            )
        }
    }
   
    $url = "https://dev.azure.com/$Organization/$encodedProject/_apis/pipelines?api-version=7.1-preview.1"
    Write-Host "##[debug]Creating pipeline: $url"
    Write-Host "##[debug]Pipeline configuration: $($body | ConvertTo-Json -Depth 10)"
   
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 10)
        Write-Host "##[debug]Created pipeline: $($response.id)"
        return $response
    }
    catch {
        Write-Error "Failed to create pipeline: $_" 
        throw
    }
}

function Set-VariableGroupPipelinePermissions {
    param (
        [string]$Token,
        [string]$Organization,
        [string]$Project,
        [string]$VariableGroupName,
        [string]$PipelineId
    )
   
    $headers = @{
        'Authorization' = "Basic $Token"
        'Content-Type' = 'application/json'
    }
   
    $encodedProject = Format-GitUrl -value $Project
    # Step 1: Get the project ID
    $projectUrl = "https://dev.azure.com/$Organization/_apis/projects/$encodedProject`?api-version=7.1-preview.1"
    Write-Host "##[debug]Getting project details: $projectUrl"
   
    try {
        $projectDetails = Invoke-RestMethod -Uri $projectUrl -Headers $headers -Method Get
        $projectId = $projectDetails.id
        Write-Host "##[debug]Found project ID: $projectId"
    }
    catch {
        Write-Error "Failed to get project details: $_"
        throw
    }
   
    # Step 2: Get the variable group ID
    $encodedVarGroupName = Format-GitUrl -value $VariableGroupName
   
    $varGroupUrl = "https://dev.azure.com/$Organization/$encodedProject/_apis/distributedtask/variablegroups?groupName=$encodedVarGroupName&api-version=7.1-preview.1"
    Write-Host "##[debug]Getting variable group: $varGroupUrl"
   
    $varGroupResponse = Invoke-RestMethod -Uri $varGroupUrl -Headers $headers -Method Get
   
    if ($varGroupResponse.count -eq 0 -or $varGroupResponse.value.Count -eq 0) {
        Write-Error "Variable group '$VariableGroupName' not found"
        return
    }
   
    $varGroupId = $varGroupResponse.value[0].id
    Write-Host "##[debug]Found variable group: $varGroupId"
   
    # Step 3: Update the variable group to allow the pipeline
    $updateUrl = "https://dev.azure.com/$Organization/$encodedProject/_apis/distributedtask/variablegroups/$varGroupId`?api-version=7.1-preview.1"
   
    # Get current variable group details
    $variableGroup = $varGroupResponse.value[0]
   
    # Add or update pipeline permissions
    if (-not $variableGroup.PSObject.Properties.Name.Contains('variableGroupProjectReferences')) {
        $variableGroup | Add-Member -MemberType NoteProperty -Name 'variableGroupProjectReferences' -Value @()
    }
   
    if ($variableGroup.variableGroupProjectReferences.Count -eq 0) {
        $variableGroup.variableGroupProjectReferences = @(
            @{
                projectReference = @{
                    id = $projectId
                    name = $Project
                }
                name = $VariableGroupName
                definitionReference = @{
                    pipeline = @{
                        authorized = $true
                        id = $PipelineId
                        name = $null
                    }
                }
            }
        )
    } else {
        # Check if pipeline permissions already exist
        $projectRef = $variableGroup.variableGroupProjectReferences[0]
       
        # Ensure projectReference has correct ID
        if (-not $projectRef.projectReference -or -not $projectRef.projectReference.id) {
            $projectRef.projectReference = @{
                id = $projectId
                name = $Project
            }
        }
       
        if (-not $projectRef.PSObject.Properties.Name.Contains('definitionReference')) {
            $projectRef | Add-Member -MemberType NoteProperty -Name 'definitionReference' -Value @{
                pipeline = @{
                    authorized = $true
                    id = $PipelineId
                    name = $null
                }
            }
        }
        elseif (-not $projectRef.definitionReference.PSObject.Properties.Name.Contains('pipeline')) {
            $projectRef.definitionReference | Add-Member -MemberType NoteProperty -Name 'pipeline' -Value @{
                authorized = $true
                id = $PipelineId
                name = $null
            }
        }
        else {
            # Update existing pipeline permissions
            $projectRef.definitionReference.pipeline = @{
                authorized = $true
                id = $PipelineId
                name = $null
            }
        }
       
        # Update the projectRef back to the variableGroup object
        $variableGroup.variableGroupProjectReferences[0] = $projectRef
    }
   
    Write-Host "##[debug]Updating variable group with pipeline permissions..."
    Write-Host "##[debug]Request body: $($variableGroup | ConvertTo-Json -Depth 10)"
   
    try {
        $updateResponse = Invoke-RestMethod -Uri $updateUrl -Headers $headers -Method Put -Body ($variableGroup | ConvertTo-Json -Depth 10)
        Write-Host "##[debug]Successfully updated variable group permissions for pipeline: $PipelineId"
        return $updateResponse
    }
    catch {
        Write-Error "Failed to update variable group permissions: $_"
        throw
    }
}


try {
    
    # only execute for workspace end with INT
    if (-not ($WorkspaceName -match 'INT')) {
      Write-Host "Skipping pipeline creation for $WorkspaceName"
      exit 0
    }
    
    Write-Host "##[debug]Organization: $Organization"
    Write-Host "##[debug]Project: $Project"
    Write-Host "##[debug]Pipeline name: $PipelineName"
    Write-Host "##[debug]Repository name: $RepositoryName"
    Write-Host "##[debug]YAML path: $YamlPath"
    Write-Host "##[debug]Release version: $ReleaseVersion"

    # Get authentication token
    $token = Get-DevOpsAuthToken
   
    # Get repository details
    $repository = Get-Repository -Token $token -Organization $Organization -Project $Project -RepositoryName $RepositoryName
   
    # Check if pipeline exists
    $pipeline = Get-Pipeline -Token $token -Organization $Organization -Project $Project -PipelineName $PipelineName
   
    if ($pipeline) {
        $pipelineId = $pipeline.id
        Write-Host "##[debug]Pipeline ID: $pipelineId"
      # do nothing for now
    } else {
        # Create new pipeline pointing to release branch
        $newPipeline = Create-Pipeline -Token $token `
            -Organization $Organization `
            -Project $Project `
            -PipelineName $PipelineName `
            -YamlPath $YamlPath `
            -RepositoryId $repository.id `
            -BranchName $ReleaseVersion
           
        Write-Host "##[debug]Created new pipeline using branch: $ReleaseVersion"
        $pipelineId = $newPipeline.id
    }
   
    # Add variable group permissions for the pipeline
    # Write-Host "##[debug]Setting variable group permissions for pipeline..."
    # if ($pipelineId) {
    #     Set-VariableGroupPipelinePermissions -Token $token `
    #         -Organization $Organization `
    #         -Project $Project `
    #         -VariableGroupName $VariableGroupName `
    #         -PipelineId $pipelineId
    # }
    Write-Host "##[section]Successfully configured pipeline '$PipelineName' to use release branch '$ReleaseVersion'"
}
catch {
    Write-Error $_
    exit 1
}

