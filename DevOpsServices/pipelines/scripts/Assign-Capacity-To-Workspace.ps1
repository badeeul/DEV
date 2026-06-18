param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory=$true)]
    [string]$CapacityId
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

function Get-WorkspaceById {
    param(
        [string]$WorkspaceId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Looking up workspace: $WorkspaceId"
       
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId"
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
       
        if ($response.id -eq $WorkspaceId) {
            Write-Host "##[debug]Found existing workspace ID: $($response.id)"
            return $response.id
        }
       
        Write-Host "##[debug]Workspace not found"
        return $null
    }
    catch {
        Write-Error "Failed to lookup workspace: $_"
        throw
    }
}

function Assign-Capacity-To-Workspace {
    param(
        [string]$WorkspaceId,
        [string]$CapacityId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Assigning capacity ID: $CapacityId to workspace ID: $WorkspaceId"
       
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/assignToCapacity"
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        $body = @{
            capacityId = $CapacityId
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody
        
        Write-Host "##[debug]Successfully assigned capacity to workspace"
    }
    catch {
        Write-Error "Failed to assign capacity to workspace: $_"
        throw
    }
}

# Main execution
try {
    Write-Host "##[debug]Starting workspace management for: $WorkspaceId"
   
    # Get Fabric token
    $token = Get-FabricAccessToken

    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "FABRIC_TOKEN environment variable is not set"
        exit 1
    }
   
    # Check if workspace exists
    $workspaceId = Get-WorkspaceById -WorkspaceId $WorkspaceId -Token $token
    if ($null -eq $workspaceId) {
        Write-Error "Workspace with id '$workspaceId' does not exist. Cannot assign capacity."
        exit 1
    }
    else {
        # Assign capacity to existing workspace
        Assign-Capacity-To-Workspace -WorkspaceId $workspaceId -CapacityId $CapacityId -Token $token
        Write-Host "##[debug]Assigned capacity '$CapacityId' to workspace '$WorkspaceName' (ID: $workspaceId)"
    }
   
    Write-Host "##[debug]Workspace management completed successfully"
}
catch {
    Write-Error "Error in workspace management: $_"
    exit 1
}