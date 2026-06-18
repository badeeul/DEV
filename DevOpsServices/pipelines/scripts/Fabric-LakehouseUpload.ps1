# Install required modules
if (-Not (Get-Module -ListAvailable -Name 'Az.Storage')) {
    Write-Host "Installing Az.Storage"
    Install-Module Az.Storage -Repository PSGallery -Force
}

if (-Not (Get-Module -ListAvailable -Name 'Az.Accounts')) {
    Write-Host "Installing Az.Accounts"
    Install-Module Az.Accounts -Repository PSGallery -Force
}

function Azure-Login {
    param (
        $TenantId,
        $ClientId,
        $ClientSecret
    )
    $securePassword = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential(
        $ClientId, $securePassword)
    Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $credential -ErrorAction Stop
}

function Upload-Files {
    param (
        [string] $LakehouseId,
        [string] $WorkspaceId,
        [string] $LocalPath,
        [string] $RemotePath
    )
    $StorageCtx = New-AzStorageContext -StorageAccountName 'onelake' -UseConnectedAccount -endpoint 'fabric.microsoft.com'

    $DirList = Get-ChildItem -Path $LocalPath -Recurse -File | Where-Object { $_.name -ne '.gitkeep'}
    $DirList | ForEach-Object {
        # common properties
        $FullName = $_.FullName

        $Parent = ($LakehouseId + $RemotePath)
        $Child = (Resolve-Path -Relative -Path $FullName -RelativeBasePath $LocalPath)

        $Child = $Child.Substring(2)
        $UploadPath = $Parent + "/" + $Child
        
        Write-Host "##[debug]Uploading file: $FullName to $UploadPath"
        Write-Host "##[debug]WorkspaceId: $WorkspaceId"

        New-AzDataLakeGen2Item -Context $StorageCtx -FileSystem $WorkspaceId -Path $UploadPath -Source $FullName -Force

        $global:upload_cnt += 1
        Write-Host "Upload action #$($global:upload_cnt)"
    }
}

function Get-WorkspaceLakehouse (
    [string]$workspaceId
) {
    $itemUrl = "https://api.fabric.microsoft.com/v1/workspaces/{0}/lakehouses" -f $workspaceId
    try {
        $response = Invoke-RestMethod -Uri $itemUrl -Headers $global:auth_header -Method GET

        return $response.value
    }
    catch {Write-Output "`tError Message: $($_.Exception.Message)"}
    return @()
}

$TenantId = $env:ARM_TENANT_ID
$FabricToken = $env:FABRIC_TOKEN
$LakehouseName = $env:LAKEHOUSE_NAME
$WorkspaceIds = ConvertFrom-Json -InputObject $env:WORKSPACE_IDS
$SourcePath = $env:SOURCE_PATH
$ClientId = $env:ARM_CLIENT_ID
$ClientSecret = $env:ARM_CLIENT_SECRET
$TargetPath = $env:TARGET_PATH

$WorkspaceId = $WorkspaceIds.PSObject.Properties.Value

$global:auth_header = @{
    'Content-Type' = "application/json"
    'Authorization' = "Bearer {0}" -f $FabricToken
   }

Write-Output "===================================================================================================="
Write-Output "Start Upload Files for Path | '$($SourcePath)'"

$global:upload_cnt = 0
$LocalPath = "../../../" + $SourcePath
$LakehousePath = "/Files/" + $TargetPath

if (!(Test-Path $LocalPath)) {
    Write-Output "Path '$($LocalPath)' could not be found. Skipping upload."
} else {
    $lakehouse = Get-WorkspaceLakehouse -WorkspaceId $WorkspaceId | Where-Object {$_.displayName -eq $LakehouseName}
    if ($null -eq $lakehouse) {
        Write-Output "Lakehouse '$($LakehouseName)' could not be found in the workspace (WorkspaceId: $($WorkspaceId)). Skipping upload."
    } else {
        Azure-Login -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
        Upload-Files -LakehouseId $lakehouse.id -WorkspaceId $WorkspaceId -LocalPath $LocalPath -RemotePath $LakehousePath
    }
}    

Write-Output "Upload Completed for Path | '$($SourcePath)' - Uploaded: $($global:upload_cnt)"
Write-Output "===================================================================================================="