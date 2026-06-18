param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory=$false)]
    [bool]$AutomaticLogEnabled = $true,
   
    [Parameter(Mandatory=$false)]
    [bool]$NotebookInteractiveRunEnabled = $false,
   
    [Parameter(Mandatory=$false)]
    [bool]$NotebookPipelineRunEnabled = $true,
   
    [Parameter(Mandatory=$false)]
    [string]$EnvironmentName,
   
    [Parameter(Mandatory=$false)]
    [string]$RuntimeVersion = "1.3"
)

function Get-FabricAccessToken {
    param(
        [string]$Purpose = "Spark Settings"
    )
    try {
        Write-Host "Retrieving Fabric access token using Azure CLI for $Purpose"
       
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
       
        Write-Host "Successfully logged in to Azure for $Purpose"
       
        # Get access token for Fabric API
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

function Invoke-FabricApiWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method,
        [string]$Body = $null,
        [int]$MaxRetries = 3,
        [int]$BaseRetryDelaySeconds = 30
    )
   
    $attempt = 1
   
    while ($attempt -le $MaxRetries) {
        try {
            Write-Host "##[debug]API call attempt $attempt of $MaxRetries to: $Uri"
           
            $requestParams = @{
                Uri = $Uri
                Headers = $Headers
                Method = $Method
            }
           
            if (-not [string]::IsNullOrEmpty($Body)) {
                $requestParams.Body = $Body
            }
           
            $response = Invoke-RestMethod @requestParams
            Write-Host "##[debug]API call successful on attempt $attempt"
            return $response
        }
        catch {
            $errorResponse = $null
           
            # Try to get the response body if available
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
           
            # Check if this is a RequestBlocked error
            if ($errorResponse -and $errorResponse.Contains('"errorCode":"RequestBlocked"')) {
                Write-Host "##[warning]Request blocked by upstream service. Error response: $errorResponse"
               
                if ($attempt -eq $MaxRetries) {
                    Write-Error "Max retries reached. Request still blocked. Last error: $errorResponse"
                    throw "Max retries reached for blocked request: $_"
                }
               
                # Use exponential backoff for blocked requests
                $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
                Write-Host "##[debug]Request blocked, using exponential backoff: $retryDelay seconds"
                Start-Sleep -Seconds $retryDelay
               
                $attempt++
                continue
            }
           
            # For non-RequestBlocked errors, use standard retry logic
            if ($attempt -eq $MaxRetries) {
                Write-Error "API call failed after $MaxRetries attempts. Last error: $_"
                if ($errorResponse) {
                    Write-Error "Response body: $errorResponse"
                }
                throw "API call failed after $MaxRetries attempts: $_"
            }
           
            # Exponential backoff for other errors
            $retryDelay = $BaseRetryDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Host "##[warning]API call failed (attempt $attempt), retrying in $retryDelay seconds. Error: $_"
            Start-Sleep -Seconds $retryDelay
            $attempt++
        }
    }
}

function Get-SparkSettings {
    param(
        [string]$WorkspaceId,
        [string]$Token
    )
   
    try {
        Write-Host "Getting current Spark settings for workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/spark/settings"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get current settings
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5
       
        Write-Host "##[debug]Successfully retrieved current Spark settings"
        return $response
    }
    catch {
        Write-Error "Failed to get Spark settings: $_"
        exit 1
    }
}

function Update-SparkSettings {
    param(
        [string]$WorkspaceId,
        [bool]$AutomaticLogEnabled,
        [bool]$NotebookInteractiveRunEnabled,
        [bool]$NotebookPipelineRunEnabled,
        [string]$EnvironmentName,
        [string]$RuntimeVersion,
        [string]$Token
    )
   
    try {
        Write-Host "Updating Spark settings for workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/spark/settings"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Build request body based on parameters
        $body = @{
            automaticLog = @{
                enabled = $AutomaticLogEnabled
            }
            highConcurrency = @{
                notebookInteractiveRunEnabled = $NotebookInteractiveRunEnabled
                notebookPipelineRunEnabled = $NotebookPipelineRunEnabled
            }
        }
       
        # Add environment settings if environment name is provided
        if (-not [string]::IsNullOrEmpty($EnvironmentName)) {
            $body.environment = @{
                name = $EnvironmentName
                runtimeVersion = $RuntimeVersion
            }
            Write-Host "##[debug]Environment settings: Name=$EnvironmentName, Runtime=$RuntimeVersion"
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        Write-Host "##[debug]Request body: $jsonBody"
       
        # Send PATCH request to update settings
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method PATCH -Body $jsonBody -MaxRetries 5
       
        Write-Host "##[debug]Successfully updated Spark settings for workspace: $WorkspaceId"
        return $response
    }
    catch {
        Write-Error "Failed to update Spark settings: $_"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

# Main execution
try {
    Write-Host "##[debug]Starting Spark settings update"
    Write-Host "##[debug]Parameters received:"
    Write-Host "##[debug] - WorkspaceId: $WorkspaceId"
    Write-Host "##[debug] - AutomaticLogEnabled: $AutomaticLogEnabled"
    Write-Host "##[debug] - NotebookInteractiveRunEnabled: $NotebookInteractiveRunEnabled"
    Write-Host "##[debug] - NotebookPipelineRunEnabled: $NotebookPipelineRunEnabled"
    Write-Host "##[debug] - EnvironmentName: $EnvironmentName"
    Write-Host "##[debug] - RuntimeVersion: $RuntimeVersion"
   
    # Get Fabric token
    $token = Get-FabricAccessToken -Purpose "Spark Settings Update"
    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "Failed to retrieve Fabric access token"
        exit 1
    }
   
    # Get current settings (for logging/comparison)
    Write-Host "##[debug]Retrieving current Spark settings..."
    $currentSettings = Get-SparkSettings -WorkspaceId $WorkspaceId -Token $token
    Write-Host "##[debug]Current settings retrieved"
   
    # Update Spark settings
    Write-Host "##[section]Updating Spark workspace settings..."
    $result = Update-SparkSettings `
        -WorkspaceId $WorkspaceId `
        -AutomaticLogEnabled $AutomaticLogEnabled `
        -NotebookInteractiveRunEnabled $NotebookInteractiveRunEnabled `
        -NotebookPipelineRunEnabled $NotebookPipelineRunEnabled `
        -EnvironmentName $EnvironmentName `
        -RuntimeVersion $RuntimeVersion `
        -Token $token
   
    Write-Host "##[section] Spark settings updated successfully"
    Write-Host "Updated settings:"
    Write-Host "  - Automatic Log: $AutomaticLogEnabled"
    Write-Host "  - Notebook Interactive Run: $NotebookInteractiveRunEnabled"
    Write-Host "  - Notebook Pipeline Run: $NotebookPipelineRunEnabled"
    if (-not [string]::IsNullOrEmpty($EnvironmentName)) {
        Write-Host "  - Environment: $EnvironmentName (Runtime: $RuntimeVersion)"
    }
   
    Write-Host "Spark settings update completed successfully"
}
catch {
    Write-Error "Error updating Spark settings: $_"
    exit 1
}