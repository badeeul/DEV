param(
    [Parameter(Mandatory=$true)]
    [string]$KeyVaultName,
    [Parameter(Mandatory=$false)]
    [string]$LakehouseName,
    [Parameter(Mandatory=$false)]
    [string]$LakehouseId,
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
    [Parameter(Mandatory=$true)]
    [string]$EnvironmentId,
    [Parameter(Mandatory=$true)]    
    [string]$EnvironmentIdPython,
    [Parameter(Mandatory=$true)]
    [string]$NotebookPath
)

# Helper functions for cleaner code organization
function Get-CommentPrefix {
    param([string]$FileExtension)
   
    switch ($FileExtension) {
        ".sql"   { return "--" }
        ".scala" { return "//" }
        default  { return "#" }
    }
}

function Get-LanguageInfo {
    param([string]$FileExtension)
   
    switch ($FileExtension) {
        ".sql"   { return "sql" }
        ".scala" { return "scala" }
        default  { return "python" }
    }
}

function Get-KernelName {
    param(
        [string]$RawContent,
        [string]$CommentPrefix
    )
   
    # Try to extract kernel_info name directly
    $pattern1 = $CommentPrefix + '\s+META\s+"name":\s*"([^"]+)"'
    $pattern2 = $CommentPrefix + '\s+META\s+"kernel_info"[^{]*{[^}]*' + $CommentPrefix + '\s+META\s+"name":\s*"([^"]+)"'
   
    $match = [regex]::Match($RawContent, $pattern1)
    if (!$match.Success) {
        $match = [regex]::Match($RawContent, $pattern2)
    }
   
    if ($match.Success) {
        return $match.Groups[1].Value
    }
   
    return "synapse_pyspark" # Default
}

function Get-MetaBlocks {
    param(
        [string]$RawContent,
        [string]$CommentPrefix
    )
   
    $pattern = $CommentPrefix + ' META \{[\s\S]*?"language":\s*"([^"]+)"[\s\S]*?"language_group":\s*"([^"]+)"[\s\S]*?' + $CommentPrefix + ' META \}'
    $blocks = [regex]::Matches($RawContent, $pattern)
   
    $metaInfo = @()
    foreach ($block in $blocks) {
        if ($block.Groups.Count -ge 3) {
            $metaInfo += @{
                Language = $block.Groups[1].Value
                LanguageGroup = $block.Groups[2].Value
                Position = $block.Index
            }
        }
    }
   
    return $metaInfo
}

function Get-SectionMarkers {
    param(
        [string]$Content,
        [string]$CommentPrefix
    )
   
    $pattern = $CommentPrefix + ' (CELL|PARAMETERS CELL|META(?:DATA)?|MARKDOWN) \*{1,}'
    return [regex]::Matches($Content, $pattern)
}

