# Copy-VariableGroup.ps1
param (
    [Parameter(Mandatory=$true)]
    [string]$SourceOrg,
    [Parameter(Mandatory=$true)]
    [string]$SourceProject,
    [Parameter(Mandatory=$true)]
    [string]$SourceGroupName,
    [Parameter(Mandatory=$true)]
    [string]$TargetOrg,
    [Parameter(Mandatory=$true)]
    [string]$TargetProject,
    [Parameter(Mandatory=$true)]
    [string]$TargetGroupName,
    [Parameter(Mandatory=$true)]
    [string]$TargetWorkspaceName,
    [Parameter(Mandatory=$true)]
    [string]$TargetParentDomainName,
    [Parameter(Mandatory=$true)]
    [string]$TargetChildDomainName,
    [Parameter(Mandatory=$true)]
    [string]$TargetRepository,
    [string]$Environment,
    [string]$AdminGroupPrincipalIds,
    [string]$ContributorGroupPrincipalIds,
    [string]$CapacityId,
    [string]$KeyvaultName,
    [string]$PepFilePath = "", # New parameter for file path
    [string]$ViewerGroupPrincipalIds,    
    [string]$KeyvaultPlatformServices = "bhg-hub-fabric01-eus-kv",
    [string]$LakeHouseDefaultReadersFilePath = ""
)

function Get-KeyVaultAuthToken {
    try {
        if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
            Install-Module -Name Az.Accounts -Force -Scope CurrentUser
        }
       
        $secureSecret = ConvertTo-SecureString $env:ARM_CLIENT_SECRET -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential(
            $env:ARM_CLIENT_ID, $secureSecret)

        # Connect to Azure using service principal
        Connect-AzAccount -ServicePrincipal -Tenant $env:ARM_TENANT_ID -Credential $credential

        # Get context for Key Vault operations
        Set-AzContext -Subscription $env:ARM_SUBSCRIPTION_ID

        return $true
    }
    catch {
        Write-Error "Failed to authenticate for Key Vault access: $_"
        throw
    }
}

function Get-KeyVaultSecret {
    param (
        [string]$SecretName,
        [string]$KeyvaultName
    )
    try {
        # First import required module
        if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
            Install-Module -Name Az.KeyVault -Force -Scope CurrentUser
        }
        Import-Module Az.KeyVault

        $secret = Get-AzKeyVaultSecret -VaultName $KeyvaultName -Name $SecretName -AsPlainText
        return $secret
    }
    catch {
        Write-Error "Failed to get secret $SecretName from KeyVault: $_"
        throw
    }
}

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

