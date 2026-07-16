param(
    [Parameter(Mandatory=$true)][string]$AzSubscriptionId,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$SFTPStorageAccountName,
    [Parameter(Mandatory=$true)][string]$SFTPContainerName
)

try {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $configPath = Join-Path $scriptDir '..\sftp_config\adls-sftp-config.json'
    $resolved = Resolve-Path -Path $configPath -ErrorAction Stop
    $configJson = Get-Content -Raw -Path $resolved.Path | ConvertFrom-Json
} catch {
    Write-Error "Failed to load SFTP config file: $_"
    exit 1
}

$folders = @()
foreach ($f in $configJson.folders) {
    $folders += [pscustomobject]@{
        Partner   = $f.partner
        SubFolders = $f.subFolders
    }
}
 
# -------------------- Authenticate & context --------------------
function Get-AzStorageContextWithSPN {
    try {
        if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
            Install-Module -Name Az.Accounts -Force -Scope CurrentUser
        }
        if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
            Install-Module -Name Az.Storage -Force -Scope CurrentUser
        }

        $secureSecret = ConvertTo-SecureString $env:ARM_CLIENT_SECRET -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential(
            $env:ARM_CLIENT_ID, $secureSecret)

        # Connect to Azure using service principal
        Write-Host "Authenticating to Azure as service principal..."
        Connect-AzAccount -ServicePrincipal -Tenant $env:ARM_TENANT_ID -Credential $credential -Subscription $AzSubscriptionId | Out-Null

        # Get context for Azure operations
        Write-Host "Setting Az context to subscription $AzSubscriptionId"
        Set-AzContext -Subscription $AzSubscriptionId | Out-Null

        Write-Host "Creating storage context for account '$SFTPStorageAccountName'..."
        $storageContext = New-AzStorageContext -StorageAccountName $SFTPStorageAccountName -UseConnectedAccount

        if ($null -eq $storageContext) {
            Write-Host "Warning: New-AzStorageContext returned null or empty." -ForegroundColor Yellow
        }

        if ($storageContext -is [System.Array]) {
            Write-Host "Multiple storage contexts returned; selecting the first entry." -ForegroundColor Yellow
            $storageContext = $storageContext[0]
        }

        Write-Host "Storage context created (type: $($storageContext.GetType().FullName))."
        return $storageContext
    }
    catch {
        Write-Error "Failed to authenticate for Azure operations: $_"
        throw
    }
}

$context = Get-AzStorageContextWithSPN
if ($context -is [System.Array]) {
    Write-Host "Top-level guard: context is an array; selecting first element." -ForegroundColor Yellow
    $context = $context[0]
}
Write-Host "Obtained storage context type: $($context.GetType().FullName)"

try {
    Write-Host "Checking for existing DataLake Gen2 file system '$SFTPContainerName'..."
    $fs = Get-AzDataLakeGen2FileSystem -Context $context -Name $SFTPContainerName -ErrorAction Stop
    Write-Host "Successfully connected to file system '$SFTPContainerName' in storage account '$SFTPStorageAccountName'."
} catch {
    Write-Host "File system '$SFTPContainerName' not found or error occurred: $($_.Exception.Message)" -ForegroundColor Yellow
    try {
        Write-Host "Creating file system '$SFTPContainerName' in storage account '$SFTPStorageAccountName'..."
        $fs = New-AzDataLakeGen2FileSystem -Context $context -Name $SFTPContainerName -ErrorAction Stop
        Write-Host "Successfully created file system '$SFTPContainerName'."
    } catch {
        Write-Error "Failed to create file system '$SFTPContainerName': $($_.Exception.Message)"
        throw
    }
}

# -------------------- Helper: Test if a Gen2 path exists --------------------
function Test-Gen2PathExists {
    param(
        [Parameter(Mandatory=$true)][string]$FileSystem,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Context
    )
    try {
        Write-Host "Testing existence of path: $FileSystem/$Path"
        $null = Get-AzDataLakeGen2Item -FileSystem $FileSystem -Path $Path -Context $Context -ErrorAction Stop
        return $true
    } catch {
        Write-Host "Path not found or error checking path: $FileSystem/$Path - $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $false
    }
}
 
# -------------------- Build expected paths --------------------
Function Set-ExpectedPaths {
    param(
        $Folder,
        $ParentPath
    )
    $currentPath = if ($ParentPath) { "$ParentPath/$($Folder.Name)" } else { $($Folder.Partner) }
    Write-Host "Adding expected path: $currentPath for partner '$($Folder.Partner)'" -ForegroundColor Cyan

    $expectedPaths.Add([pscustomobject]@{
            Partner    = $Folder.Partner
            ParentPath = $ParentPath
            Path       = $currentPath
        })


    if ($Folder.SubFolders) {
        foreach ($sub in $Folder.SubFolders) {
            Set-ExpectedPaths -Folder $sub -ParentPath $currentPath
        }
    }
}

$expectedPaths = New-Object System.Collections.Generic.List[pscustomobject]
 
foreach ($folder in $folders) {
    Set-ExpectedPaths -Folder $folder -ParentPath ""
}

$expectedPaths | ForEach-Object { Write-Host "Expected path: $($_.Path) for partner '$($_.Partner)'" -ForegroundColor Gray }

# -------------------- Create directories (pre-check + try/catch) --------------------
foreach ($item in $expectedPaths) {
    $path = $item.Path
 
    # Skip if already exists
    if (Test-Gen2PathExists -FileSystem $SFTPContainerName -Path $path -Context $context) {
        Write-Host "Exists: $path (skipping)"
        continue
    }
 
    # Attempt creation
    try {
        Write-Host "Creating: $path"
        New-AzDataLakeGen2Item -FileSystem $SFTPContainerName -Path $path -Directory -Context $context -ErrorAction Stop | Out-Null
        Write-Host "Created: $path"
    } catch {
        $msg = $_.Exception.Message
        # Handle race conditions where the path was created after the pre-check
        if ($msg -match 'PathAlreadyExists|already exists|ResourceAlreadyExists|409') {
            Write-Host "Exists (race): $path (skipping)"
        } else {
            Write-Warning "Failed to create '$path': $msg"
        }
    }
}
 
# -------------------- Verification pass --------------------
$missing = @()
foreach ($item in $expectedPaths) {
    if (-not (Test-Gen2PathExists -FileSystem $SFTPContainerName -Path $item.Path -Context $context)) {
        $missing += $item
    }
}
 
Write-Host ""
Write-Host "===== Verification Summary =====" -ForegroundColor Cyan
Write-Host ("Total expected directories : {0}" -f $expectedPaths.Count)
Write-Host ("Missing directories        : {0}" -f $missing.Count)
 
if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Warning "The following directories are missing:"
    $missing | Sort-Object Partner, Folder, Path | Format-Table Partner, Folder, Path -AutoSize
} else {
    Write-Host "All expected directories were created and verified." -ForegroundColor Green
}
 
Write-Host ""
Write-Host "Folder structure creation and verification complete."