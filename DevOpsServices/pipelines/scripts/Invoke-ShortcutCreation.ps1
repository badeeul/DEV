param(
    [Parameter(Mandatory=$true)]
    [string]$ConsumerWorkspaceName,
   
    [Parameter(Mandatory=$true)]
    [string]$ConsumerLakehouseName,
   
    [Parameter(Mandatory=$true)]
    [string]$ShortcutName,

    [Parameter(Mandatory=$true)]
    [string]$ShortcutPath,
   
    [Parameter(Mandatory=$true)]
    [string]$TargetWorkspaceName,
   
    [Parameter(Mandatory=$true)]
    [string]$TargetLakehouseName,
   
    [Parameter(Mandatory=$true)]
    [string]$TargetPath
)

function Cleanup-Shortcuts {
    param(
        [string]$WorkspaceId,
        [string]$LakehouseId,
        [array]$ValidShortcutNames,
        [string]$TargetPath,
        [string]$Token
    )
   
    try {
        Write-Host "##[debug]Starting cleanup of shortcuts that are no longer defined in variables"
       
        # List existing shortcuts
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$LakehouseId/shortcuts"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to list shortcuts
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
        $existingShortcuts = $response.value
       
        Write-Host "##[debug]Found $($existingShortcuts.Count) existing shortcuts"
        $validShortcutNames = $($ValidShortcutNames -join ', ')
        Write-Host "##[debug]ValidShortcutNames: $validShortcutNames"
       

        # Identify shortcuts to delete (those not in ValidShortcutNames)
        foreach ($shortcut in $existingShortcuts) {
            if ($ValidShortcutNames -notcontains $shortcut.name) {
                Write-Host "##[debug]Deleting shortcut '$($shortcut.name)' as it's not in the defined shortcuts"
               
                # Format the path correctly - first remove leading slash if present
                $pathWithoutLeadingSlash = $($shortcut.path) -replace '^/', ''
               
                # For the Fabric API, we need to URL encode each path segment separately
                $pathSegments = $pathWithoutLeadingSlash -split '/'
                $encodedPathSegments = $pathSegments | ForEach-Object {
                    [System.Web.HttpUtility]::UrlEncode($_)
                }
               
                # Join them back with encoded slashes
                $encodedPath = $encodedPathSegments -join '%2F'
               
                # Encode the shortcut name
                $encodedName = [System.Web.HttpUtility]::UrlEncode($shortcut.name)

                # Construct API URL for deleting the shortcut with encoding in mind
                $deleteUrl = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$LakehouseId/shortcuts/$encodedPath/$encodedName"

                Write-Host "##[debug]Delete URL: $deleteUrl"
               
                # Send request to delete shortcut
                try {
                    Invoke-RestMethod -Uri $deleteUrl -Method DELETE -Headers $headers
                    Write-Host "##[debug]Successfully deleted shortcut '$($shortcut.name)'"
                }
                catch {
                    Write-Warning "Failed to delete shortcut '$($shortcut.name)': $_"
                }
            }
            else {
                Write-Host "##[debug]Keeping shortcut '$($shortcut.name)' as it's in the defined shortcuts"
            }
        }
       
        Write-Host "##[debug]Cleanup completed"
    }
    catch {
        Write-Error "Error during cleanup of shortcuts: $_"
    }
}

function Get-WorkspaceIdByName {
    param(
        [string]$Name,
        [string]$Token
    )
   
    try {
        Write-Host "Looking up workspace ID for workspace name: $Name"
       
        # Construct API URL to get all workspaces
        $apiUrl = "https://api.fabric.microsoft.com/v1/workspaces"
       
        # Set up headers with auth token
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
       
        # Send request to get all workspaces
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
       
        # Iterate through workspaces to find matching display name
        $matchingWorkspace = $response.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingWorkspace) {
            Write-Error "No workspace found with name: $Name"
            exit 1
        }
       
        $workspaceId = $matchingWorkspace.id
        Write-Host "Found workspace ID: $workspaceId for workspace name: $Name"
        return $workspaceId
    }
    catch {
        Write-Error "Failed to get workspace ID: $_"
        exit 1
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
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET

        # Iterate through workspaces to find matching display name
        $matchingLakehouse = $response.value | Where-Object { $_.displayName -eq $Name }
       
        if ($null -eq $matchingLakehouse) {
            Write-Error "No lakehouse found with name: $Name"
            exit 1
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

# Main execution
try {
    Write-Host "##[debug]Starting shortcut creation process for $ShortcutName"
    Write-Host "##[debug]Consumer: $ConsumerWorkspaceName/$ConsumerLakehouseName"
    Write-Host "##[debug]Target: $TargetWorkspaceName/$TargetLakehouseName"
    Write-Host "##[debug]Path: $ShortcutPath -> $TargetPath"
   
    # Get Fabric token
    $token = $env:FABRIC_TOKEN
   
    # Lookup consumer workspace ID (where the shortcut will be created)
    $consumerWorkspaceId = Get-WorkspaceIdByName -Name $ConsumerWorkspaceName -Token $token
   
    # Lookup consumer lakehouse ID (where the shortcut will be created)
    $consumerLakehouseId = Get-LakehouseIdByName -WorkspaceId $consumerWorkspaceId -Name $ConsumerLakehouseName -Token $token
   
    # Lookup target workspace ID
    $targetWorkspaceId = Get-WorkspaceIdByName -Name $TargetWorkspaceName -Token $token
   
    # Lookup target lakehouse ID
    $targetLakehouseId = Get-LakehouseIdByName -WorkspaceId $targetWorkspaceId -Name $TargetLakehouseName -Token $token
   
    # Get valid shortcut names from environment variable (set by Terraform)
    # $validShortcutNames = $env:VALID_SHORTCUT_NAMES
    # if ($validShortcutNames) {
    #     $validShortcutNamesArray = $validShortcutNames -split ','
       
    #     # Perform cleanup of shortcuts not in the list
    #     Cleanup-Shortcuts -WorkspaceId $consumerWorkspaceId -LakehouseId $consumerLakehouseId -ValidShortcutNames $validShortcutNamesArray -TargetPath $TargetPath -Token $token
    # }
   
    Write-Host "##[debug]Calling Create-LakehouseShortcut.ps1 with resolved IDs"
   
    # Call the actual shortcut creation script
    & "$PSScriptRoot\Create-LakehouseShortcut.ps1" `
        -WorkspaceId $consumerWorkspaceId `
        -LakehouseId $consumerLakehouseId `
        -ShortcutName $ShortcutName `
        -ShortcutPath $ShortcutPath `
        -TargetItemId $targetLakehouseId `
        -TargetWorkspaceId $targetWorkspaceId `
        -TargetPath $TargetPath
       
    Write-Host "##[debug]Shortcut creation process completed successfully"
}
catch {
    Write-Error "Error in shortcut creation process: $_"
    exit 1
}