param(
    [Parameter(Mandatory = $true)]
    [string] $CopyFromVariableGroupName,

    [Parameter(Mandatory = $true)]
    [string] $userName,

    [string]$KeyvaultPlatformServices = "bhg-hub-fabric01-eus-kv"
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

$collectionUri = $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI
$project = $env:SYSTEM_TEAMPROJECT
$token = Get-DevOpsAuthToken

if (-not $collectionUri -or -not $project) {
    Write-Error "Missing pipeline context: ensure this runs in an Azure DevOps pipeline."
    exit 1
}

if (-not $token) {
    Write-Error "Failed to obtain Azure DevOps token."
    exit 1
}

$authHeader = "Basic $token"

$apiVersion = '7.2-preview.2'
$baseUrl = "${collectionUri}${project}/_apis/distributedtask/variablegroups?api-version=${apiVersion}"

Write-Host "Looking up variable groups in project '$project'..."

write-Host "GET $baseUrl"

$response = Invoke-RestMethod -Uri $baseUrl -Headers @{ Authorization = $authHeader } -Method Get

if (-not $response.value) {
    Write-Error "No variable groups found in project."
    exit 1
}

$sourceGroup = $response.value | Where-Object { $_.name -eq $CopyFromVariableGroupName }

if (-not $sourceGroup) {
    Write-Error "Source variable group named '$CopyFromVariableGroupName' not found."
    exit 1
}

$childDomain = $null
$domain = $null
foreach ($k in $sourceGroup.variables.PSObject.Properties.Name) {
    if ($k -ieq 'CHILD_DOMAIN_NAME' ) {
        $childDomain = $sourceGroup.variables.$k.value
    }
    elseif ($k -ieq 'PARENT_DOMAIN_NAME' ) {
        $domain = $sourceGroup.variables.$k.value
    }
}

Write-Host "domain='$domain' childDomain='$childDomain'"

$newName = ($domain -replace '\s+', '') + "-" + ($childDomain -replace '\s+', '') + "-feature-" + "$($userName)".ToLower()
Write-Host "Cloning '$CopyFromVariableGroupName' to '$newName'..."

$vars = @{}
foreach ($k in $sourceGroup.variables.PSObject.Properties.Name) {
    $v = $sourceGroup.variables.$k
    if ($v.isSecret -eq $true) {
        $value = ""
        switch ($k) {
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
        Write-Host $"Marking variable '$k' as secret with value from KeyVault. (Original value '$value')"    
        $vars[$k] = @{ value = $value; isSecret = $true }
    }
    else {
        $value = $v.value
        switch ($k) {
            "WORKSPACE_NAMES" {
                $value = '["' + ($newName) + '"]'
            }
            "ENVIRONMENT" {
                $value = $userName.ToLower()
            }
        }
        
        $vars[$k] = @{ value = $value; isSecret = $false }
        Write-Host $"Copying variable '$k' with value '$value'."
    }
}

$projectId = $env:SYSTEM_TEAMPROJECTID
if (-not $projectId) {
    Write-Error "SYSTEM_TEAMPROJECTID is not available. Ensure this runs in an Azure DevOps pipeline."
    exit 1
}

$payload = @{
    name                           = $newName
    description                    = "Copied from $CopyFromVariableGroupName"
    variables                      = $vars
    type                           = "Vsts"
    variableGroupProjectReferences = @(
        @{
            name             = $newName
            description      = "Copied from $CopyFromVariableGroupName"
            projectReference = @{
                id   = $projectId
                name = $project
            }
        }
    )            
} | ConvertTo-Json -Depth 10

$createUrl = "${collectionUri}${project}/_apis/distributedtask/variablegroups?api-version=${apiVersion}"

try {
    $created = Invoke-RestMethod -Uri $createUrl -Method Post -Headers @{ Authorization = $authHeader; 'Content-Type' = 'application/json' } -Body $payload
    Write-Host "Created variable group: $($created.id) with name $($created.name)"
}
catch {
    Write-Error "Failed to create variable group: $_"
    exit 1
}
