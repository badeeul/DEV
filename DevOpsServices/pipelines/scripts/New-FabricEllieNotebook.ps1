param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory=$true)]
    [string]$DisplayName,
   
    [Parameter(Mandatory=$true)]
    [string]$SqlFilePath,
   
    [Parameter(Mandatory=$true)]
    [string]$DefaultLakehouseName,
   
    [Parameter(Mandatory=$false)]
    [string]$Description = "",
   
    [Parameter(Mandatory=$false)]
    [string]$FolderId
)

function Get-FabricAccessToken {
    param(
        [string]$Purpose = "Ellie Notebook Creation"
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

function Get-LakehouseIdByName {
    param(
        [string]$WorkspaceId,
        [string]$Name,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Looking up lakehouse ID for lakehouse name: $Name in workspace: $WorkspaceId"
       
        # Construct API URL for lakehouses in the workspace
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get lakehouses
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5

        # Iterate through lakehouses to find matching display name
        $matchingLakehouse = $response.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingLakehouse) {
            Write-Warning "No lakehouse found with name: $Name"
            return $null
        }

        $lakehouseId = $matchingLakehouse.id
        Write-Host "##[debug]Found lakehouse ID: $lakehouseId for lakehouse name: $Name"
        return $lakehouseId
    }
    catch {
        Write-Error "Failed to get lakehouse ID: $_"
        exit 1
    }
}

function Get-NotebookIdByName {
    param(
        [string]$WorkspaceId,
        [string]$NotebookName,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Looking up notebook ID for: $NotebookName in workspace: $WorkspaceId"
       
        # Construct API URL for notebooks in workspace
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get notebooks
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method GET -MaxRetries 5
       
        # Find notebook with matching display name
        $matchingNotebook = $response.value | Where-Object { $_.displayName -eq $NotebookName }
       
        if ($null -eq $matchingNotebook) {
            Write-Host "##[debug]No notebook found with name: $NotebookName"
            return $null
        }
       
        Write-Host "##[debug]Found notebook ID: $($matchingNotebook.id)"
        return $matchingNotebook.id
    }
    catch {
        Write-Warning "Failed to lookup notebook: $_"
        return $null
    }
}

function New-NotebookJsonContent {
    param(
        [string]$SqlContent,
        [string]$DefaultLakehouseName,
        [string]$DefaultLakehouseId,
        [string]$WorkspaceId
    )
   
    try {
        Write-Host "##[debug]Generating notebook JSON content"
       
        # Create notebook structure matching Terraform format
        $notebookContent = @{
            cells = @(
                @{
                    cell_type = "code"
                    source = @($SqlContent)
                    metadata = @{
                        microsoft = @{
                            language = "sparksql"
                            language_group = "synapse_pyspark"
                        }
                    }
                    outputs = @()
                }
            )
            metadata = @{
                kernel_info = @{
                    name = "synapse_pyspark"
                }
                language_info = @{
                    name = "sql"
                }
                dependencies = @{
                    lakehouse = @{
                        default_lakehouse = $DefaultLakehouseId
                        default_lakehouse_name = $DefaultLakehouseName
                        default_lakehouse_workspace_id = $WorkspaceId
                    }
                }
            }
            nbformat = 4
            nbformat_minor = 2
        }
       
        $jsonContent = $notebookContent | ConvertTo-Json -Depth 10 -Compress
        Write-Host "##[debug]Notebook JSON content generated successfully"
       
        return $jsonContent
    }
    catch {
        Write-Error "Failed to generate notebook JSON: $_"
        throw
    }
}

function ConvertTo-Base64 {
    param(
        [string]$Content
    )
   
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $base64 = [Convert]::ToBase64String($bytes)
        return $base64
    }
    catch {
        Write-Error "Failed to convert content to Base64: $_"
        throw
    }
}

