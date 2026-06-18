param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory=$true)]
    [string]$LakehouseId,
   
    [Parameter(Mandatory=$true)]
    [string]$ShortcutName,
   
    [Parameter(Mandatory=$true)]
    [string]$ShortcutPath,
   
    [Parameter(Mandatory=$true)]
    [string]$TargetItemId,
   
    [Parameter(Mandatory=$true)]
    [string]$TargetWorkspaceId,
   
    [Parameter(Mandatory=$true)]
    [string]$TargetPath,
   
    [Parameter(Mandatory=$false)]
    [string]$Token = $null
)

function Get-Shortcuts {
    param (
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Listing shortcuts in lakehouse $LakehouseId"
       
        # Construct API URL for shortcuts
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$LakehouseId/shortcuts"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        Write-Host "##[debug]Sending GET request to $apiUrl"
       
        # Send request to list shortcuts
        $response = Invoke-RestMethod -Uri $apiUrl -Method GET -Headers $headers
       
        Write-Host "##[debug]Retrieved $(($response.value).Count) shortcuts"
        return $response.value
    }
    catch {
        Write-Error "Failed to list shortcuts: $_"
        Write-Error "Status code: $($_.Exception.Response.StatusCode.value__)"
        if ($_.ErrorDetails.Message) {
            Write-Error "Response: $($_.ErrorDetails.Message)"
        }
        exit 1
    }
}

function Remove-Shortcut {
    param (
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$ShortcutPath,
        [string]$ShortcutName,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Deleting shortcut '$ShortcutName' from path '$ShortcutPath' in lakehouse $LakehouseId"
       
        # Format the path correctly - first remove leading slash if present
        $pathWithoutLeadingSlash = $ShortcutPath -replace '^/', ''
        
        # For the Fabric API, we need to URL encode each path segment separately
        $pathSegments = $pathWithoutLeadingSlash -split '/'
        $encodedPathSegments = $pathSegments | ForEach-Object {
            [System.Web.HttpUtility]::UrlEncode($_)
        }
        
        # Join them back with encoded slashes
        $encodedPath = $encodedPathSegments -join '%2F'
        
        # Encode the shortcut name
        $encodedName = [System.Web.HttpUtility]::UrlEncode($ShortcutName)
       
        # Construct API URL for deleting the shortcut
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$LakehouseId/shortcuts/$encodedPath/$encodedName"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        Write-Host "##[debug]Sending DELETE request to $apiUrl"
       
        # Send request to delete shortcut
        $response = Invoke-RestMethod -Uri $apiUrl -Method DELETE -Headers $headers
       
        Write-Host "##[debug]Shortcut deleted successfully!"
        return $response
    }
    catch {
        # Check if the error is a 404 (shortcut doesn't exist)
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Host "##[debug]Shortcut '$ShortcutName' does not exist. Skipping deletion."
        }
        else {
            Write-Error "Failed to delete shortcut: $_"
            Write-Error "Status code: $($_.Exception.Response.StatusCode.value__)"
            if ($_.ErrorDetails.Message) {
                Write-Error "Response: $($_.ErrorDetails.Message)"
            }
            exit 1
        }
    }
}


function Create-Shortcut {
    param (
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [string]$ShortcutName,
        [string]$ShortcutPath,
        [string]$TargetItemId,
        [string]$TargetWorkspaceId,
        [string]$TargetPath,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Creating shortcut '$ShortcutName' in lakehouse $LakehouseId"
        Write-Host "##[debug]Path: $ShortcutPath, Target: $TargetPath"
        Write-Host "##[debug]Target Item ID: $TargetItemId, Target Workspace ID: $TargetWorkspaceId"
       
        # Construct API URL for shortcuts
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$LakehouseId/shortcuts"
       
        # Construct request body
        $body = @{
            name = $ShortcutName
            path = $ShortcutPath
            target = @{
                type = "OneLake"
                oneLake = @{
                    path = $TargetPath
                    itemId = $TargetItemId
                    workspaceId = $TargetWorkspaceId
                }
            }
        } | ConvertTo-Json -Depth 10
       
        Write-Host "##[debug]Request body: $body"
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        Write-Host "##[debug]Sending request to $apiUrl"
       
        # Send request to create shortcut
        $response = Invoke-RestMethod -Uri $apiUrl -Method POST -Headers $headers -Body $body
       
        Write-Host "##[debug]Shortcut created successfully!"
        return $response
    }
    catch {
        # Check if the error is a 409 conflict (shortcut already exists)
        if ($_.Exception.Response.StatusCode -eq 409) {
            Write-Host "##[debug]Shortcut '$ShortcutName' already exists. Skipping creation."
        }
        else {
            Write-Error "Failed to create shortcut: $_"
            Write-Error "Status code: $($_.Exception.Response.StatusCode.value__)"
            if ($_.ErrorDetails.Message) {
                Write-Error "Response: $($_.ErrorDetails.Message)"
            }
            exit 1
        }
    }
}

# Main execution
try {

    $fabricToken = $env:FABRIC_TOKEN

    # sleep 10 seconds to ensure the shortcut is deleted before creating a new one
    Start-Sleep -Seconds 10

    # Create the shortcut
    Create-Shortcut -WorkspaceId $WorkspaceId -LakehouseId $LakehouseId -ShortcutName $ShortcutName -ShortcutPath $ShortcutPath -TargetItemId $TargetItemId -TargetWorkspaceId $TargetWorkspaceId -TargetPath $TargetPath -Token $fabricToken
}
catch {
    Write-Error "Error in script execution: $_"
    exit 1
}
