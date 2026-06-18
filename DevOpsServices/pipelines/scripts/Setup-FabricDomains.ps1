function Get-FabricDomains {
    param (
        [string]$token
    )
    Write-Host "##[debug]Getting domains..."

    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }
   
    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.fabric.microsoft.com/v1/admin/domains" `
            -Method Get `
            -Headers $headers
       
        return $response.domains
    }
    catch {
        Write-Error "##[debug]Failed to get domains: $_"
        throw
    }
}

function New-FabricDomain {
    
    param (
        [string]$token,
        [string]$displayName,
        [string]$parentDomainId = $null
    )
    Write-Host "##[debug]Creating domain..."
    Write-Host "##[debug]Parent domain ID: $parentDomainId"
    Write-host "##[debug]Display name: $displayName"

    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }
   
    $body = @{
        displayName = $displayName
    }
   
    if ($parentDomainId) {
        $body.parentDomainId = $parentDomainId
    }
   
    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.fabric.microsoft.com/v1/admin/domains" `
            -Method Post `
            -Headers $headers `
            -Body ($body | ConvertTo-Json)
       
        return $response
    }
    catch {
        Write-Error "##[debug]Failed to create domain: $_"
        throw
    }
}

function Add-WorkspacesToDomain {
   
    param (
        [string]$token,
        [string]$domainId,
        [string[]]$workspaceIds
    )
    Write-Host "##[debug]Assigning workspaces..."
    Write-Host "##[debug]Domain ID: $domainId"

    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }
   
    $body = @{
        workspacesIds = $workspaceIds
    }
   
    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.fabric.microsoft.com/v1/admin/domains/$domainId/assignWorkspaces" `
            -Method Post `
            -Headers $headers `
            -Body ($body | ConvertTo-Json)
       
        return $response
    }
    catch {
        Write-Error "##[debug]Failed to assign workspaces: $_"
        throw
    }
}

function Add-DomainRoleAssignments {
    param (
        [string]$token,
        [string]$domainId,
        [array]$principalIds,
        [string]$roleType = "Admins"
    )
    Write-Host "##[debug]Assigning domain roles..."
    Write-Host "##[debug]Domain ID: $domainId"
    Write-Host "##[debug]Role Type: $roleType"

    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }

    $principalIds = @(
        $principalIds | ForEach-Object {
            @{
                id = $_
                type = "Group"
            }
        }
    )

    $body = @{
        type = "Admins"
        principals = $principalIds
    }

    Write-host "Checking body..."
    Write-Host "##[debug]Body: $($body | ConvertTo-Json -Depth 10)"

    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.fabric.microsoft.com/v1/admin/domains/$domainId/roleAssignments/bulkAssign" `
            -Method Post `
            -Headers $headers `
            -Body ($body | ConvertTo-Json -Depth 10)

        Write-Host "##[debug]Role assignments created successfully"
        return $response
    }
    catch {
        Write-Error "##[debug]Failed to assign roles: $_"        
    }
}

# Main script
try {
    # Parameters
    $token = $env:FABRIC_TOKEN
    $parentDomainName = $env:PARENT_DOMAIN_NAME
    $childDomainName = $env:CHILD_DOMAIN_NAME
    $workspaceIds = $env:WORKSPACE_IDS | ConvertFrom-Json
    
    $adminGroupPrincipalIds = $env:ADMIN_GROUP_PRINCIPAL_IDS | ConvertFrom-Json

    # Display all parameters
    Write-Host "##[debug]Parameters from Setup-FabricDomains.ps1"
    Write-Host "##[debug]Parent domain name: $parentDomainName"
    Write-Host "##[debug]Child domain name: $childDomainName"
    Write-Host "##[debug]Workspace IDs: $workspaceIds"
    Write-Host "##[debug]Admin Group Principal IDs: $adminGroupPrincipalIds"
    

    # Get existing domains
    Write-Host "##[debug]Getting existing domains..."
    $existingDomains = Get-FabricDomains -token $token
   
    # Check parent domain
    $parentDomain = $existingDomains | Where-Object { $_.displayName -eq $parentDomainName }
    if (-not $parentDomain) {
        Write-Host "##[debug]Creating parent domain..."
        $parentDomain = New-FabricDomain -token $token -displayName $parentDomainName

        # sleep 20 seconds
        Start-Sleep -Seconds 20
    }

    # Assign roles only for newly created parent domain
    if ($adminGroupPrincipalIds) {
        Write-Host "##[debug]Assigning admin roles to parent domain..."
        Add-DomainRoleAssignments -token $token `
                                    -domainId $parentDomain.id `
                                    -principalIds $adminGroupPrincipalIds `
                                    -roleType "Admins"
    }

    Write-Host "Parent domain ID: $($parentDomain.id)"
   
    # Check child domain
    $childDomain = $existingDomains | Where-Object { $_.displayName -eq $childDomainName }
    if (-not $childDomain) {
        Write-Host "##[debug]Creating child domain..."
        $childDomain = New-FabricDomain -token $token -displayName $childDomainName -parentDomainId $parentDomain.id        
    }
    Write-Host "##[debug]Child domain ID: $($childDomain.id)"
   
    # Assign workspaces to child domain
    Write-Host "##[debug]Assigning workspaces to child domain..."
   
    $workspaceIdArray = $workspaceIds.PSObject.Properties.Value
    Add-WorkspacesToDomain -token $token -domainId $childDomain.id -workspaceIds $workspaceIdArray
    
   
    Write-Host "##[debug]Domain setup completed successfully"
}
catch {
    Write-Error "##[debug]Script failed: $_"
    throw
}
