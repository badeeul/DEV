param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory=$false)]
    [bool]$EnsureWorkspaceExists = $false
)

function Get-FabricAccessToken {
    try {
        Write-Host "Retrieving Fabric access token using Azure CLI"
       
        # Login to Azure using service principal
        $clientId = $env:ARM_CLIENT_ID
        $clientSecret = $env:ARM_CLIENT_SECRET
        $tenantId = $env:ARM_TENANT_ID
       
        if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($clientSecret) -or [string]::IsNullOrEmpty($tenantId)) {
            Write-Error "ARM_CLIENT_ID, ARM_CLIENT_SECRET, and ARM_TENANT_ID environment variables must be set"
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
        $tokenResult = az account get-access-token --resource https://api.fabric.microsoft.com/ --query accessToken --output tsv 2>&1
       
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

function Get-WorkspaceIdByName {
    param(
        [string]$Name,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Looking up workspace: $Name"
       
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces"
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
        $matchingWorkspace = $response.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -ne $matchingWorkspace) {
            Write-Host "##[debug]Found existing workspace ID: $($matchingWorkspace.id)"
            return $matchingWorkspace.id
        }
       
        Write-Host "##[debug]Workspace not found"
        return $null
    }
    catch {
        Write-Error "Failed to lookup workspace: $_"
        throw
    }
}

function Create-Workspace {
    param(
        [string]$WorkspaceName,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Creating workspace: $WorkspaceName"
       
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces"
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        $body = @{
            displayName = $WorkspaceName
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody
       
        Write-Host "##[debug]Successfully created workspace with ID: $($response.id)"
        $workspaceNames = @(
            @{
                $WorkspaceName = $response.id
            }
        )
        return $workspaceNames
    }
    catch {
        Write-Error "Failed to create workspace: $_"
        throw
    }
}

# Main execution
try {
    Write-Host "##[debug]Starting workspace management for: $WorkspaceName"
   
    # Get Fabric token
    $token = Get-FabricAccessToken

    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "FABRIC_TOKEN environment variable is not set"
        exit 1
    }
   
    # Check if workspace exists
    $workspaceId = Get-WorkspaceIdByName -Name $WorkspaceName -Token $token
    
    if ($EnsureWorkspaceExists -and $null -eq $workspaceId) {
        Write-Error "Workspace '$WorkspaceName' does not exist. Please make sure the workspace is created using 'Default' execution mode before proceeding."
        exit 1
    }

    $workspaceNames = @()
    if ($null -eq $workspaceId) {
        # Create new workspace
        $workspaceNames = Create-Workspace -WorkspaceName $WorkspaceName -Token $token
    }
    else {
        $workspaceNames += @{ $WorkspaceName = $workspaceId }
    }
   
    Write-Host "##[debug]Workspace management completed successfully"

    return $workspaceNames
   
}
catch {
    Write-Error "Error in workspace management: $_"
    exit 1
}