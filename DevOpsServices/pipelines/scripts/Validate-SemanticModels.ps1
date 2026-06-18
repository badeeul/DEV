function Validate-ExpressionFile {
    param (
        [string]$BaseFolderPath,
        [string]$FabricItemType = "SemanticModel"
    )    
    # Get all subfolders in the base folder
    $folders = Get-ChildItem -Path $BaseFolderPath -Directory -Filter "*.$($FabricItemType)"  
   
    foreach ($folder in $folders) {
        $itemSourceFiles = Get-ChildItem -Path $folder.FullName -File -Recurse | Where-Object name -eq "expressions.tmdl"

        $itemSourceFiles | ForEach-Object {
            if ($_.Name -eq "expressions.tmdl") {

                Write-Host "`tValidating File '$($_.FullName)'"

                $database_pattern = 'Sql.Database[(]"(\w+[-]\w+[.]datawarehouse.fabric.microsoft.com)", "(\w{8}-\w{4}-\w{4}-\w{4}-\w{12})"[)]'
                $fileContent = Get-Content -Path $_.FullName -Raw
                $databases = $fileContent | Select-String -pattern $database_pattern -AllMatches

                if ($databases.count -gt 0) {
                    Write-Host "`tInvalid Connections: $($databases.Matches.count)" -ForegroundColor Red
                    $databases.Matches | ForEach-Object {
                        Write-Host "`t$($_.Value)" -ForegroundColor Red
                    }
                    $global:FileCount += 1
                } else {
                    Write-Host "`tConnections are valid"
                }
            }
        }
    }
}

$SourceCodePath = "../../../src/fabric"

$FabricItemType = "SemanticModel"

Write-Output "===================================================================================================="
Write-Output "Validate Fabric Semantic Model Expression Files"
$global:FileCount = 0

Validate-ExpressionFile -BaseFolderPath $SourceCodePath -FabricItemType $FabricItemType

if ($global:FileCount -gt 0) {
    Write-Error "Validation of Expression Files Completed | Failed: $($global:FileCount)" -ErrorAction Stop
} else {
    Write-Output "Validation of Expression Files Completed | Failed: $($global:FileCount)"
}
Write-Output "===================================================================================================="
