param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory=$true)]
    [string]$EnvironmentName,
   
    [Parameter(Mandatory=$true)]
    [int]$DriverCores,
   
    [Parameter(Mandatory=$true)]
    [string]$DriverMemory,
   
    [Parameter(Mandatory=$true)]
    [int]$ExecutorCores,
   
    [Parameter(Mandatory=$true)]
    [string]$ExecutorMemory,
   
    [Parameter(Mandatory=$true)]
    [string]$RuntimeVersion,
   
    [Parameter(Mandatory=$true)]
    [int]$MinExecutors,
   
    [Parameter(Mandatory=$true)]
    [int]$MaxExecutors
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

function Get-EnvironmentIdByName {
    param(
        [string]$WorkspaceId,
        [string]$Name,
        [string]$Token
    )
   
    try {
        Write-Host "Looking up environment ID for environment name: $Name in workspace: $WorkspaceId"
       
        # Construct API URL for environments in the workspace
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get environments
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET

        # Iterate through environments to find matching display name
        $matchingEnvironment = $response.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingEnvironment) {
            Write-Error "No environment found with name: $Name"
            exit 1
        }

        $environmentId = $matchingEnvironment.id
        Write-Host "##[debug]Found environment ID: $environmentId for environment name: $Name"
        return $environmentId
    }
    catch {
        Write-Error "Failed to get environment ID: $_"
        exit 1
    }
}

function Set-SparkEnvironmentSettings {
    param(
        [string]$WorkspaceId,
        [string]$EnvironmentId,
        [int]$DriverCores,
        [string]$DriverMemory,
        [int]$ExecutorCores,
        [string]$ExecutorMemory,
        [string]$RuntimeVersion,
        [int]$MinExecutors,
        [int]$MaxExecutors,
        [string]$Token
    )
   
    try {
        Write-Host "Configuring Spark settings for environment ID: $EnvironmentId in workspace: $WorkspaceId"
       
        # Construct API URL for Spark environment settings
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments/$EnvironmentId/staging/sparkcompute"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Prepare request body with Spark configuration
        $body = @{
            driverCores = $DriverCores
            driverMemory = $DriverMemory
            executorCores = $ExecutorCores
            executorMemory = $ExecutorMemory
            runtimeVersion = $RuntimeVersion
            dynamicExecutorAllocation = @{
                enabled = $true
                minExecutors = $MinExecutors
                maxExecutors = $MaxExecutors
            }
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        Write-Host "##[debug]Spark settings request body: $jsonBody"
       
        # Send request to configure Spark settings
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method PATCH -Body $jsonBody
       
        Write-Host "##[debug]Successfully configured Spark settings for environment ID: $EnvironmentId"
       
        # # Publish the environment to make settings active
        # Write-Host "Publishing environment to activate Spark settings..."
        # $publishUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/environments/$EnvironmentId/staging/publish"
        # $publishResponse = Invoke-RestMethod -Uri $publishUrl -Headers $headers -Method POST
       
        # Write-Host "##[debug]Successfully published environment with Spark settings"
        return $response
    }
    catch {
        Write-Error "Failed to configure Spark settings for environment ID '$EnvironmentId': $_"
        exit 1
    }
}

# Main execution
try {
    Write-Host "##[debug]Starting Spark environment settings configuration"
    Write-Host "##[debug] Parameters received:"
    Write-Host "##[debug] - WorkspaceId: $WorkspaceId"
    Write-Host "##[debug] - EnvironmentName: $EnvironmentName"
    Write-Host "##[debug] - DriverCores: $DriverCores"
    Write-Host "##[debug] - DriverMemory: $DriverMemory"
    Write-Host "##[debug] - ExecutorCores: $ExecutorCores"
    Write-Host "##[debug] - ExecutorMemory: $ExecutorMemory"
    Write-Host "##[debug] - RuntimeVersion: $RuntimeVersion"
    Write-Host "##[debug] - MinExecutors: $MinExecutors"
    Write-Host "##[debug] - MaxExecutors: $MaxExecutors"
   
    # Get Fabric token
    $token = Get-FabricAccessToken
    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "Failed to retrieve Fabric access token"
        exit 1
    }
   
    # Get environment ID by name
    $environmentId = Get-EnvironmentIdByName -WorkspaceId $WorkspaceId -Name $EnvironmentName -Token $token
    if ([string]::IsNullOrEmpty($environmentId)) {
        Write-Error "Environment '$EnvironmentName' not found in workspace '$WorkspaceId'"
        exit 1
    }
   
    # Configure Spark settings
    $result = Set-SparkEnvironmentSettings -WorkspaceId $WorkspaceId -EnvironmentId $environmentId -DriverCores $DriverCores -DriverMemory $DriverMemory -ExecutorCores $ExecutorCores -ExecutorMemory $ExecutorMemory -RuntimeVersion $RuntimeVersion -MinExecutors $MinExecutors -MaxExecutors $MaxExecutors -Token $token
   
    Write-Host "Spark environment settings configuration completed successfully"
    Write-Output $result | ConvertTo-Json -Depth 10
}
catch {
    Write-Error "Error in Spark environment settings configuration: $_"
    exit 1
}