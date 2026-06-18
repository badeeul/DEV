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

function Get-FabricConnections {
    param(
        [string]$Token
    )
   
    try {
        Write-Host "Getting Fabric connections..."
       
        # Construct API URL for connections
        $apiUrl = "https://api.fabric.microsoft.com/v1/connections"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get connections
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5
       
        Write-Host "##[debug]Successfully retrieved connections from Fabric API"
        return $response
    }
    catch {
        Write-Error "Failed to get connections: $_"
        exit 1
    }
}

function Export-ConnectionsToJson {
    param(
        [array]$Connections,
        [string]$OutputPath
    )
   
    try {
        Write-Host "##[debug]Exporting connections to JSON file: $OutputPath"
       
        # Ensure we have valid data before writing
        if ($null -eq $Connections -or $Connections.Count -eq 0) {
            Write-Host "No connections found"
            # Write empty array if no connections found
            '[]' | Out-File -FilePath $OutputPath -Encoding UTF8
            Write-Host "##[debug]Wrote empty array to $OutputPath"
            return
        }
       
        # Format connections with only essential fields
        $formattedConnections = @($Connections | Select-Object displayName, id, connectivityType, connectionDetails)
       
        # Write to a temporary file first
        $tempFile = "$OutputPath.tmp"
       
        # Ensure it's written as an array
        @($formattedConnections) | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempFile -Encoding UTF8
       
        Write-Host "Found $($formattedConnections.Count) connection(s)"
       
        # Move to final location only if successful
        Move-Item -Path $tempFile -Destination $OutputPath -Force
        Write-Host "Successfully wrote connections to file: $OutputPath"
    }
    catch {
        Write-Error "Failed to export connections: $_"
        # Ensure we have a valid JSON array even on error
        '[]' | Out-File -FilePath $OutputPath -Encoding UTF8
        throw
    }
}

# Main execution
try {
    Write-Host "##[debug]Starting Fabric connections retrieval"
   
    # Get Fabric token
    $token = Get-FabricAccessToken -Purpose "Fabric Connections"
    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "Failed to retrieve Fabric access token"
        exit 1
    }
   
    # Get connections from Fabric API
    Write-Host "##[debug]Retrieving connections from Fabric API"
    $response = Get-FabricConnections -Token $token
   
    # Extract connections array from response
    $connections = @()
    if ($response.value) {
        $connections = @($response.value)
        Write-Host "##[debug]Retrieved $($connections.Count) connection(s) from API"
    } else {
        Write-Host "##[warning]No connections found in response"
    }
   
    # Determine output path (default to current directory)
    $outputPath = Join-Path -Path $PSScriptRoot -ChildPath "connections.json"
   
    # If running from a different context, use current directory
    if ([string]::IsNullOrEmpty($PSScriptRoot)) {
        $outputPath = "connections.json"
    }
   
    Write-Host "##[debug]Output path: $outputPath"
   
    # Export connections to JSON
    Export-ConnectionsToJson -Connections $connections -OutputPath $outputPath
   
    Write-Host "Fabric connections retrieval completed successfully"
    Write-Host "Output saved to: $outputPath"
   
}
catch {
    Write-Error "Error in Fabric connections retrieval: $_"
   
    # Ensure connections.json exists even on error (for Terraform compatibility)
    $fallbackPath = "connections.json"
    if (-not (Test-Path $fallbackPath)) {
        '[]' | Out-File -FilePath $fallbackPath -Encoding UTF8
        Write-Host "##[debug]Created empty connections.json as fallback"
    }
   
    exit 1
}
