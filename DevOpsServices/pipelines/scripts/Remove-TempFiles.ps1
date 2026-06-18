function Remove-TempFiles {
   
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Force
    )
   
    if (-not $env:TEMP) {
        Write-Error "TEMP environment variable not found"
        return
    }
   
    if (-not (Test-Path $env:TEMP)) {
        Write-Warning "Temp directory does not exist: $env:TEMP"
        return
    }
   
    $results = @{
        FilesRemoved = 0
        FoldersRemoved = 0
        SizeFreedMB = 0
        Errors = 0
    }
   
    Write-Host "Cleaning temp directory: $env:TEMP" -ForegroundColor Cyan
   
    try {
        # Get all items in temp directory
        $items = Get-ChildItem -Path $env:TEMP -Recurse -Force -ErrorAction SilentlyContinue
       
        if (-not $items) {
            Write-Host "Temp directory is already empty" -ForegroundColor Green
            return $results
        }
       
        # Calculate total size before removal
        $totalSize = ($items | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum
        $results.SizeFreedMB = [math]::Round($totalSize / 1MB, 2)
       
        if ($WhatIfPreference) {
            Write-Host "Would remove:" -ForegroundColor Yellow
            $items | ForEach-Object {
                $type = if ($_.PSIsContainer) { "Folder" } else { "File" }
                Write-Host "  $type`: $($_.FullName)" -ForegroundColor Yellow
            }
            Write-Host "Total items: $($items.Count)" -ForegroundColor Yellow
            Write-Host "Total size: $($results.SizeFreedMB) MB" -ForegroundColor Yellow
            return $results
        }
       
        # Remove files first (deepest first to avoid directory not empty errors)
        $files = $items | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName -Descending
       
        foreach ($file in $files) {
            try {
                if ($Force -or $PSCmdlet.ShouldProcess($file.FullName, "Remove File")) {
                    Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                    $results.FilesRemoved++
                }
            }
            catch {
                Write-Warning "Could not remove file: $($file.FullName) - $($_.Exception.Message)"
                $results.Errors++
            }
        }
       
        # Remove directories (deepest first)
        $folders = $items | Where-Object { $_.PSIsContainer } | Sort-Object FullName -Descending
       
        foreach ($folder in $folders) {
            try {
                if ($Force -or $PSCmdlet.ShouldProcess($folder.FullName, "Remove Folder")) {
                    Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction Stop
                    $results.FoldersRemoved++
                }
            }
            catch {
                Write-Warning "Could not remove folder: $($folder.FullName) - $($_.Exception.Message)"
                $results.Errors++
            }
        }
       
        Write-Host "Cleanup completed:" -ForegroundColor Green
        Write-Host "  Files removed: $($results.FilesRemoved)" -ForegroundColor Green
        Write-Host "  Folders removed: $($results.FoldersRemoved)" -ForegroundColor Green
        Write-Host "  Space freed: $($results.SizeFreedMB) MB" -ForegroundColor Green
       
        if ($results.Errors -gt 0) {
            Write-Warning "Encountered $($results.Errors) errors (some files may be in use)"
        }
    }
    catch {
        Write-Error "Failed to clean temp directory: $($_.Exception.Message)"
        $results.Errors++
    }
   
    return $results
}

# Example usage
Remove-TempFiles -Force
