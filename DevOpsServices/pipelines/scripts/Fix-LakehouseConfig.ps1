param(
    [Parameter(Mandatory=$false)]
    [string]$TerraformDir = ".",
    [Parameter(Mandatory=$false)]
    [bool]$DryRun = $false
)

# Emoji variables for consistent use throughout the script
$Emojis = @{
    Success = "✅"
    Warning = "⚠️"
    Error = "❌"
    Fix = "🔧"
    Search = "🔍"
    Note = "📝"
    Arrow = "→"
    Checkmark = "✓"
}

function Get-FabricLakehouse {
    param($Token, $WorkspaceId, $LakehouseId)
   
    $headers = @{ 'Authorization' = "Bearer $Token"; 'Content-Type' = 'application/json' }
    $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses/$LakehouseId"
   
    try {
        return Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    } catch {
        return $null
    }
}

function Get-ImportedLakehouses {
    $stateList = terraform state list | Where-Object { $_ -match "fabric_lakehouse\.this\[" }
    $lakehouses = @{}
   
    foreach ($resource in $stateList) {
        $stateOutput = terraform state show "`"$resource`"" 2>$null | Out-String
       
        if ($stateOutput -match 'id\s*=\s*"([^/]+)/([^"]+)"') {
            $workspaceId = $matches[1]
            $lakehouseId = $matches[2]
           
            $currentDisplayName = if ($stateOutput -match 'display_name\s*=\s*"([^"]+)"') { $matches[1] } else { "" }
            $currentWorkspaceId = if ($stateOutput -match 'workspace_id\s*=\s*"([^"]+)"') { $matches[1] } else { "" }
           
            $lakehouses[$resource] = @{
                WorkspaceId = $workspaceId
                LakehouseId = $lakehouseId
                CurrentDisplayName = $currentDisplayName
                CurrentWorkspaceId = $currentWorkspaceId
                ResourceAddress = $resource
            }
        }
    }
   
    return $lakehouses
}

function Fix-LakehouseConfigurations {
    $token = $env:FABRIC_TOKEN
    $importedLakehouses = Get-ImportedLakehouses
    $fixes = @()
   
    foreach ($resource in $importedLakehouses.Keys) {
        $lh = $importedLakehouses[$resource]
        $fabricData = Get-FabricLakehouse -Token $token -WorkspaceId $lh.WorkspaceId -LakehouseId $lh.LakehouseId
       
        if ($fabricData) {
            $issues = @()
           
            # Check display_name mismatch
            if ($lh.CurrentDisplayName -ne $fabricData.displayName) {
                $issues += "display_name: '$($lh.CurrentDisplayName)' $($Emojis.Arrow) '$($fabricData.displayName)'"
            }
           
            # Check workspace_id mismatch  
            if ($lh.CurrentWorkspaceId -ne $lh.WorkspaceId) {
                $issues += "workspace_id: '$($lh.CurrentWorkspaceId)' $($Emojis.Arrow) '$($lh.WorkspaceId)'"
            }
           
            if ($issues.Count -gt 0) {
                # Extract the for_each key from resource address
                if ($resource -match 'fabric_lakehouse\.this\["([^"]+)"\]') {
                    $forEachKey = $matches[1]
                   
                    $fixes += @{
                        Resource = $resource
                        ForEachKey = $forEachKey
                        Issues = $issues
                        CorrectDisplayName = $fabricData.displayName
                        CorrectWorkspaceId = $lh.WorkspaceId
                        CorrectDescription = $fabricData.description ?? ""
                    }
                }
            }
        }
    }
   
    return $fixes
}

function Generate-FixInstructions {
    param($Fixes)
   
    if ($Fixes.Count -eq 0) {
        Write-Host "$($Emojis.Success) No configuration issues found!" -ForegroundColor Green
        return
    }
   
    Write-Host "`n$($Emojis.Fix) Configuration Issues Found:" -ForegroundColor Yellow
   
    $lakehouseMapFixes = @()
    $variableFixes = @()
   
    foreach ($fix in $Fixes) {
        Write-Host "`nResource: $($fix.Resource)" -ForegroundColor Cyan
        Write-Host "Issues: $($fix.Issues -join ', ')" -ForegroundColor Red
        Write-Host "Correct Values:" -ForegroundColor Green
        Write-Host "  display_name: '$($fix.CorrectDisplayName)'" -ForegroundColor Green
        Write-Host "  workspace_id: '$($fix.CorrectWorkspaceId)'" -ForegroundColor Green
       
        # For your for_each structure, the key format is "${workspace_name}-${lakehouse_name}"
        # We need to ensure the lakehouse_name part matches the actual display name
        if ($fix.ForEachKey -match '^(.+)-(.+)$') {
            $workspaceName = $matches[1]
            $currentLakehouseName = $matches[2]
           
            if ($currentLakehouseName -ne $fix.CorrectDisplayName) {
                $lakehouseMapFixes += @{
                    WorkspaceName = $workspaceName
                    CurrentName = $currentLakehouseName
                    CorrectName = $fix.CorrectDisplayName
                    CorrectWorkspaceId = $fix.CorrectWorkspaceId
                }
            }
        }
    }
   
    if ($lakehouseMapFixes.Count -gt 0) {
        Write-Host "`n$($Emojis.Note) FIXES NEEDED:" -ForegroundColor Yellow
        Write-Host "`n1. Update your lakehouse platform files:" -ForegroundColor Cyan
       
        foreach ($fix in $lakehouseMapFixes) {
            Write-Host "   Find platform file with displayName: '$($fix.CurrentName)'" -ForegroundColor Yellow
            Write-Host "   Update to: '$($fix.CorrectName)'" -ForegroundColor Green
        }
       
        Write-Host "`n2. Or update your variables.tf workspace_ids mapping:" -ForegroundColor Cyan
        foreach ($fix in $lakehouseMapFixes) {
            Write-Host "   '$($fix.WorkspaceName)' should map to: '$($fix.CorrectWorkspaceId)'" -ForegroundColor Green
        }
       
        Write-Host "`n3. After fixes, run:" -ForegroundColor Cyan
        Write-Host "   terraform plan" -ForegroundColor White
        Write-Host "   # Should show no drift" -ForegroundColor Gray
    }
}

# Main execution
Push-Location $TerraformDir

try {
    if ($DryRun) {
        Write-Host "$($Emojis.Search) DRY RUN - Analyzing configuration..." -ForegroundColor Cyan
    } else {
        Write-Host "$($Emojis.Fix) Analyzing lakehouse configurations..." -ForegroundColor Cyan
    }
   
    $fixes = Fix-LakehouseConfigurations
    Generate-FixInstructions -Fixes $fixes
   
    if ($fixes.Count -eq 0) {
        exit 0
    } else {
        exit 1
    }
}
finally {
    Pop-Location
}
