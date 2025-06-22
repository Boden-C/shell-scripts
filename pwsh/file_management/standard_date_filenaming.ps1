function Rename-ImagesByExifOrFilename {
<#
.SYNOPSIS
    Organizes image files by renaming them based on their EXIF date or filename date,
    moving them into a central folder, and handling duplicates.
.DESCRIPTION
    This script scans a specified path for image files (JPG, PNG, GIF, BMP, TIFF).
    It prioritizes extracting the 'Date Taken' from EXIF metadata. If EXIF data is
    not available or invalid, it attempts to parse a date from common filename patterns:
    'YYYYMMDD_HHmmss', 'YYYYMMDDHHmmss', or 10/13-digit Unix timestamps.
 
    Images are then renamed to a 'yyyy-MM-dd HH꞉mm꞉ss' format.
    Small images (potential thumbnails, defined as less than 600x600 pixels in both dimensions)
    are moved to a dedicated 'Thumbnails' folder. All other images go to an 'Organized Photos' folder.
 
    Duplicate files are detected based on a combination of their extracted date/time
    and their MD5 file hash, ensuring only exact duplicates are flagged.
    Destructive actions (renaming, moving, deleting duplicates) are logged to a text file.
 
    **Interactive Control:**
    - The script uses `SupportsShouldProcess`, enabling `-WhatIf` for a dry run (showing what *would* happen)
      and `-Confirm` for interactive prompts before each significant action (move, delete).
    - If a file's name already matches the target format and it's in the correct destination folder,
      you'll be prompted specifically to confirm if you want to move it, providing fine-grained control.
 
.PARAMETER Path
    The root directory to scan for image files.
    Defaults to the current working directory (`Get-Location`).
 
.PARAMETER OrganizedPhotosFolder
    The name of the folder where primary (non-thumbnail) images will be moved.
    Defaults to "Organized Photos".
 
.PARAMETER ThumbnailsFolder
    The name of the folder where small images (thumbnails) will be moved.
    Defaults to "Thumbnails".
 
.PARAMETER LogFile
    The name of the log file to record all processing actions.
    Defaults to "log.txt".
 
.PARAMETER AppendLog
    If specified, new log entries will be appended to the existing log file.
    Otherwise, the log file will be overwritten at the start of the script run.
 
.PARAMETER TimeZone
    The target time zone for converting Unix timestamps found in filenames.
    This should be a valid system time zone ID (e.g., 'UTC', 'Pacific Standard Time').
    Defaults to 'UTC' (Coordinated Universal Time) for global consistency.
    You can find valid IDs using `[System.TimeZoneInfo]::GetSystemTimeZones()`.
 
.EXAMPLE
    Rename-ImagesByExifOrFilename -Path "C:\MyVacationPhotos" -WhatIf -Verbose
 
    # Scans "C:\MyVacationPhotos", displays detailed output of planned actions
    # without making any changes (due to -WhatIf).
 
.EXAMPLE
    Rename-ImagesByExifOrFilename -Confirm -TimeZone "Central Standard Time"
 
    # Scans the current directory, prompts for confirmation before each rename/move/delete.
    # Unix timestamps in filenames will be converted based on "Central Standard Time".
 
.EXAMPLE
    Rename-ImagesByExifOrFilename -Path "D:\Images"
 
    # Scans D:\Images and processes files. No interactive prompts unless an error occurs.
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
 
    #region Initial Setup and Validation
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to load System.Drawing assembly, which is required for image processing (EXIF, dimensions). Error: $($_.Exception.Message)"
        return
    }
 
    try {
        $script:TargetTimeZoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
        Write-Verbose "Using time zone: $($script:TargetTimeZoneInfo.DisplayName)"
    }
    catch {
        Write-Error "Invalid TimeZone '$TimeZone'. Please use a valid system time zone ID. You can list valid IDs with `[System.TimeZoneInfo]::GetSystemTimeZones()`. Error: $($_.Exception.Message)"
        return
    }
 
    $rootPath = Resolve-Path $Path | Select-Object -ExpandProperty Path
    $organizedPhotosFullPath = Join-Path -Path $rootPath -ChildPath $OrganizedPhotosFolder
    $thumbnailsFullPath = Join-Path -Path $rootPath -ChildPath $ThumbnailsFolder
    $script:logFilePath = Join-Path -Path $rootPath -ChildPath $LogFile
 
    New-Item -Path $organizedPhotosFullPath -ItemType Directory -Force | Out-Null
    New-Item -Path $thumbnailsFullPath -ItemType Directory -Force | Out-Nul
 
    if (-not $AppendLog) {
        Set-Content -Path $script:logFilePath -Value "Log started at $(Get-Date)" -Force
    }
    Write-Host "Logging actions to: $script:logFilePath"
    #endregion
 
    #region Helper Functions
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
            _Log-Action "ERROR: Could not get MD5 hash for '$FilePath': $($_.Exception.Message)"
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
            _Log-Action "WARNING: Failed to convert Unix timestamp '$UnixTimestamp': $($_.Exception.Message)"
            return $null
        }
    }
    #endregion
 
    $script:processedImageSignatures = @{}
 
    Write-Host "Scanning for image files in '$rootPath'..."
    $imageFiles = Get-ChildItem -Path $rootPath -Recurse -File | Where-Object {
        $_.Extension -match "\.(jpg|jpeg|png|gif|bmp|tiff)$" -and
        $_.DirectoryName -ne $organizedPhotosFullPath -and
        $_.DirectoryName -ne $thumbnailsFullPath
    }
 
    Write-Host "Found $($imageFiles.Count) eligible image files to process."
    Write-Host ("-" * 50)
 
    foreach ($file in $imageFiles) {
        $bitmap = $null
        try {
            if (-not (Test-Path $file.FullName)) {
                _Log-Action "INFO: '$($file.FullName)' no longer exists. Skipping."
                continue
            }
 
            $extractedDateTime = $null
            $isThumbnail = $false
 
            #region Bitmap Handling (for EXIF and dimensions)
            try {
                $bitmap = New-Object System.Drawing.Bitmap($file.FullName)
                $isThumbnail = ($bitmap.Width -lt 600 -and $bitmap.Height -lt 600)
 
                if ($bitmap.PropertyIdList -contains 36867) { # Property ID for 'DateTimeOriginal'
                    try {
                        $exifStr = [System.Text.Encoding]::ASCII.GetString($bitmap.GetPropertyItem(36867).Value).TrimEnd("`0")
                        $extractedDateTime = [datetime]::ParseExact($exifStr, "yyyy:MM:dd HH:mm:ss", $null)
                        Write-Verbose "EXIF date found for '$($file.Name)': $($extractedDateTime)"
                    }
                    catch {
                        _Log-Action "WARNING: Could not parse EXIF date string '$exifStr' from '$($file.FullName)'. Error: $($_.Exception.Message)"
                    }
                }
            }
            catch {
                 _Log-Action "ERROR: Could not create Bitmap object for '$($file.FullName)'. It might be corrupt or not a valid image. Error: $($_.Exception.Message)"
                 Write-Host "[ERROR]     $($file.Name) (Reason: Image file corrupt or invalid)" -ForegroundColor DarkRed
                 continue
            }
            finally {
                if ($bitmap -ne $null) {
                    $bitmap.Dispose()
                    $bitmap = $null
                }
            }
            #endregion
 
            # If EXIF date failed or was invalid, try to parse date from filename
            if (-not $extractedDateTime -or $extractedDateTime.Year -lt 1900 -or $extractedDateTime.Year -gt 2200) {
                $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                Write-Verbose "Attempting to parse date from filename: '$name'"
 
                if ($name -match '(\d{8})_(\d{6})') { # Format: YYYYMMDD_HHmmss
                    $extractedDateTime = [datetime]::ParseExact("$($Matches[1]) $($Matches[2])", "yyyyMMdd HHmmss", $null)
                }
                elseif ($name -match '(\d{14})') { # Format: YYYYMMDDHHmmss
                    $extractedDateTime = [datetime]::ParseExact($Matches[1], "yyyyMMddHHmmss", $null)
                }
                elseif ($name -match '^\d{10}$') { # Format: 10-digit Unix timestamp (seconds)
                    $extractedDateTime = _Convert-UnixTimestamp -UnixTimestamp ([long]$Matches[0])
                }
                elseif ($name -match '^\d{13}$') { # Format: 13-digit Unix timestamp (milliseconds)
                    $extractedDateTime = _Convert-UnixTimestamp -UnixTimestamp ([long]$Matches[0] / 1000)
                }
            }
 
            if (-not $extractedDateTime -or $extractedDateTime.Year -lt 1900 -or $extractedDateTime.Year -gt 2200) {
                _Log-Action "SKIPPED: '$($file.FullName)' - No valid date found in EXIF or filename."
                Write-Host "[SKIPPED]   $($file.Name) (Reason: No valid date found)" -ForegroundColor Yellow
                continue
            }
 
            $fileHash = _Get-FileHashMD5 -FilePath $file.FullName
            if (-not $fileHash) {
                Write-Host "[ERROR]     $($file.Name) (Reason: Could not calculate MD5 hash)" -ForegroundColor DarkRed
                continue
            }
 
            $destinationFolder = if ($isThumbnail) { $thumbnailsFullPath } else { $organizedPhotosFullPath }
            # Using U+A789 (MODIFIER LETTER COLON) as it's a valid character for Windows filenames.
            $baseFileName = $extractedDateTime.ToString("yyyy-MM-dd HH꞉mm꞉ss")
 
            $newFileNameCandidate = $baseFileName + $file.Extension
            $targetNewPath = Join-Path -Path $destinationFolder -ChildPath $newFileNameCandidate
 
            $finalNewPath = $targetNewPath
            $counter = 0
            while (Test-Path $finalNewPath) {
                $counter++
                $tempNewFileName = "$baseFileName ($counter)$($file.Extension)"
                $finalNewPath = Join-Path -Path $destinationFolder -ChildPath $tempNewFileName
            }
 
            # Check for duplicates based on unique signature (extracted timestamp + file content hash)
            $signatureKey = "$($extractedDateTime.Ticks)-$fileHash"
            if ($script:processedImageSignatures.ContainsKey($signatureKey)) {
                $processedAsPath = $script:processedImageSignatures[$signatureKey]
                if ($PSCmdlet.ShouldProcess($file.FullName, "Delete as duplicate of '$processedAsPath'")) {
                    _Log-Action "DELETED: '$($file.FullName)' -> Duplicate of file processed as '$processedAsPath'."
                    Write-Host "[DELETED]   $($file.Name) (Reason: Duplicate of $($processedAsPath | Split-Path -Leaf))" -ForegroundColor Red
                    Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
                }
                continue
            }
            else {
                $script:processedImageSignatures[$signatureKey] = $finalNewPath
            }
 
            # Determine if the file is already correctly named and in the exact target directory
            $isAlreadyCorrectlyNamedAndInPlace = (
                ([System.IO.Path]::GetFileName($file.FullName) -eq ([System.IO.Path]::GetFileName($targetNewPath))) -and
                ([System.IO.Path]::GetDirectoryName($file.FullName) -eq $destinationFolder)
            )
 
            if ($isAlreadyCorrectlyNamedAndInPlace) {
                if ($PSCmdlet.ShouldProcess($file.FullName, "Move (already correctly named) to '$finalNewPath'")) {
                    Move-Item -Path $file.FullName -Destination $finalNewPath -Force -ErrorAction Stop
                    _Log-Action "MOVED: '$($file.FullName)' -> '$finalNewPath' (Already named correctly, confirmed move to organized folder)."
                    Write-Host "[MOVED]     $($file.Name) -> $($finalNewPath | Split-Path -Leaf) (Already correct, just moved)" -ForegroundColor Cyan
                } else {
                    _Log-Action "SKIPPED MOVE: '$($file.FullName)' - Already named correctly and in target folder, user opted not to move."
                    Write-Host "[SKIPPED]   $($file.Name) (Reason: Already named correctly, user opted not to move)" -ForegroundColor Yellow
                }
            }
            else {
                if ($PSCmdlet.ShouldProcess($file.FullName, "Rename and Move to '$finalNewPath'")) {
                    Move-Item -Path $file.FullName -Destination $finalNewPath -Force -ErrorAction Stop
                    _Log-Action "PROCESSED: '$($file.FullName)' -> '$finalNewPath'"
                    Write-Host "[PROCESSED] $($file.Name) -> $($finalNewPath | Split-Path -Leaf)" -ForegroundColor Green
                }
            }
 
        }
        catch {
            _Log-Action "ERROR: A critical error occurred while processing '$($file.FullName)': $($_.Exception.Message)"
            $fileNameForError = if ($file) { $file.Name } else { "an unknown file" }
            Write-Host "[ERROR]     $fileNameForError (Reason: $($_.Exception.Message))" -ForegroundColor DarkRed
        }
        finally {
            if ($bitmap -ne $null) {
                $bitmap.Dispose()
            }
        }
    }
 
    Write-Host ("-" * 50)
    Write-Host "Image organization complete. See log file for detailed actions."
} #Remove this to run# ; Rename-ImagesByExifOrFilename
