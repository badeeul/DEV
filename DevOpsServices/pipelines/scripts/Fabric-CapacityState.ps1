
function Get-FabricCapacities {
    param (
        [string]$ContinuationToken = $null
    )

    $allCapacities = @()
    $baseUrl = "https://api.fabric.microsoft.com/v1/capacities"
   
    do {
        try {
            # Build URL with continuation token if provided
            if ($ContinuationToken) {
                $capacitiesUrl = "$baseUrl" + "?continuationToken=$ContinuationToken"
            } else {
                $capacitiesUrl = $baseUrl
            }
           
            Write-Host "##[debug]`tFetching capacities from: $capacitiesUrl"
           
            $response = Invoke-RestMethod -Uri $capacitiesUrl -Headers $global:auth_header -Method GET
           
            if ($response.value -and $response.value.Count -gt 0) {
                $allCapacities += $response.value
                Write-Host "##[debug]`t`tFound $($response.value.Count) capacities in this batch"
            }
           
            # Check for continuation token in response
            $ContinuationToken = $null
            if ($response.PSObject.Properties['continuationToken'] -and $response.continuationToken) {
                $ContinuationToken = $response.continuationToken
                Write-Host "##[debug]`t`tContinuation token found, fetching next batch..."
            }
           
        } catch {
            Write-Error "`t`tError fetching Fabric capacities: $($_.Exception.Message)"
            if ($_.Exception.Response) {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                Write-Error "`t`tResponse Body: $responseBody"
            }
            break
        }
       
    } while ($ContinuationToken)
   
    Write-Host "##[debug]`tTotal capacities retrieved: $($allCapacities.Count)"
    return $allCapacities
}

##################################
# Function to Check if Specific Capacity is Active
##################################
function Test-FabricCapacityState {
    param (
        [string]$CapacityId,
        [string]$ExpectedState = "Active"
    )
   
    if ([string]::IsNullOrEmpty($CapacityId)) {
        Write-Error "CapacityId parameter is required"
        return $false
    }
   
    try {
        Write-Host "##[debug]`tChecking capacity state for ID: $CapacityId"
       
        # Get all capacities (could optimize to get specific capacity if API supports it)
        $capacities = Get-FabricCapacities
       
        # Find the specific capacity
        $targetCapacity = $capacities | Where-Object { $_.id -eq $CapacityId }
       
        if ($null -eq $targetCapacity) {
            Write-Host "##[debug]`t`tCapacity with ID '$CapacityId' not found" -ForegroundColor Yellow
            return $false
        }
       
        Write-Host "##[debug]`t`tFound capacity: $($targetCapacity.displayName)"
        Write-Host "##[debug]`t`tSKU: $($targetCapacity.sku)"
        Write-Host "##[debug]`t`tRegion: $($targetCapacity.region)"
        Write-Host "##[debug]`t`tCurrent State: $($targetCapacity.state)"
       
        $isExpectedState = $targetCapacity.state -eq $ExpectedState
       
        if ($isExpectedState) {
            Write-Host "##[debug]`t`tCapacity is in expected state: $ExpectedState" -ForegroundColor Green
        } else {
            Write-Host "##[debug]`t`tCapacity is NOT in expected state. Expected: $ExpectedState, Actual: $($targetCapacity.state)" -ForegroundColor Red
        }
       
        return $isExpectedState
       
    } catch {
        Write-Error "`t`tError checking capacity state: $($_.Exception.Message)"
        return $false
    }
}

function Show-FabricCapacities {
    param (
        [string]$FilterState = $null
    )
   
    try {
        Write-Host "##[debug]`tRetrieving all Fabric capacities..."
        $capacities = Get-FabricCapacities
       
        if ($capacities.Count -eq 0) {
            Write-Host "##[debug]`t`tNo capacities found" -ForegroundColor Yellow
            return
        }
       
        # Apply state filter if specified
        if (![string]::IsNullOrEmpty($FilterState)) {
            $capacities = $capacities | Where-Object { $_.state -eq $FilterState }
            Write-Host "##[debug]`t`tFiltered to show only '$FilterState' capacities: $($capacities.Count) found"
        }
       
        # Display formatted table
        Write-Host "##[debug]`n===================================================================================================="
        Write-Host "##[debug]FABRIC CAPACITIES SUMMARY"
        Write-Host "##[debug]===================================================================================================="
       
        $capacities | Format-Table -Property @(
            @{Name="Display Name"; Expression={$_.displayName}; Width=40},
            @{Name="ID"; Expression={$_.id}; Width=36},
            @{Name="SKU"; Expression={$_.sku}; Width=8},
            @{Name="Region"; Expression={$_.region}; Width=15},
            @{Name="State"; Expression={$_.state}; Width=10}
        ) -AutoSize
       
        # Summary statistics
        $stateGroups = $capacities | Group-Object -Property state
        Write-Host "##[debug]STATE SUMMARY:"
        $stateGroups | ForEach-Object {
            $color = if ($_.Name -eq "Active") { "Green" } else { "Yellow" }
            Write-Host "##[debug]`t$($_.Name): $($_.Count)" -ForegroundColor $color
        }
       
        Write-Host "##[debug]===================================================================================================="
       
    } catch {
        Write-Error "`t`tError displaying capacities: $($_.Exception.Message)"
    }
}

##################################
# Main Execution Functions
##################################

# Initialize authentication header
function Initialize-FabricAuth {
    param (
        [string]$FabricToken
    )
   
    if ([string]::IsNullOrEmpty($FabricToken)) {
        $FabricToken = $env:FABRIC_TOKEN
    }
   
    if ([string]::IsNullOrEmpty($FabricToken)) {
        Write-Error "Fabric token is required. Set FABRIC_TOKEN environment variable or pass as parameter."
        exit 1
    }
   
    $global:auth_header = @{
        'Content-Type' = "application/json"
        'Authorization' = "Bearer $FabricToken"
    }
   
    Write-Host "##[debug]Fabric authentication initialized successfully"
}

# Parameters - can be set via environment variables or passed directly
$FabricToken = $env:FABRIC_TOKEN
$TargetCapacityId = $env:TF_VAR_capacity_id  # Optional: specific capacity to check

# Initialize authentication
Initialize-FabricAuth -FabricToken $FabricToken

try {
    # Show all capacities
    Show-FabricCapacities
    
    # Check specific capacity if ID provided
    if (![string]::IsNullOrEmpty($TargetCapacityId)) {
        Write-Output "`nCHECKING SPECIFIC CAPACITY"
        Write-Output "Target Capacity ID: $TargetCapacityId"
        
        $isActive = Test-FabricCapacityState -CapacityId $TargetCapacityId -ExpectedState "Active"
        
        if ($isActive) {
            exit 0
        } else {
            exit 1
        }
    }
    
} catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    exit 1
}


