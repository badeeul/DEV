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
}
catch {
    Write-Error "Failed to load SFTP config file: $_"
    exit 1
}

$folders = @()
foreach ($f in $configJson.folders) {
    $folders += [pscustomobject]@{
        Partner    = $f.partner
        SubFolders = $f.subFolders
        Users      = $f.users
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
        $azContext = Set-AzContext -Subscription $AzSubscriptionId

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
        return $storageContext, $azContext
    }
    catch {
        Write-Error "Failed to authenticate for Azure operations: $_"
        throw
    }
}

function Set-SftpLocalUser {
    param (
        [string]$StorageAccountName,
        [string]$ResourceGroupName,
        [string]$UserName,
        [string]$HomeDirectory,
        $Context
    )

    try {

        Write-Host "Creating local user '$UserName' for SFTP access..." -ForegroundColor Green
        $storageAccount = Get-AzStorageAccount -ResourceGroupName "$ResourceGroupName" -Name "$SFTPStorageAccountName"
        $permissionScopeBlob = New-AzStorageLocalUserPermissionScope -Permission rw -Service blob -ResourceName $SFTPContainerName
        Set-AzStorageLocalUser -StorageAccount $storageAccount -UserName $UserName -PermissionScope $permissionScopeBlob -HomeDirectory $HomeDirectory -HasSharedKey $false -HasSshKey $false -HasSshPassword $false -DefaultProfile $Context 
        Write-Host "Successfully created local user '$UserName'." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to create local user '$UserName': $_" 
        throw
    }
}

function Update-AzDataLakeGen2ItemAcl {
    param (
        [string]$UserName,
        [string]$FileSystem,
        [string]$Path,
        [string]$Permissions,
        $Context
    )

    try {
        Write-Host "Updating ACL for path '$FileSystem/$Path' with permissions '$Permissions'..." -ForegroundColor Green
        $AzStorageLocalUser = Get-AzStorageLocalUser -ResourceGroupName $ResourceGroupName -StorageAccountName $SFTPStorageAccountName -UserName $UserName -DefaultProfile $Context -ErrorAction SilentlyContinue
        if ($null -eq $AzStorageLocalUser) {
            Write-Error "Local user '$UserName' not found. Cannot set ACL." 
            return
        }
    
        if ($AzStorageLocalUser.Count -gt 1) {
            Write-Warning "Multiple local users found with username '$UserName'. Using the first one returned."
            $AzStorageLocalUser = $AzStorageLocalUser[0]
        }
    
        $dir = Get-AzDataLakeGen2Item -Context $storageContext -FileSystem $FileSystem -Path $Path
        $aclEntry = $dir.ACL

        Write-Host "Retrieved local user '$UserName' with SID: $($AzStorageLocalUser.Sid)" -ForegroundColor Green
        $aclEntry = Set-AzDataLakeGen2ItemAclObject -AccessControlType user -Permission $Permissions -InputObject $aclEntry
        Set-AzDataLakeGen2AclRecursive -Context $storageContext -FileSystem $FileSystem -Path $Path -Acl $aclEntry
        Update-AzDataLakeGen2Item -Context $storageContext -FileSystem $FileSystem -Path $Path -Acl $aclEntry
        Write-Host "Successfully updated ACL for '$FileSystem/$Path'." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to update ACL for '$FileSystem/$Path': $_"
        throw
    }
}

Function Set-UserAndPermissions {
    param (
        [string]$FileSystem,
        [string]$Partner,
        [PsCustomObject]$User,
        $Context
    )
    $UserName = $User.Username
    $HomeDirectory = $User.HomeDirectory
    $Permissions = $User.Permissions

    Write-Host "Setting up user '$UserName' with home directory '$HomeDirectory' and permissions for partner '$Partner'..." -ForegroundColor Green
    
    try {
        $existingUser = Get-AzStorageLocalUser -ResourceGroupName $ResourceGroupName -StorageAccountName $SFTPStorageAccountName -UserName $UserName -ErrorAction SilentlyContinue
        if ($existingUser) {
            Write-Host "Local user '$UserName' already exists. Skipping creation." -ForegroundColor Yellow
        }
        else {
            Set-SftpLocalUser -StorageAccountName $SFTPStorageAccountName -ResourceGroupName $ResourceGroupName -UserName $UserName -Uid $UID -Context $context -HomeDirectory $HomeDirectory
        
            Write-host "SFTP user setup complete. Please securely store the access password for SFTP client configuration." -ForegroundColor Green
            # Generate a new access password for the user
            $accessPassword = New-AzStorageLocalUserSshPassword -ResourceGroupName $ResourceGroupName -StorageAccountName $SFTPStorageAccountName -UserName $UserName -DefaultProfile $context

            # Store the access password securely - this will be needed for SFTP client configuration
            #TODO: Implement secure storage for the access password (e.g., Azure Key Vault, secure file, etc.)
            Write-Host "Access Password for $UserName`: $($accessPassword.SshPassword)"

        }
        foreach ($perm in $Permissions) {
            $path = $perm.Folder
            Write-Host "Setting permissions for user '$UserName' on path '$path' with permissions '$($perm.Permission)'..." -ForegroundColor Green
            Update-AzDataLakeGen2ItemAcl -UserName $UserName -FileSystem $FileSystem -Path $path -Permissions $perm.Permission -Context $Context
        }
    }
    catch {
        Write-Error "Failed to create local user '$UserName': $_"
        throw
    }
}

$storageContext, $context = Get-AzStorageContextWithSPN
if ($context -is [System.Array]) {
    Write-Host "Top-level guard: context is an array; selecting first element." -ForegroundColor Yellow
    $context = $context[0]
}

foreach ($folder in $folders) {
    foreach ($user in $folder.Users) {
        Write-Host "Processing user '$($user.Username)' for folder '$($folder.Partner)'..." -ForegroundColor Green
        Set-UserAndPermissions -FileSystem $SFTPContainerName -Partner $folder.Partner -User $user -Context $context
    }
}

# List all local SFTP users to verify creation
Get-AzStorageLocalUser -ResourceGroupName $ResourceGroupName -StorageAccountName $SFTPStorageAccountName -DefaultProfile $context



