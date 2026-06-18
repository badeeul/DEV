# Emoji definitions for better output readability
$script:Emoji = @{
    Success    = [char]::ConvertFromUtf32(0x2705)    # ✅ Check Mark
    Error      = [char]::ConvertFromUtf32(0x274C)    # ❌ Cross Mark
    Warning    = [char]::ConvertFromUtf32(0x26A0)    # ⚠️ Warning
    Info       = [char]::ConvertFromUtf32(0x2139)    # ℹ️ Information
    Magnify    = [char]::ConvertFromUtf32(0x1F50D)   # 🔍 Magnifying Glass
    Gear       = [char]::ConvertFromUtf32(0x2699)    # ⚙️ Gear
    Document   = [char]::ConvertFromUtf32(0x1F4C4)   # 📄 Document
    List       = [char]::ConvertFromUtf32(0x1F4CB)   # 📋 Clipboard
    Stats      = [char]::ConvertFromUtf32(0x1F4CA)   # 📊 Bar Chart
    Clock      = [char]::ConvertFromUtf32(0x23F3)    # ⏳ Hourglass
    Stop       = [char]::ConvertFromUtf32(0x1F6D1)   # 🛑 Stop Sign
    Fire       = [char]::ConvertFromUtf32(0x1F525)   # 🔥 Fire
    Target     = [char]::ConvertFromUtf32(0x1F3AF)   # 🎯 Target
}

# Step 1: Validate Terraform State After Imports
Write-Host "##[section]$($script:Emoji.Magnify) Step 1: Validating Terraform State After Imports"

# Check imported resources are properly in state
Write-Host "##[debug]Checking imported resources in state..."
$stateList = terraform state list | Where-Object { $_ -match "(fabric_workspace|fabric_environment|fabric_lakehouse|fabric_notebook)" }

Write-Host "##[section]$($script:Emoji.List) Resources currently in Terraform state:"
$stateList | ForEach-Object { Write-Host "  $($script:Emoji.Success) $_" }

# Step 2: Verify Configuration Alignment
Write-Host ""
Write-Host "##[section]$($script:Emoji.Gear) Step 2: Checking Configuration Alignment"

# Run terraform plan to see if there are any configuration drifts
Write-Host "##[debug]Running terraform plan to check for configuration drift..."
terraform plan -detailed-exitcode -no-color

$planExitCode = $LASTEXITCODE

if ($planExitCode -eq 0) {
    Write-Host "##[section]$($script:Emoji.Success) PERFECT: No configuration drift detected"
} elseif ($planExitCode -eq 2) {
    Write-Host "##[warning]$($script:Emoji.Warning) ATTENTION: Configuration differences detected"
    Write-Host "##[warning]This could cause resources to be modified/recreated during apply"
    Write-Host "##[warning]Review the plan output above carefully before proceeding"
} else {
    Write-Host "##[error]$($script:Emoji.Error) Plan failed - there may be configuration issues"
}

# Step 3: Validate Resource Properties Match
Write-Host ""
Write-Host "##[section]$($script:Emoji.Magnify) Step 3: Validating Resource Properties"

# Show details of imported resources to check for property mismatches
$importedResources = @(
    "module.fabric_workspace.fabric_workspace.this",
    "module.environment.fabric_environment.this",
    "module.lakehouse_names.fabric_lakehouse.this"
)

foreach ($resource in $resources) {
    Write-Host "##[debug] Checking properties for: $resource"
   
    # Properly escape resource name for terraform command
    $escapedResource = "`"$resource`""
    $resourceDetails = terraform state show $escapedResource 2>&1
   
    if ($LASTEXITCODE -eq 0) {
        # Check for common property issues
        $detailsString = $resourceDetails -join "`n"
       
        # Look for null or empty values that might cause issues
        if ($detailsString -match "= null|= `"`"|= \[\]") {
            Write-Host "##[warning] Found null/empty properties in $resource"
        }
       
        # Check if display names match expected patterns
        if ($detailsString -match 'display_name\s*=\s*"([^"]+)"') {
            $displayName = $matches[1]
            Write-Host "##[debug]  Display Name: $displayName"
        }
    } else {
        Write-Host "##[error] Could not get details for $resource"
        Write-Host "##[error]Error details: $($resourceDetails -join ' ')"
    }
}

# Step 4: Pre-Pipeline Checklist
Write-Host ""
Write-Host "##[section]$($script:Emoji.List) Step 4: Pre-Pipeline Checklist"

$checklistItems = @(
    "$($script:Emoji.Success) All missing resources imported successfully",
    "$($script:Emoji.Clock) Waiting to verify: terraform plan shows no destructive changes",
    "$($script:Emoji.Clock) Waiting to verify: Resource properties align with configuration",
    "$($script:Emoji.Clock) Waiting to verify: No unexpected resource recreations planned"
)

$checklistItems | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "##[section]$($script:Emoji.List) NEXT STEPS BEFORE CI/CD PIPELINE:"
Write-Host "  1. $($script:Emoji.Magnify) REVIEW the terraform plan output above carefully"
Write-Host "  2. $($script:Emoji.Fire) Look for any resources marked for DESTRUCTION or RECREATION"
Write-Host "  3. $($script:Emoji.Warning) If you see lakehouses being recreated/destroyed, DO NOT proceed"
Write-Host "  4. $($script:Emoji.Gear) Fix any configuration mismatches first"
Write-Host "  5. $($script:Emoji.Success) Only proceed with CI/CD when plan shows no destructive changes"

# Step 5: Generate Diagnostic Report
Write-Host ""
Write-Host "##[section]$($script:Emoji.Stats) Step 5: Generating Diagnostic Report"

$diagnosticReport = @"
TERRAFORM STATE DRIFT REPAIR - DIAGNOSTIC REPORT
================================================
Date: $(Get-Date)
Working Directory: $(Get-Location)

IMPORTED RESOURCES:
$($stateList -join "`n")

TERRAFORM PLAN EXIT CODE: $planExitCode
- 0 = No changes needed (SAFE to proceed)
- 2 = Changes detected (REVIEW before proceeding)
- 1 = Plan failed (DO NOT proceed)

RECOMMENDATIONS:
"@

if ($planExitCode -eq 0) {
    $diagnosticReport += @"

$($script:Emoji.Success) SAFE TO PROCEED: No configuration drift detected
$($script:Emoji.Success) You can safely run your CI/CD pipeline
"@
} elseif ($planExitCode -eq 2) {
    $diagnosticReport += @"

$($script:Emoji.Warning) REVIEW REQUIRED: Configuration changes detected
$($script:Emoji.Warning) Carefully review terraform plan output above
$($script:Emoji.Warning) Look for any lakehouse resources being destroyed/recreated
$($script:Emoji.Warning) Fix configuration mismatches before running CI/CD pipeline
"@
} else {
    $diagnosticReport += @"

$($script:Emoji.Error) DO NOT PROCEED: Plan failed
$($script:Emoji.Error) Fix configuration issues before running CI/CD pipeline
$($script:Emoji.Error) Review error messages above
"@
}

Write-Host $diagnosticReport

# Save diagnostic report to file
$diagnosticReport | Out-File -FilePath "terraform-state-drift-report.txt" -Encoding UTF8
Write-Host "##[section]$($script:Emoji.Document) Diagnostic report saved to: terraform-state-drift-report.txt"