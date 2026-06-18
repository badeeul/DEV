param (
    [string]$KeyVaultName
)

function Convert-PythonNotebook {
    param($FolderPath)
   
    $pyPath = Join-Path $FolderPath "notebook-content.py"
    $ipynbPath = Join-Path $FolderPath "notebook-content.ipynb"
   
    if (!(Test-Path $pyPath)) {
        Write-Warning "Python file not found in $FolderPath"
        return
    }
   
    $content = Get-Content $pyPath -Raw
   
    # Clean content
    $content = $content -split "`n" |
        Where-Object { -not ($_.Trim().StartsWith("# META") -or $_.Trim().StartsWith("# METADATA") -or $_.Trim() -eq "# Fabric notebook source") } |
        ForEach-Object { $_ -replace "bhg-hub-fabric01-eus-kv", $KeyVaultName } |
        Out-String
   
    $markers = [regex]::Matches($content, '# (CELL|PARAMETERS CELL|META(?:DATA)?|MARKDOWN) \*{1,}')
   
    # Split into sections
    $sections = @()
    $currentPos = 0
   
    foreach ($marker in $markers) {
        if ($marker.Index -gt $currentPos) {
            $sections += @{
                Content = $content.Substring($currentPos, $marker.Index - $currentPos).Trim()
                Marker = ""
            }
        }
        $currentPos = $marker.Index + $marker.Length
        $sections += @{
            Content = ""
            Marker = $marker.Groups[1].Value
        }
    }
   
    if ($currentPos -lt $content.Length) {
        $sections += @{
            Content = $content.Substring($currentPos).Trim()
            Marker = ""
        }
    }
   
    # Process sections
    $cells = @()
    $foundFirstSection = $false
    $foundParametersSection = $false
    $lastMarker = ""
   
    foreach ($section in $sections) {
        if ([string]::IsNullOrWhiteSpace($section.Content)) {
            $lastMarker = $section.Marker
            continue
        }
       
        $isVariableAssignment = [regex]::IsMatch($section.Content, '^\s*[a-zA-Z_][a-zA-Z0-9_]*\s*=')
        $isMarkdown = $lastMarker -eq "MARKDOWN"
       
        # Determine cell type
        $cellType = "code"
        $cellMetadata = @{
            language = "python"
            language_group = "synapse_pyspark"
        }
       
        if ($isMarkdown) {
            $cellType = "markdown"
            $cellMetadata = @{}
        }
       
        # Add cell
        $cells += @{
            cell_type = $cellType
            source = @($section.Content)
            metadata = $cellMetadata
            outputs = if ($cellType -eq "code") { @() } else { $null }
        }
       
        # Track section types
        if (!$foundFirstSection) {
            $foundFirstSection = $true
        }
        elseif ($isVariableAssignment -and !$foundParametersSection) {
            $foundParametersSection = $true
        }
       
        $lastMarker = ""
    }
   
    # Create notebook content
    $ipynbContent = @{
        cells = $cells
        metadata = @{
            kernel_info = @{
                name = "synapse_pyspark"
            }
            dependencies = @{
                lakehouse = @{
                    default_lakehouse = ""
                    default_lakehouse_name = ""
                    default_lakehouse_workspace_id = ""
                }
                environment = @{
                    environmentId = ""
                    workspaceId = ""
                }
            }
        }
        nbformat = 4
        nbformat_minor = 2
    }
   
    $jsonContent = $ipynbContent | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($ipynbPath, $jsonContent, [System.Text.Encoding]::UTF8)
    Write-Host "Converted $pyPath to $ipynbPath"
}

function Convert-SqlNotebook {
    param(
        [string]$FolderPath,
        [string]$NotebookContentPath
    )
   
    $sqlPath = Join-Path $FolderPath $NotebookContentPath
    $ipynbPath = Join-Path $FolderPath "notebook-content.ipynb"
   
    if (!(Test-Path $sqlPath)) {
        Write-Warning "SQL file not found in $FolderPath"
        return
    }
   
    $cells = @(
        @{
            cell_type = "markdown"
            source = @("This is a template")
            metadata = @{}
        }
    )
   
    $ipynbContent = @{
        cells = $cells
        metadata = @{
            kernel_info = @{
                name = "synapse_pyspark"
            }
            dependencies = @{
                lakehouse = @{
                    default_lakehouse = ""
                    default_lakehouse_name = ""
                    default_lakehouse_workspace_id = ""
                }
                environment = @{
                    environmentId = ""
                    workspaceId = ""
                }
            }
        }
        nbformat = 4
        nbformat_minor = 2
    }
   
    $jsonContent = $ipynbContent | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($ipynbPath, $jsonContent, [System.Text.Encoding]::UTF8)
    Write-Host "Converted $sqlPath to $ipynbPath"
}

# Process notebooks from src/fabric directory
Get-ChildItem -Path "../../../src/fabric" -Filter "*.Notebook" -Recurse | ForEach-Object {
    Convert-PythonNotebook $_.FullName
    Convert-SqlNotebook -FolderPath $_.FullName -NotebookContentPath "notebook-content.sql"
}

# Process notebooks from src/ellie directory
Get-ChildItem -Path "../../../src/ellie" -Filter "*.Notebook" -Recurse | ForEach-Object {
    Convert-SqlNotebook -FolderPath $_.FullName -NotebookContentPath "subdomain.sql"
}

