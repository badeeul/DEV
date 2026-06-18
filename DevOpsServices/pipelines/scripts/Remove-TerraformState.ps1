param(
    [Parameter(Mandatory=$true)]
    [string]$StateFileName,
   
    [Parameter(Mandatory=$true)]
    [string]$StorageAccount,
   
    [Parameter(Mandatory=$true)]
    [string]$ContainerName,
   
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
   
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
   
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
   
    [Parameter(Mandatory=$true)]
    [string]$ClientId,
   
    [Parameter(Mandatory=$true)]
    [string]$ClientSecret,
   
    [Parameter(Mandatory=$true)]
    [string]$ParentDomainName,
   
    [Parameter(Mandatory=$true)]
    [string]$ChildDomainName,
   
    [Parameter(Mandatory=$true)]
    [string]$Environment
)

try {
    Write-Host "##[section]Removing Terraform State File from Blob Storage"
    Write-Host "##[debug]State File: $StateFileName"
    Write-Host "##[debug]Storage Account: $StorageAccount"
    Write-Host "##[debug]Container: $ContainerName"
    Write-Host "##[debug]Environment: $Environment"
   
    # Check if Az modules are already installed
    $requiredModules = @(
        'Az.Accounts',
        'Az.Storage'
    )

    foreach ($module in $requiredModules) {
        if (!(Get-Module -Name $module -ListAvailable)) {
            Write-Host "Installing $module..."
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
            Install-Module -Name $module -Force -AllowClobber -Scope CurrentUser -Confirm:$false
        } else {
            Write-Host "$module already installed"
        }
    }
   
    # Import required modules
    Import-Module Az.Accounts -DisableNameChecking
    Import-Module Az.Storage -DisableNameChecking

    # Clear existing context
    Clear-AzContext -Force
   
    # Configure authentication
    Update-AzConfig -LoginExperienceV2 off
    Update-AzConfig -EnableLoginByWam $false

    # Create credential object
    $userPwd = $ClientSecret | ConvertTo-SecureString -AsPlainText -Force
    $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $ClientId, $userPwd

    # Connect to Azure
    Write-Host "##[debug]Connecting to Azure..."
    $connectResult = Connect-AzAccount -Tenant $TenantId -Credential $credential -Subscription $SubscriptionId -ServicePrincipal
    if ($connectResult) {
        Write-Host "##[debug]Successfully connected to Azure"
        Write-Host "##[debug]Account: $($connectResult.Context.Account.Id)"
        Write-Host "##[debug]Subscription: $($connectResult.Context.Subscription.Id)"
        Write-Host "##[debug]Tenant: $($connectResult.Context.Tenant.Id)"
    } else {
        throw "Failed to connect to Azure"
    }


    # Construct the blob key path
    $blobKey = "$ParentDomainName/$ChildDomainName/$Environment/$StateFileName"
    Write-Host "##[debug]Blob Key Path: $blobKey"
   
    # Get storage account context
    $ctx = $null
    Write-Host "##[debug]Getting storage account context..."
    try {
        # Method 2: Use storage account keys to create context
        $keys = Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccount -ErrorAction Stop
        $key = $keys[0].Value
        $ctx = New-AzStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $key
        Write-Host "##[debug]Successfully created storage context using access keys"
    } catch {
        Write-Host "##vso[task.LogIssue type=error;]Failed to create storage context: $($_.Exception.Message)"
        throw "Unable to establish storage context. Please verify storage account permissions."
    }
   
    # Check if the blob exists
    Write-Host "##[debug]Checking if blob exists..."
    try {
        $blob = Get-AzStorageBlob -Container $ContainerName -Blob $blobKey -Context $ctx -ErrorAction Stop
        Write-Host "##[section]Found Terraform state file: $blobKey"
        Write-Host "##[debug]Blob Properties:"
        Write-Host "##[debug]  Last Modified: $($blob.LastModified)"
        Write-Host "##[debug]  Length: $($blob.Length) bytes"
        Write-Host "##[debug]  Content Type: $($blob.BlobType)"

        # Confirm deletion
        Write-Host "##[warning]About to delete Terraform state file: $blobKey"
        
        # Remove the blob
        Write-Host "##[debug]Removing blob..."
        Remove-AzStorageBlob -Container $ContainerName -Blob $blobKey -Context $ctx -Force
        
        # Verify deletion
        try {
            $verifyBlob = Get-AzStorageBlob -Container $ContainerName -Blob $blobKey -Context $ctx -ErrorAction Stop
            Write-Host "##vso[task.LogIssue type=error;]Error: Blob still exists after deletion attempt"
            exit 1
        } catch {
            Write-Host "##[section]Successfully removed Terraform state file: $blobKey"
        }

       
    } catch {
        if ($_.Exception.Message -like "*BlobNotFound*" -or $_.Exception.Message -like "*does not exist*") {
            Write-Host "##[warning]Terraform state file does not exist: $blobKey"
            Write-Host "##[section]No action needed - file already absent"
        } else {
            Write-Host "##vso[task.LogIssue type=error;]Error checking blob existence: $($_.Exception.Message)"
            throw
        }
    }
   
    Write-Host "##[section]Terraform state removal operation completed"
   
} catch {
    Write-Host "##vso[task.LogIssue type=error;]Error removing Terraform state: $($_.Exception.Message)"
    Write-Host "##vso[task.LogIssue type=error;]Stack Trace: $($_.ScriptStackTrace)"
   
    # Enhanced error handling
    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode
        Write-Host "##vso[task.LogIssue type=error;]HTTP Status Code: $statusCode"
    }
   
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}
