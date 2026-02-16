# Run via Fetch: irm https://raw.githubusercontent.com/Boden-C/shell-scripts/refs/heads/main/pwsh/file_management/standard_date_filenaming.ps1 | iex; Rename-ImagesByExifOrFilename

function Rename-ImagesByExifOrFilename {
<#
.SYNOPSIS
    Organizes image files by renaming them based on EXIF/filename date.
    PATCHED: Allows Absolute Paths for Output Folders.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Path = (Get-Location).Path,

        [Parameter(Mandatory = $false)]
        [string]$OrganizedPhotosFolder = "Organized Photos",

        [Parameter(Mandatory = $false)]
        [string]$ThumbnailsFolder = "Thumbnails",

        [Parameter(Mandatory = $false)]
        [string]$LogFile = "log.txt",

        [Parameter(Mandatory = $false)]
        [switch]$AppendLog,

        [Parameter(Mandatory = $false)]
        [string]$TimeZone = "UTC"
    )

    # Interactive Prompt
    if ($PSBoundParameters.Count -eq 0) {
        Write-Host "Interactive Mode: Press Enter to accept defaults." -ForegroundColor Cyan
        
        $i = Read-Host "Source Path [$Path]"
        if ($i) { $Path = $i }

        $i = Read-Host "Organized Photos Destination [$OrganizedPhotosFolder]"
        if ($i) { $OrganizedPhotosFolder = $i }

        $i = Read-Host "Thumbnails Destination [$ThumbnailsFolder]"
        if ($i) { $ThumbnailsFolder = $i }

        $i = Read-Host "TimeZone [$TimeZone]"
        if ($i) { $TimeZone = $i }
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    catch {
        Write-Error "System.Drawing required. Error: $($_.Exception.Message)"
        return
    }

    try {
        $script:TargetTimeZoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
    }
    catch {
        Write-Error "Invalid TimeZone '$TimeZone'. Error: $($_.Exception.Message)"
        return
    }

    # FIX: Ensure we get a clean string path, removing Provider prefixes if present
    $rootPath = Resolve-Path $Path | Select-Object -ExpandProperty Path

    # FIX: Handle Absolute Paths vs Relative Names for Organized Folder
    if ([System.IO.Path]::IsPathRooted($OrganizedPhotosFolder)) {
        $organizedPhotosFullPath = $OrganizedPhotosFolder
    } else {
        $organizedPhotosFullPath = Join-Path -Path $rootPath -ChildPath $OrganizedPhotosFolder
    }

    # FIX: Handle Absolute Paths vs Relative Names for Thumbnails Folder
    if ([System.IO.Path]::IsPathRooted($ThumbnailsFolder)) {
        $thumbnailsFullPath = $ThumbnailsFolder
    } else {
        $thumbnailsFullPath = Join-Path -Path $rootPath -ChildPath $ThumbnailsFolder
    }

    $script:logFilePath = Join-Path -Path $rootPath -ChildPath $LogFile

    # Create directories
    if (-not (Test-Path $organizedPhotosFullPath)) {
        New-Item -Path $organizedPhotosFullPath -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $thumbnailsFullPath)) {
        New-Item -Path $thumbnailsFullPath -ItemType Directory -Force | Out-Null
    }

    if (-not $AppendLog) {
        Set-Content -Path $script:logFilePath -Value "Log started at $(Get-Date)" -Force
    }

    function _Log-Action {
        param([string]$Message)
        $logEntry = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") - $Message"
        Add-Content -Path $script:logFilePath -Value $logEntry
        Write-Verbose $logEntry
    }

    function _Get-FileHashMD5 {
        param([string]$FilePath)
        try {
            return (Get-FileHash -Path $FilePath -Algorithm MD5 -ErrorAction Stop).Hash
        }
        catch {
            return $null
        }
    }

    function _Convert-UnixTimestamp {
        param([long]$UnixTimestamp)
        try {
            $utcDateTimeOffset = [datetimeoffset]::FromUnixTimeSeconds($UnixTimestamp)
            return [System.TimeZoneInfo]::ConvertTime($utcDateTimeOffset, $script:TargetTimeZoneInfo).DateTime
        }
        catch {
            return $null
        }
    }

    $script:processedImageSignatures = @{}

    # Recursively get images, excluding the output folders to prevent loops
    $imageFiles = Get-ChildItem -Path $rootPath -Recurse -File | Where-Object {
        $_.Extension -match "\.(jpg|jpeg|png|gif|bmp|tiff)$" -and
        $_.DirectoryName -ne $organizedPhotosFullPath -and
        $_.DirectoryName -ne $thumbnailsFullPath
    }

    foreach ($file in $imageFiles) {
        $bitmap = $null
        try {
            if (-not (Test-Path $file.FullName)) { continue }

            $extractedDateTime = $null
            $isThumbnail = $false

            try {
                $bitmap = New-Object System.Drawing.Bitmap($file.FullName)
                $isThumbnail = ($bitmap.Width -lt 600 -and $bitmap.Height -lt 600)

                if ($bitmap.PropertyIdList -contains 36867) { 
                    try {
                        $exifStr = [System.Text.Encoding]::ASCII.GetString($bitmap.GetPropertyItem(36867).Value).TrimEnd("`0")
                        $extractedDateTime = [datetime]::ParseExact($exifStr, "yyyy:MM:dd HH:mm:ss", $null)
                    }
                    catch {}
                }
            }
            catch {
                 _Log-Action "ERROR: Invalid image '$($file.FullName)'."
                 continue
            }
            finally {
                if ($bitmap -ne $null) {
                    $bitmap.Dispose()
                    $bitmap = $null
                }
            }

            if (-not $extractedDateTime -or $extractedDateTime.Year -lt 1900) {
                $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

                if ($name -match '(\d{8})_(\d{6})') {
                    $extractedDateTime = [datetime]::ParseExact("$($Matches[1]) $($Matches[2])", "yyyyMMdd HHmmss", $null)
                }
                elseif ($name -match '(\d{14})') {
                    $extractedDateTime = [datetime]::ParseExact($Matches[1], "yyyyMMddHHmmss", $null)
                }
                elseif ($name -match '^\d{10}$') {
                    $extractedDateTime = _Convert-UnixTimestamp -UnixTimestamp ([long]$Matches[0])
                }
                elseif ($name -match '^\d{13}$') {
                    $extractedDateTime = _Convert-UnixTimestamp -UnixTimestamp ([long]$Matches[0] / 1000)
                }
            }

            if (-not $extractedDateTime -or $extractedDateTime.Year -lt 1900) {
                _Log-Action "SKIPPED: '$($file.FullName)' - No date found."
                continue
            }

            $fileHash = _Get-FileHashMD5 -FilePath $file.FullName
            if (-not $fileHash) { continue }

            $destinationFolder = if ($isThumbnail) { $thumbnailsFullPath } else { $organizedPhotosFullPath }
            
            # Special colon U+A789 used for time to allow windows filenames
            $dateString = $extractedDateTime.ToString("yyyy-MM-dd HH꞉mm꞉ss")
            
            if ($file.Name -match "screenshot") {
                $baseFileName = "Screenshot $dateString"
            } else {
                $baseFileName = $dateString
            }

            $newFileNameCandidate = $baseFileName + $file.Extension
            $targetNewPath = Join-Path -Path $destinationFolder -ChildPath $newFileNameCandidate

            $finalNewPath = $targetNewPath
            $counter = 0
            while (Test-Path $finalNewPath) {
                $counter++
                $tempNewFileName = "$baseFileName ($counter)$($file.Extension)"
                $finalNewPath = Join-Path -Path $destinationFolder -ChildPath $tempNewFileName
            }

            $signatureKey = "$($extractedDateTime.Ticks)-$fileHash"
            if ($script:processedImageSignatures.ContainsKey($signatureKey)) {
                $processedAsPath = $script:processedImageSignatures[$signatureKey]
                if ($PSCmdlet.ShouldProcess($file.FullName, "Delete as duplicate of '$processedAsPath'")) {
                    _Log-Action "DELETED: '$($file.FullName)' -> Duplicate."
                    Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
                }
                continue
            }
            else {
                $script:processedImageSignatures[$signatureKey] = $finalNewPath
            }

            $isAlreadyCorrect = (
                ([System.IO.Path]::GetFileName($file.FullName) -eq ([System.IO.Path]::GetFileName($targetNewPath))) -and
                ([System.IO.Path]::GetDirectoryName($file.FullName) -eq $destinationFolder)
            )

            if ($isAlreadyCorrect) {
                if ($PSCmdlet.ShouldProcess($file.FullName, "Move (already correctly named)")) {
                    Move-Item -Path $file.FullName -Destination $finalNewPath -Force -ErrorAction Stop
                    _Log-Action "MOVED: '$($file.FullName)' -> '$finalNewPath'"
                }
            }
            else {
                if ($PSCmdlet.ShouldProcess($file.FullName, "Rename and Move to '$finalNewPath'")) {
                    Move-Item -Path $file.FullName -Destination $finalNewPath -Force -ErrorAction Stop
                    _Log-Action "PROCESSED: '$($file.FullName)' -> '$finalNewPath'"
                }
            }
        }
        catch {
            _Log-Action "ERROR: Processing '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}