function New-FabricNotebook {
    param(
        [string]$WorkspaceId,
        [string]$DisplayName,
        [string]$NotebookJsonContent,
        [string]$Description,
        [string]$FolderId,
        [string]$Token
    )
   
    try {
        Write-Host "Creating Fabric notebook: $DisplayName in workspace: $WorkspaceId"
       
        # Construct API URL
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Convert notebook content to Base64
        $base64Content = ConvertTo-Base64 -Content $NotebookJsonContent
       
        # Build request body
        $body = @{
            displayName = $DisplayName
            definition = @{
                format = "ipynb"
                parts = @(
                    @{
                        path = "notebook-content.ipynb"
                        payload = $base64Content
                        payloadType = "InlineBase64"
                    }
                )
            }
        }
       
        # Add optional fields if provided
        if (-not [string]::IsNullOrEmpty($Description)) {
            $body.description = $Description
        }
       
        if (-not [string]::IsNullOrEmpty($FolderId)) {
            $body.folderId = $FolderId
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        Write-Host "##[debug]Request body prepared (payload truncated for logging)"
       
        # Send POST request to create notebook
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5

        # Sleep briefly to allow notebook creation to propagate
        Start-Sleep -Seconds 10

        $existingNotebookId = Get-NotebookIdByName `
            -WorkspaceId $WorkspaceId `
            -NotebookName $DisplayName `
            -Token $Token

        Write-Host "##[debug]Successfully created notebook: $DisplayName with ID: $($existingNotebookId)"
        return $existingNotebookId
    }
    catch {
        Write-Error "Failed to create notebook: $_"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response body: $responseBody"
        }
        exit 1
    }
}

function Update-FabricNotebook {
    param(
        [string]$WorkspaceId,
        [string]$DisplayName,
        [string]$NotebookId,
        [string]$NotebookJsonContent,
        [string]$Token
    )
   
    try {
        Write-Host "Updating Fabric notebook ID: $NotebookId in workspace: $WorkspaceId"
       
        # Construct API URL for update definition
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks/$NotebookId/updateDefinition"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Convert notebook content to Base64
        $base64Content = ConvertTo-Base64 -Content $NotebookJsonContent
       
        # Build request body for update
        $body = @{
            definition = @{
                format = "ipynb"
                parts = @(
                    @{
                        path = "notebook-content.ipynb"
                        payload = $base64Content
                        payloadType = "InlineBase64"
                    }
                )
            }
        }
       
        $jsonBody = $body | ConvertTo-Json -Depth 10
        Write-Host "##[debug]Update request body prepared"
       
        # Send POST request to update notebook
        $response = Invoke-FabricApiWithRetry -Uri $apiUrl -Headers $headers -Method POST -Body $jsonBody -MaxRetries 5    
        
        Write-Host "##[debug]Successfully updated notebook ID: $NotebookId"
        return $NotebookId
    }
    catch {
        Write-Error "Failed to update notebook: $_"
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
    Write-Host "##[debug]Starting Ellie notebook creation/update"
    Write-Host "##[debug]Parameters received:"
    Write-Host "##[debug] - WorkspaceId: $WorkspaceId"
    Write-Host "##[debug] - DisplayName: $DisplayName"
    Write-Host "##[debug] - SqlFilePath: $SqlFilePath"
    Write-Host "##[debug] - DefaultLakehouseName: $DefaultLakehouseName"
    Write-Host "##[debug] - Description: $Description"
    Write-Host "##[debug] - FolderId: $FolderId"
   
    # Get Fabric token
    $token = Get-FabricAccessToken -Purpose "Ellie Notebook Management"
    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "Failed to retrieve Fabric access token"
        exit 1
    }
   
    # Determine SQL content source
    $sqlContentToUse = ""
   
    if (-not [string]::IsNullOrEmpty($SqlFilePath)) {
        if (Test-Path $SqlFilePath) {
            Write-Host "##[debug]Reading SQL content from file: $SqlFilePath"
            $sqlContentToUse = Get-Content -Path $SqlFilePath -Raw
        } else {
            Write-Error "SQL file not found: $SqlFilePath"
            exit 1
        }
    } else {
        Write-Error " SqlFilePath must be provided"
        exit 1
    }
   
    if ([string]::IsNullOrEmpty($sqlContentToUse)) {
        Write-Error "SQL content is empty"
        exit 1
    }
   
    Write-Host "##[debug]SQL content loaded successfully (length: $($sqlContentToUse.Length) characters)"
   
    $DefaultLakehouseId = Get-LakehouseIdByName `
        -WorkspaceId $WorkspaceId `
        -Name $DefaultLakehouseName `
        -Token $token

    # Generate notebook JSON content
    Write-Host "##[section]Generating notebook content..."
    $notebookJson = New-NotebookJsonContent `
        -SqlContent $sqlContentToUse `
        -DefaultLakehouseName $DefaultLakehouseName `
        -DefaultLakehouseId $DefaultLakehouseId `
        -WorkspaceId $WorkspaceId
   
    # Check if notebook already exists
    Write-Host "##[debug]Checking if notebook already exists..."
    $existingNotebookId = Get-NotebookIdByName `
        -WorkspaceId $WorkspaceId `
        -NotebookName $DisplayName `
        -Token $token
   
    if ($null -ne $existingNotebookId) {
        Write-Host "##[section]Notebook '$DisplayName' already exists (ID: $existingNotebookId)"
        Write-Host "##[section]Updating existing notebook..."
       
        $notebookId = Update-FabricNotebook `
            -WorkspaceId $WorkspaceId `
            -DisplayName $DisplayName `
            -NotebookId $existingNotebookId `
            -NotebookJsonContent $notebookJson `
            -Token $token
       
        Write-Host "##[section] Notebook updated successfully"
        Write-Host "Notebook ID: $notebookId"

        return $notebookId
    } else {
        Write-Host "##[section]Creating new notebook..."
       
        $notebookId = New-FabricNotebook `
            -WorkspaceId $WorkspaceId `
            -DisplayName $DisplayName `
            -NotebookJsonContent $notebookJson `
            -Description $Description `
            -FolderId $FolderId `
            -Token $token
       
        Write-Host "##[section] Notebook created successfully"
        Write-Host "Notebook ID: $notebookId"
        Write-Host "Display Name: $DisplayName"

        return $notebookId
    }
   
    Write-Host "Ellie notebook operation completed successfully"
}
catch {
    Write-Error "Error in Ellie notebook operation: $_"
    exit 1
}