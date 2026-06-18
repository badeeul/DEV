param(
    [Parameter(Mandatory = $true)]
    [string]$PepDetailedJson,
   
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,
   
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,
   
    [Parameter(Mandatory = $false)]
    [bool]$ForceDeletionPPE = $false,
   
    [Parameter(Mandatory = $false)]
    [string]$ScriptBasePath = "."
)

try {
    Write-Host "##[section]Processing Private Endpoint Approvals"
   
    if ([string]::IsNullOrEmpty($PepDetailedJson)) {
        Write-Host "##[warning]No private endpoint configuration found. Skipping private endpoint processing."
        return
    }
   
    if ([string]::IsNullOrEmpty($WorkspaceId)) {
        Write-Host "##[error]Workspace ID not found. Cannot proceed with private endpoint processing."
        exit 1
    }
   
    # Parse the JSON data
    $pepData = $PepDetailedJson | ConvertFrom-Json

    Write-Host "##[debug]Found $($pepData.Count) private endpoint configurations"
    Write-Host "##[debug]Available workspaces: $workspaceId"
   
    Write-Host "##[debug]Processing workspaces: $workspaceName "
   
    # Create private endpoints list similar to Terraform local
    $privateEndpointsList = @()
   
       
    if ([string]::IsNullOrEmpty($workspaceId)) {
        Write-Host "##[warning]Workspace ID not found for workspace: $workspaceName"
        continue
    }
    
    foreach ($pep in $pepData) {
        if ([string]::IsNullOrEmpty($pep.resourceId) -or [string]::IsNullOrEmpty($pep.subresourceType)) {
            Write-Host "##[warning]Skipping invalid PEP configuration - missing resourceId or subresourceType"
            continue
        }
        
        # Extract resource name from resource ID
        $resourceIdParts = $pep.resourceId -split '/'
        $resourceName = $resourceIdParts[-1]
        
        # Create endpoint name (max 64 characters)
        $workspaceNameCleaned = $workspaceName -replace '\s+', '-' -replace '[/\\]', '-'
        $endpointName = "$workspaceNameCleaned-$resourceName"
        if ($endpointName.Length -gt 64) {
            $endpointName = $endpointName.Substring(0, 64)
        }
        
        $privateEndpointsList += [PSCustomObject]@{
            workspace_name       = $workspaceName
            workspace_id         = $workspaceId
            endpoint_name        = $endpointName
            target_resource_id   = $pep.resourceId
            target_subresource   = $pep.subresourceType
            request_message      = "Please approve this Fabric managed private endpoint subresource type $resourceName"
            allowed              = [System.Convert]::ToBoolean($pep.allowed)
            force_deletion_ppe   = $ForceDeletionPPE
        }
    }

   
    if ($privateEndpointsList.Count -eq 0) {
        Write-Host "##[warning]No valid private endpoint configurations to process"
        return
    }
   
    Write-Host "##[info]Processing $($privateEndpointsList.Count) private endpoint requests"
   
    # Set the path to the Create-ManagedPrivateEndpoints.ps1 script
    $managedEndpointsScript = Join-Path $ScriptBasePath "Create-ManagedPrivateEndpoints.ps1"
   
    if (-not (Test-Path $managedEndpointsScript)) {
        Write-Host "##[error]Cannot find Create-ManagedPrivateEndpoints.ps1 at: $managedEndpointsScript"
        exit 1
    }
   
    Write-Host "##[debug]Using script path: $managedEndpointsScript"
   
    # Process each private endpoint sequentially
    foreach ($endpoint in $privateEndpointsList) {
        Write-Host "##[section]Processing endpoint: $($endpoint.endpoint_name) for workspace: $($endpoint.workspace_name)"
       
        try {
            # Determine the action based on allowed flag
            if ($endpoint.allowed -eq $true) {
                Write-Host "##[info]Creating/updating endpoint: $($endpoint.endpoint_name)"
               
                # Prepare parameters for creation/update
                $scriptParams = @{
                    WorkspaceId = $endpoint.workspace_id
                    EndpointName = $endpoint.endpoint_name
                    TargetResourceId = $endpoint.target_resource_id
                    TargetSubresourceType = $endpoint.target_subresource
                    RequestMessage = $endpoint.request_message
                    Verbose = $true
                }
               
                $scriptParams['Delete'] = $endpoint.force_deletion_ppe
               
                Write-Host "##[debug]Executing with parameters:"
                Write-Host "##[debug]  WorkspaceId: $($endpoint.workspace_id)"
                Write-Host "##[debug]  EndpointName: $($endpoint.endpoint_name)"
                Write-Host "##[debug]  TargetResourceId: $($endpoint.target_resource_id)"
                Write-Host "##[debug]  TargetSubresourceType: $($endpoint.target_subresource)"
                Write-Host "##[debug]  ForceDeletion: $($endpoint.force_deletion_ppe)"
               
                # Execute the script
                & $managedEndpointsScript @scriptParams
               
                if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
                    Write-Host "##[info]Successfully processed endpoint: $($endpoint.endpoint_name)"
                } else {
                    Write-Host "##[error]Failed to process endpoint: $($endpoint.endpoint_name). Exit code: $LASTEXITCODE"
                    throw "Private endpoint creation failed for $($endpoint.endpoint_name)"
                }
               
            } else {
                Write-Host "##[info]Deleting endpoint: $($endpoint.endpoint_name) (allowed=false)"
               
                # Prepare parameters for deletion
                $deleteParams = @{
                    WorkspaceId = $endpoint.workspace_id
                    EndpointName = $endpoint.endpoint_name
                    TargetResourceId = $endpoint.target_resource_id
                    TargetSubresourceType = $endpoint.target_subresource
                    RequestMessage = "Delete request - allowed set to false"
                    Delete = $true
                    Verbose = $true
                }
               
                Write-Host "##[debug]Executing deletion for endpoint: $($endpoint.endpoint_name)"
               
                # Execute the script
                & $managedEndpointsScript @deleteParams
               
                if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
                    Write-Host "##[info]Successfully deleted endpoint: $($endpoint.endpoint_name)"
                } else {
                    Write-Host "##[warning]Failed to delete endpoint: $($endpoint.endpoint_name). Exit code: $LASTEXITCODE"
                    # Don't throw error for deletion failures, just warn
                }
            }
           
            # Add a brief pause between endpoints to avoid API rate limiting
            Write-Host "##[debug]Waiting 5 seconds before processing next endpoint..."
            Start-Sleep -Seconds 5
           
        } catch {
            Write-Host "##[error]Error processing endpoint $($endpoint.endpoint_name): $($_.Exception.Message)"
            Write-Host "##[error]Stack trace: $($_.ScriptStackTrace)"
           
            # Decide whether to continue or fail the entire task
            if ($endpoint.allowed -eq $true) {
                # For creation/update failures, fail the task
                throw "Critical error processing private endpoint: $($endpoint.endpoint_name)"
            } else {
                # For deletion failures, continue with warning
                Write-Host "##[warning]Continuing with next endpoint despite deletion failure"
            }
        }
    }
   
    Write-Host "##[section]Private endpoint processing completed successfully"
    Write-Host "##[info]Processed $($privateEndpointsList.Count) private endpoint configurations"
   
} catch {
    Write-Host "##[error]Critical error in private endpoint processing: $($_.Exception.Message)"
    Write-Host "##[error]Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
