function Test-DirectoryTree
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Paths
    )

    Begin
    {
        # Set path separator
        $Separator = '/'

        # Init array to hold log
        $Log = @()
    }

    Process
    {
        # For every path in array
        foreach ($Path in $Paths){

            # Init array to store existing paths
            $Tree = @()

            # Split path
            foreach ($Dir in $Path.Split($Separator)){
                # If not first element
                if($Tree)
                {
                    # Build path for current dir to check
                    $CurrDir = Join-Path -Path ($Tree -join $Separator) -ChildPath $Dir
                }
                else # If not first element
                {
                    # Check if root dir exist
                    if(!(Test-Path -LiteralPath $Dir -PathType Container) -and [System.IO.Path]::IsPathRooted($Dir))
                    {
                        Write-Error "Root folder '$Dir' is not valid!"
                        break
                    }
                    else
                    {
                        # Build path for current dir to check
                        $CurrDir = $Dir
                    }
                }

                # If current dir not exist
                if(!(Test-Path -LiteralPath $CurrDir -PathType Container))
                {
                    # Write message to log
                    $Log += "Folder doesn't exist: $CurrDir"
                }

                # If current dir exist, do nothing and add it to existing paths
                $Tree += $Dir
            }
        }
    }

    End
    {
        # Return log
        return $Log
    }
}

$SourceCodePath = "../../../src/metadata"

Write-Output "===================================================================================================="
Write-Output "Validate Metadata Folder Structure"

$Paths = @(
    "/data_product/feeds",
    "/data_quality",
    "/datasets",
    "/feeds",
    "/templates/emails",
    "/templates/logs"
) | ForEach-Object {
    $SourceCodePath + $_
}

$Log = $Paths | Test-DirectoryTree
$Log | ForEach-Object { Write-Host $_ -ForegroundColor Red }

if ($Log.count -gt 0) {
    Write-Error "Validation of Metadata Folder Structure Completed | Failed: $($Log.count)" -ErrorAction Stop
} else {
    Write-Output "Validation of Metadata Folder Structure Completed | Failed: 0"
}
Write-Output "===================================================================================================="