function Copy-AzDevOpsVariableGroup {
    param (
        [string]$Token,
        [string]$SourceOrg,
        [string]$SourceProject,
        [string]$SourceGroupName,
        [string]$TargetOrg,
        [string]$TargetProject,
        [string]$TargetGroupName,
        [string]$TargetWorkspaceName,
        [string]$TargetParentDomainName,
        [string]$TargetChildDomainName,
        [string]$Environment,
        [string]$AdminGroupPrincipalIds,
        [string]$ContributorGroupPrincipalIds,
        [string]$CapacityId,
        [string]$KeyvaultName,
        [string]$PepFilePath,
        [string]$ViewerGroupPrincipalIds,
        [string]$LakeHouseDefaultReadersFilePath
    )

   $headers = @{
       'Authorization' = "Basic $Token"
       'Content-Type' = 'application/json'
   }

    try {
       # Custom URL encoding function
        function Format-GitUrl {
            param ([string]$value)
            return $value.Replace(' ', '%20')
        }

        # Process PEP JSON parameter into individual flattened properties
        Write-Host "##[debug]Processing PEP parameter into flattened properties"
        $pepProperties = @{}
       
       
        try {
            # First check if a file path was provided
            if (-not [string]::IsNullOrWhiteSpace($PepFilePath) -and (Test-Path $PepFilePath)) {
                Write-Host "##[debug]Reading PEP JSON from file: $PepFilePath"
                $pepJson = Get-Content -Path $PepFilePath -Raw
            } 
           
            if (-not [string]::IsNullOrWhiteSpace($pepJson)) {
                Write-Host "##[debug]PEP JSON content: $pepJson"
                $pepObj = $pepJson | ConvertFrom-Json
               
                # Ensure it's an array
                if ($pepObj -isnot [System.Array]) {
                    Write-Host "##[debug]Converting single PEP object to array"
                    $pepObj = @($pepObj)
                }
               
                # Process each PEP entry into flattened properties
                foreach ($entry in $pepObj) {
                    if (($entry.PSObject.Properties.Name -contains "subresourceType") -and
                        ($entry.PSObject.Properties.Name -contains "allowed") -and
                        ($entry.PSObject.Properties.Name -contains "resourceId")) {
                       
                        $subresourceType = $entry.subresourceType
                       
                        # Create flattened properties
                        $pepProperties["pep.$subresourceType.allowed"] = $entry.allowed.ToString().ToLower()
                        $pepProperties["pep.$subresourceType.resourceId"] = $entry.resourceId
                        $pepProperties["pep.$subresourceType.subresourceType"] = $subresourceType
                       
                        Write-Host "##[debug]Created flattened properties for $subresourceType"
                    } else {
                        Write-Warning "PEP entry missing required fields, skipping: $($entry | ConvertTo-Json -Compress)"
                    }
                }
               
                Write-Host "##[debug]Processed $($pepObj.Count) private endpoint configurations into $(($pepProperties.Keys | Measure-Object).Count - 1) flattened properties"
            } else {
                Write-Host "##[debug]No PEP parameter provided"
            }
        } catch {
            Write-Warning "Failed to process PEP JSON parameter: $_"
            Write-Host "##[debug]Using empty PEP array due to parsing error"
        }

        $lakeHouseReaderProperties = @{}
        try {
            # Process Lake House Default Readers JSON from file if provided
            if (-not [string]::IsNullOrWhiteSpace($LakeHouseDefaultReadersFilePath) -and (Test-Path $LakeHouseDefaultReadersFilePath)) {
                Write-Host "##[debug]Reading Lake House Default Readers JSON from file: $LakeHouseDefaultReadersFilePath"
                $lakeHouseReadersJson = Get-Content -Path $LakeHouseDefaultReadersFilePath -Raw
               
                if (-not [string]::IsNullOrWhiteSpace($lakeHouseReadersJson)) {
                    Write-Host "##[debug]Lake House Default Readers JSON content: $lakeHouseReadersJson"
                    $lakehouseObject = $lakeHouseReadersJson | ConvertFrom-Json
                    $lakeHouseReaderProperties["lakeHouse.defaultReaders.lakehouse_1.name"] = $lakehouseObject.lakehouse_1_name
                    $lakeHouseReaderProperties["lakeHouse.defaultReaders.lakehouse_1.readerMembers"] = $lakehouseObject.lakehouse_1_readerMembers
                } else {
                    Write-Host "##[debug]Lake House Default Readers JSON file is empty"
                }
            } else {
                Write-Host "##[debug]No Lake House Default Readers file path provided or file does not exist"
            }
        } catch {
            Write-Warning "Failed to process Lake House Default Readers JSON file: $_"
        }

        $encodedTargetProj = Format-GitUrl $TargetProject
        $encodedSourceGroupName = Format-GitUrl $SourceGroupName
        $encodedSourceProj = Format-GitUrl $SourceProject
        $encodedTargetGroupName = Format-GitUrl $TargetGroupName
     
        # Debug info
        Write-Host "##[debug]Source org: $SourceOrg"
        Write-Host "##[debug]Source project: $SourceProject"
        Write-Host "##[debug]Source group name: $SourceGroupName"
        Write-Host "##[debug]Target org: $TargetOrg"
        Write-Host "##[debug]Target project: $TargetProject"
        Write-Host "##[debug]Target group name: $TargetGroupName"
       
        $sourceUrl = "https://dev.azure.com/$SourceOrg/$encodedSourceProj/_apis/distributedtask/variablegroups?groupName=$encodedSourceGroupName&api-version=7.2-preview.2"

        # debug source project exists
        Write-Host "##[debug]Source URL: $sourceUrl"
 
        $sourceGroup = Invoke-RestMethod -Uri $sourceUrl -Headers $headers -Method Get

        if (-not $sourceGroup -or -not $sourceGroup.value -or $sourceGroup.value.Count -eq 0) {
            Write-Host "##[debug]Source group response: $($sourceGroup | ConvertTo-Json)"
            throw "Source variable group '$SourceGroupName' not found or empty"
        }

        Write-Host "##[debug]Found source group with $($sourceGroup.value.Count) variables"

        # Get target project ID
        $projectUrl = "https://dev.azure.com/$TargetOrg/_apis/projects/$encodedTargetProj`?api-version=7.2-preview.2"
        $projectDetails = Invoke-RestMethod -Uri $projectUrl -Headers $headers -Method Get
        $targetProjectId = $projectDetails.id

       # Check if target group exists
       $targetGroupUrl = "https://dev.azure.com/$TargetOrg/$encodedTargetProj/_apis/distributedtask/variablegroups?groupName=$encodedTargetGroupName&api-version=7.2-preview.2"
       $targetGroup = Invoke-RestMethod -Uri $targetGroupUrl -Headers $headers -Method Get

        # Certain variables cannot be overwritten if exists at target variable group    
        $variables = @{}
        $skip_connection = $false
        $skip_default_spark_environment_name = $false
        $skip_default_spark_runtime = $false
        $skip_shortcut = $false
        $skip_sparkcompute = $false
        $skip_mng_connection = $false
        $skip_teams_channel_web_url = $false
        $skip_teams_tags = $false
        $skip_capacity_id = $false
        $skip_sm = $false
        $skip_smParameter = $false
        $skip_keyvault_name = $false
        $skip_lakehouse_default_readers = $false

        if ($targetGroup.count -gt 0) {
            if ($targetGroup.value -and $targetGroup.value[0].variables) {
                foreach ($key in $targetGroup.value[0].variables.PSObject.Properties.Name) {
                    $value = $targetGroup.value[0].variables.$key.value
                  
                    if ($key.ToLower().StartsWith("connection")) {
                        $variables[$key] = @{
                            value = $value
                            isSecret = $false
                        }
                        $skip_connection = $true
                    }
                    if ($key.ToLower().StartsWith("mngconnection")) {
                        $variables[$key] = @{
                            value = $value
                            isSecret = $false
                        }
                        $skip_mng_connection = $true
                    }   
                    if ($key.ToLower().StartsWith("sm")) {
                        $variables[$key] = @{
                            value = $value
                            isSecret = $false
                        }
                        $skip_sm = $true
                    }    
                    if ($key.ToLower().StartsWith("smparameter")) {
                        $variables[$key] = @{
                            value = $value
                            isSecret = $false
                        }
                        $skip_smParameter = $true
                    }                    
                    if ($key.ToLower().StartsWith("sparkcompute")) {
                        $variables[$key] = @{
                            value = $value
                            isSecret = $false
                        }
                        $skip_sparkcompute = $true
                    }
                    if ($key.ToLower().StartsWith("shortcut")) {
                        $variables[$key] = @{
                            value = $value
                            isSecret = $false
                        }
                        $skip_shortcut = $true
                    }                    
                    if ($key -eq "DEFAULT_SPARK_ENVIRONMENT_NAME") {
                        $variables[$key] = @{
                            value = $value
                            isSecret =$false
                        }
                        $skip_default_spark_environment_name = $true
                    }
                    if ($key -eq "DEFAULT_SPARK_RUNTIME") {
                        $variables[$key] = @{
                            value = $value
                            isSecret =$false
                        }
                        $skip_default_spark_runtime = $true
                    }
                    if ($key -eq "TEAMS_CHANNEL_WEB_URL") {
                        $variables[$key] = @{
                            value = $value
                            isSecret =$false
                        }
                        $skip_teams_channel_web_url = $true
                    }
                    if ($key -eq "TEAMS_TAGS") {
                        $variables[$key] = @{
                            value = $value
                            isSecret = $false
                        }
                        $skip_teams_tags = $true
                    }
                    if ($key -eq "CAPACITY_ID") {
                        $variables[$key] = @{
                            value = $value
                            isSecret = $false
                        }
                        $skip_capacity_id = $true
                    }
                    if ($key -eq "KEYVAULT_NAME") {
                        $variables[$key] = @{
                            value = $value
                            isSecret = $false
                        }
                        $skip_keyvault_name = $true
                    }
                    if ($lakeHouseReaderProperties.ContainsKey($key)) {
                        $variables[$key] = @{
                            value    = $lakeHouseReaderProperties[$key]
                            isSecret = $false
                        }
                        $skip_lakehouse_default_readers = $true
                    }
                }
            }
        }

        # Prepare new group with fallback values
        $description = if ($sourceGroup.value[0].description) {
            $sourceGroup.value[0].description
        } else {
            "Copied from $SourceGroupName"
        }
       
        Write-Host "##[debug]Description: $description"
        write-Host "##[debug]Target project ID: $targetProjectId"
        Write-Host "##[debug]Target group name: $TargetGroupName"

        if ($sourceGroup.value -and $sourceGroup.value[0].variables) {
          foreach ($key in $sourceGroup.value[0].variables.PSObject.Properties.Name) {
            $value = $sourceGroup.value[0].variables.$key.value
            $isSecret = if ($null -eq $sourceGroup.value[0].variables.$key.isSecret) {
                $false
            } else {
                $sourceGroup.value[0].variables.$key.isSecret
            }

            if ($key -eq "ENVIRONMENT")
            {
                $value = $Environment
            }

            if ($key -eq "PIPELINE_ENVIRONMENT_APPROVAL" -and $Environment -eq "prd") {
                $value = "productionManagementApproval"  
            }

            if ($key -eq "CAPACITY_ID") {
                $value = $CapacityId
            }

            if ($key -eq "KEYVAULT_NAME") {
                $value = $KeyvaultName
            }
            # add them at pipeline level
            if ($key -eq "WORKSPACE_NAMES") {
                $value = "[$($TargetWorkspaceName -replace '^"|"$' | ConvertTo-Json)]"
            }

            if ($key -eq "ADMIN_GROUP_PRINCIPAL_IDS") {
                if ([string]::IsNullOrWhiteSpace($AdminGroupPrincipalIds)) {
                    $value = "[]"
                } else {
                    # Original processing for non-empty case
                    $principalIds = $AdminGroupPrincipalIds -split ',' | ForEach-Object { $_.Trim(' "\"') }
                    $value = "[" + ($principalIds -join ',') + "]"
                    $value = $value.Replace('[', '["').Replace(']', '"]').Replace(',', '","').Replace(' ', '')
                }
            }
            if ($key -eq "VIEWER_GROUP_PRINCIPAL_IDS") {
                if ([string]::IsNullOrWhiteSpace($ViewerGroupPrincipalIds)) {
                    $value = "[]"
                } else {
                    # Original processing for non-empty case
                    $principalIds = $ViewerGroupPrincipalIds -split ',' | ForEach-Object { $_.Trim(' "\"') }
                    $value = "[" + ($principalIds -join ',') + "]"
                    $value = $value.Replace('[', '["').Replace(']', '"]').Replace(',', '","').Replace(' ', '')
                }
            }
            if ($key -eq "CONTRIBUTOR_GROUP_PRINCIPAL_IDS") {
                if ([string]::IsNullOrWhiteSpace($ContributorGroupPrincipalIds)) {
                    $value = "[]"
                } else {
                    # Original processing for non-empty case
                    $principalIds = $ContributorGroupPrincipalIds -split ',' | ForEach-Object { $_.Trim(' "\"') }
                    $value = "[" + ($principalIds -join ',') + "]"
                    $value = $value.Replace('[', '["').Replace(']', '"]').Replace(',', '","').Replace(' ', '')
                }
            }

            if ($key -eq "PARENT_DOMAIN_NAME") {
                $value = $TargetParentDomainName
            }
            if ($key -eq "CHILD_DOMAIN_NAME") {
                $value = $TargetChildDomainName
            }
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

            if ($key.ToLower().StartsWith("connection") -and $skip_connection) {
                Write-Host "##[debug]Skipping connection variable: $key"
                continue
            }
            if ($key.ToLower().StartsWith("mngconnection") -and $skip_mng_connection) {
                Write-Host "##[debug]Skipping mngconnection variable: $key"
                continue
            }
            if ($key.ToLower().StartsWith("sm") -and $skip_sm) {
                Write-Host "##[debug]Skipping sm variable: $key"
                continue
            }
            if ($key.ToLower().StartsWith("smparameter") -and $skip_smParameter) {
                Write-Host "##[debug]Skipping smparameter variable: $key"
                continue
            }
            if ($key.ToLower().StartsWith("sparkcompute") -and $skip_sparkcompute) {
                Write-Host "##[debug]Skipping sparkcompute variable: $key"
                continue
            }            
            if ($key.ToLower().StartsWith("shortcut") -and $skip_shortcut) {
                Write-Host "##[debug]Skipping shortcut variable: $key"
                continue
            }
            if ($key -eq "DEFAULT_SPARK_ENVIRONMENT_NAME" -and $skip_default_spark_environment_name) {
                Write-Host "##[debug]Skipping default spark environment name variable: $key"
                continue
            }            
            if ($key -eq "DEFAULT_SPARK_RUNTIME" -and $skip_default_spark_runtime) {
                Write-Host "##[debug]Skipping default spark runtime variable: $key"
                continue
            }
            if ($key -eq "TEAMS_CHANNEL_WEB_URL" -and $skip_teams_channel_web_url) {
                Write-Host "##[debug]Skipping teams channel web url variable: $key"
                continue
            }
            if ($key -eq "TEAMS_TAGS" -and $skip_teams_tags) {
                Write-Host "##[debug]Skipping tags variable: $key"
                continue
            }
            if ($key -eq "CAPACITY_ID" -and $skip_capacity_id) {
                Write-Host "##[debug]Skipping capacity id variable: $key"
                continue
            }
            if ($key -eq "KEYVAULT_NAME" -and $skip_keyvault_name) {
                Write-Host "##[debug]Skipping keyvault name variable: $key"
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

        # Add flattened PEP properties to the variables
        foreach ($key in $pepProperties.Keys) {

            Write-Host "##[debug]Adding PEP property: $key = $($pepProperties[$key])"
            $variables[$key] = @{
                value = $pepProperties[$key]
                isSecret = $false
            }
        }

        foreach ($key in $lakeHouseReaderProperties.Keys) {
            if ($skip_lakehouse_default_readers) {
                Write-Host "##[debug]Skipping lakehouse default readers variable: $key"
                continue
            }
            Write-Host "##[debug]Adding LakeHouse Reader property: $key = $($lakeHouseReaderProperties[$key])"
            $variables[$key] = @{
                value    = $lakeHouseReaderProperties[$key]
                isSecret = $false
            }
        }

        #  add key TargetOrganization
        $variables["TARGET_ORGANIZATION"] = @{
            value = $TargetOrg
            isSecret = $false
        }
        # add key TargetProject
        $variables["TARGET_PROJECT"] = @{
            value = $TargetProject
            isSecret = $false
        }
        # add key target repository
        $variables["TARGET_REPOSITORY"] = @{
            value = $TargetRepository
            isSecret = $false
        }
        Write-Host "##[debug]Prepared variables: $($variables | ConvertTo-Json -Depth 5)"

        $newGroup = @{
            name = $TargetGroupName
            description = $description
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

        # Add debug output before API call
        Write-Host "##[debug]Request body: $($newGroup | ConvertTo-Json -Depth 10)"
       
        if ($targetGroup.count -gt 0) {
            # Update existing group
            $groupId = $targetGroup.value[0].id
            Write-Host "##[debug]Updating existing variable group: $groupId"
           
            $updateUrl = "https://dev.azure.com/$TargetOrg/_apis/distributedtask/variablegroups/$groupId`?api-version=7.2-preview.2"
            $response = Invoke-RestMethod -Uri $updateUrl -Headers $headers -Method Put -Body ($newGroup | ConvertTo-Json -Depth 10)
        }
        else {
            # Create new group
            Write-Host "##[debug]Creating new variable group"
           
            $createUrl = "https://dev.azure.com/$TargetOrg/_apis/distributedtask/variablegroups?api-version=7.2-preview.2"
            $response = Invoke-RestMethod -Uri $createUrl -Headers $headers -Method Post -Body ($newGroup | ConvertTo-Json -Depth 10)
        }
       
        Write-Host "##[debug]Variable group copied successfully. New group ID: $($response.id)"
        return $response.id
    }
    catch {
        Write-Error "Failed to copy variable group: $_"
        throw
    }
}

try {

    Get-KeyVaultAuthToken

    $token = Get-DevOpsAuthToken
   
    write-Host "##[debug]Token: $token"
    write-Host "##[debug]SourceOrg: $SourceOrg"
    write-Host "##[debug]SourceProject: $SourceProject"
    write-Host "##[debug]SourceGroupName: $SourceGroupName"
    write-Host "##[debug]TargetOrg: $TargetOrg"
    write-Host "##[debug]TargetProject: $TargetProject"
    write-Host "##[debug]TargetGroupName: $TargetGroupName"
    write-Host "##[debug]TargetWorkspaceName: $TargetWorkspaceName"
    write-Host "##[debug]TargetParentDomainName: $TargetParentDomainName"
    write-Host "##[debug]TargetChildDomainName: $TargetChildDomainName"
    write-Host "##[debug]Environment: $Environment"
    write-Host "##[debug]AdminGroupPrincipalIds: $AdminGroupPrincipalIds"
    write-Host "##[debug]ContributorGroupPrincipalIds: $ContributorGroupPrincipalIds"
    Write-Host "##[debug]KeyVaultName: $KeyVaultName"
    Write-Host "##[debug]PepFilePath: $PepFilePath"
    Write-Host "##[debug]LakeHouseDefaultReadersFilePath: $LakeHouseDefaultReadersFilePath"


    $copyParams = @{
        Token = $token
        SourceOrg = $SourceOrg
        SourceProject = $SourceProject
        SourceGroupName = $SourceGroupName
        TargetOrg = $TargetOrg
        TargetProject = $TargetProject
        TargetGroupName = $TargetGroupName
        TargetWorkspaceName = $TargetWorkspaceName
        TargetParentDomainName = $TargetParentDomainName
        TargetChildDomainName = $TargetChildDomainName
        Environment = $environment
        AdminGroupPrincipalIds = $adminGroupPrincipalIds
        ContributorGroupPrincipalIds = $contributorGroupPrincipalIds
        CapacityId = $CapacityId
        KeyvaultName = $KeyVaultName
        PepFilePath = $PepFilePath
        ViewerGroupPrincipalIds = $ViewerGroupPrincipalIds
        LakeHouseDefaultReadersFilePath = $LakeHouseDefaultReadersFilePath
    }

    $groupId = Copy-AzDevOpsVariableGroup @copyParams
    Write-Host "##vso[task.setvariable variable=NewGroupId;isoutput=true]$groupId"
}
catch {
    Write-Error $_
    exit 1
}