function Remove-MetaLines {
    param(
        [string]$Content,
        [string]$CommentPrefix,
        [string]$KeyVaultName
    )
   
    $notebookSource = "$CommentPrefix Fabric notebook source"
   
    return $Content -split "`n" |
        Where-Object {
            -not ($_.Trim().StartsWith("$CommentPrefix META") -or
                  $_.Trim().StartsWith("$CommentPrefix METADATA") -or
                  $_.Trim() -eq $notebookSource)
        } |
        ForEach-Object {
            $line = $_
           
            # Replace any secretsScope assignment with the new KeyVault name
            # Handle quoted strings
            if ($line -match "(secretsScope\s*=\s*[`"'])([^`"']+)([`"'])") {
                $before = $matches[1]
                $oldValue = $matches[2]
                $after = $matches[3]
                $line = "${before}${KeyVaultName}${after}"
                Write-Host "##[debug]Replaced secretsScope from '$oldValue' to '$KeyVaultName'"
            }
            return $line
        } |
        Out-String            
}

function Remove-MagicPrefixes {
    param(
        [string]$Content,
        [string]$CommentPrefix
    )
   
    if ($Content -match "$CommentPrefix MAGIC") {
        return $Content -split "`n" |
            ForEach-Object { $_ -replace "$CommentPrefix MAGIC ", "" } |
            ForEach-Object { $_ -replace "$CommentPrefix MAGIC", "" } |
            Out-String
    }
   
    return $Content
}

function Process-MarkdownContent {
    param(
        [string]$Content,
        [string]$CommentPrefix
    )
   
    return $Content -split "`n" | ForEach-Object {
        if ($_.StartsWith("$CommentPrefix ")) {
            $_.Substring($CommentPrefix.Length + 1)
        } else {
            $_
        }
    } | Out-String
}

# Main script execution starts here
$folder = Split-Path -Parent $NotebookPath
$ipynbPath = Join-Path $folder "notebook-content.ipynb"

if (-not [string]::IsNullOrEmpty($EnvironmentId)) {
    $EnvironmentId = $EnvironmentId.Trim()
    Write-Host "##[debug]Trimmed EnvironmentId: '$EnvironmentId'"
}

if (-not [string]::IsNullOrEmpty($EnvironmentIdPython)) {
    $EnvironmentIdPython = $EnvironmentIdPython.Trim()
    Write-Host "##[debug]Trimmed EnvironmentIdPython: '$EnvironmentIdPython'"
}

Write-Host "##[debug]folder: $folder"
Write-Host "##[debug]NotebookPath: $NotebookPath"
Write-Host "##[debug]ipynbPath: $ipynbPath"
Write-Host "##[debug]LakehouseName: $LakehouseName"
Write-Host "##[debug]LakehouseId: $LakehouseId"
Write-Host "##[debug]WorkspaceId: $WorkspaceId"
Write-Host "##[debug]EnvironmentId: $EnvironmentId"
Write-Host "##[debug]EnvironmentIdPython: $EnvironmentIdPython"

if (Test-Path $NotebookPath) {
    # Read raw content
    $rawContent = Get-Content $NotebookPath -Raw -Encoding UTF8
   
    # Determine file type and associated comment prefix
    $fileExtension = [System.IO.Path]::GetExtension($NotebookPath).ToLower()
    $commentPrefix = Get-CommentPrefix -FileExtension $fileExtension
    $language_info_name = Get-LanguageInfo -FileExtension $fileExtension
   
    Write-Host "##[debug]File extension: $fileExtension, Comment prefix: $commentPrefix, Language: $language_info_name"
   
    # Extract kernel names
    $kernelName = Get-KernelName -RawContent $rawContent -CommentPrefix $commentPrefix
    $jupyterKernelName = $kernelName # Default to same as kernelName if not found
   
    # Try to extract jupyter_kernel_name from metadata
    $jupyterKernelMatch = [regex]::Match($rawContent, '"jupyter_kernel_name":\s*"([^"]+)"')
    if ($jupyterKernelMatch.Success) {
        $jupyterKernelName = $jupyterKernelMatch.Groups[1].Value
        Write-Host "##[debug]Found jupyter_kernel_name in metadata: $jupyterKernelName"
    }
   
    # Extract META blocks with language information
    $metaInfo = Get-MetaBlocks -RawContent $rawContent -CommentPrefix $commentPrefix
    Write-Host "##[debug]Found $($metaInfo.Count) META blocks with language information"
   
    # Process content and remove META lines
    $content = Remove-MetaLines -Content $rawContent -CommentPrefix $commentPrefix -KeyVaultName $KeyVaultName
   
    # Get section markers
    $markers = Get-SectionMarkers -Content $content -CommentPrefix $commentPrefix
   
    # Split content into sections
    $sections = @()
    $currentPos = 0
   
    foreach ($marker in $markers) {
        if ($marker.Index -gt $currentPos) {
            $sections += @{
                Content = $content.Substring($currentPos, $marker.Index - $currentPos).Trim()
                Marker = ""
                Position = $currentPos
            }
        }
        $currentPos = $marker.Index + $marker.Length
        $sections += @{
            Content = ""
            Marker = $marker.Groups[1].Value
            Position = $marker.Index
        }
    }
   
    # Add the final section
    if ($currentPos -lt $content.Length) {
        $sections += @{
            Content = $content.Substring($currentPos).Trim()
            Marker = ""
            Position = $currentPos
        }
    }
   
    # Process sections
    $cells = @()
    $foundFirstSection = $false
    $foundParametersSection = $false
    $lastMarker = ""
    $currentLanguage = "python"  # Default
    $currentLanguageGroup = $kernelName  # Default
   

    foreach ($section in $sections) {
        if ([string]::IsNullOrWhiteSpace($section.Content)) {
            $lastMarker = $section.Marker
            continue
        }
    
        # Find applicable META block for this section
        $relevantMetaInfo = $null
        foreach ($metaBlock in $metaInfo) {
            if ($metaBlock.Position -lt $section.Position -and
                ($relevantMetaInfo -eq $null -or $metaBlock.Position > $relevantMetaInfo.Position)) {
                $relevantMetaInfo = $metaBlock
            }
        }
    
        if ($relevantMetaInfo -ne $null) {
            $currentLanguage = $relevantMetaInfo.Language
            $currentLanguageGroup = $relevantMetaInfo.LanguageGroup
            Write-Host "##[debug]Using language: $currentLanguage, language_group: $currentLanguageGroup for section"
        }

        if ($kernelName -eq "sqldatawarehouse") {
            $currentLanguage = "sql"
            $currentLanguageGroup = "sqldatawarehouse"
        }
        
        # Check if this is a parameters cell - ONLY if explicitly marked
        $isParametersCell = $lastMarker -eq "PARAMETERS CELL"
    
        # Remove MAGIC prefixes
        $processedContent = Remove-MagicPrefixes -Content $section.Content -CommentPrefix $commentPrefix
        $hasMagicPrefix = $section.Content -match "$commentPrefix MAGIC"
    
        Write-Host "##[debug]Processing section. Marker: '$lastMarker', Is Parameters Cell: $isParametersCell, Has Magic Prefix: $hasMagicPrefix"
    
        # Create the appropriate cell type
        if (-not $foundFirstSection) {
            if ($lastMarker -eq "MARKDOWN") {
                # First section is markdown
                $markdownContent = Process-MarkdownContent -Content $processedContent -CommentPrefix $commentPrefix
                $cells += @{
                    cell_type = "markdown"
                    source = @($markdownContent)
                    metadata = @{}
                }
                Write-Host "##[debug]Added first section as markdown"
            }
            elseif ($isParametersCell) {
                # First section is a parameters cell
                $cells += @{
                    cell_type = "code"
                    source = @($processedContent)
                    metadata = @{
                        microsoft = @{
                            language = $currentLanguage
                            language_group = $currentLanguageGroup
                        }
                        tags = @("parameters")
                    }
                    outputs = @()
                }
                $foundParametersSection = $true
                Write-Host "##[debug]Added first section as parameters cell with tags"
            }
            else {
                # First non-empty section goes to first cell as code
                $cells += @{
                    cell_type = "code"
                    source = @($processedContent)
                    metadata = @{
                        microsoft = @{
                            language = $currentLanguage
                            language_group = $currentLanguageGroup
                        }
                    }
                    outputs = @()
                }
                Write-Host "##[debug]Added first section as regular code cell"
            }
            $foundFirstSection = $true
        }
        elseif ($isParametersCell) {
            # Parameters cell that's not the first section
            $cells += @{
                cell_type = "code"
                source = @($processedContent)
                metadata = @{
                    microsoft = @{
                        language = $currentLanguage
                        language_group = $currentLanguageGroup
                    }
                    tags = @("parameters")
                }
                outputs = @()
            }
            $foundParametersSection = $true
            Write-Host "##[debug]Added non-first section as parameters cell with tags"
        }
        elseif ($lastMarker -eq "MARKDOWN") {
            # Markdown cell
            $markdownContent = Process-MarkdownContent -Content $processedContent -CommentPrefix $commentPrefix
            $cells += @{
                cell_type = "markdown"
                source = @($markdownContent)
                metadata = @{}
            }
            Write-Host "##[debug]Added markdown cell"
        }
        else {
            # Code cell
            $cells += @{
                cell_type = "code"
                source = @($processedContent)
                metadata = @{
                    microsoft = @{
                        language = $currentLanguage
                        language_group = $currentLanguageGroup
                    }
                }
                outputs = @()
            }
            Write-Host "##[debug]Added regular code cell"
        }
    
        # Reset the marker after using it
        $lastMarker = ""
    }

    # Debug output after processing
    Write-Host "##[debug]Total cells created: $($cells.Count)"
    $parameterCells = $cells | Where-Object { $_.metadata.tags -contains "parameters" }
    Write-Host "##[debug]Parameter cells found: $($parameterCells.Count)"
   
    if ("00000000-0000-0000-0000-000000000000" -eq $EnvironmentId) {
        $EnvironmentId = $null
    }

    if ($jupyterKernelName.StartsWith("python")) {
        $EnvironmentId = $EnvironmentIdPython
    }

    # Build notebook content
    $ipynbContent = @{
        cells = $cells
        metadata = @{
            kernel_info = @{
                name = $kernelName
                jupyter_kernel_name = $jupyterKernelName
            }
            dependencies = @{
                environment = @{
                    environmentId = $EnvironmentId
                    workspaceId = $WorkspaceId
                }
            }
            language_info = @{
                name = $language_info_name
            }
        }
        nbformat = 4
        nbformat_minor = 2
    }
   
    # Add lakehouse if provided
    if ($LakehouseName -ne $null -and -not [string]::IsNullOrWhiteSpace($LakehouseName)) {
        $ipynbContent.metadata.dependencies.lakehouse = @{
            default_lakehouse = $LakehouseId
            default_lakehouse_name = $LakehouseName
            default_lakehouse_workspace_id = $WorkspaceId
        }
    }
   
    # Write output file
    $jsonContent = $ipynbContent | ConvertTo-Json -Depth 10 -Compress

    Write-Host "##[debug]Writing notebook content path $ipynbPath to $jsonContent"

    [System.IO.File]::WriteAllText($ipynbPath, $jsonContent, [System.Text.Encoding]::UTF8)
    Write-Host "Converted $NotebookPath to $ipynbPath"
}
else {
    Write-Warning "Notebook file not found at $NotebookPath"
}
