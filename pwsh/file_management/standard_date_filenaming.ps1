Add-Type -AssemblyName System.Drawing; Get-ChildItem -Path (Get-Location) -Recurse -File | ForEach-Object {
    # Common image extensions.
    if ($_.Extension -match "\.(jpg|jpeg|png|gif|bmp|tiff)$") {
        try {
            # Create Bitmap object for EXIF data.
            $bitmap = New-Object System.Drawing.Bitmap($_.FullName);

            # Check for 'DateTimeOriginal' EXIF property (ID 36867).
            if ($bitmap.PropertyIdList -contains 36867) {
                $dateTimeOriginalString = [System.Text.Encoding]::ASCII.GetString($bitmap.GetPropertyItem(36867).Value).TrimEnd("`0");
                $bitmap.Dispose(); 
                $bitmap = $null;

                $dateTime = [datetime]::ParseExact($dateTimeOriginalString, "yyyy:MM:dd HH:mm:ss", $null);

                # Format base filename with 'Modifier Letter Colon' (U+A789).
                $baseFileName = $dateTime.ToString("yyyy-MM-dd HH꞉mm꞉ss");
                $newFileName = $baseFileName + $_.Extension;
                $newPath = Join-Path -Path $_.DirectoryName -ChildPath $newFileName;

                $counter = 0;
                while (Test-Path $newPath) {
                    $counter++;
                    $newFileName = $baseFileName + " ($counter)" + $_.Extension;
                    $newPath = Join-Path -Path $_.DirectoryName -ChildPath $newFileName;
                }

                Rename-Item -Path $_.FullName -NewName $newFileName -Force;
                Write-Host "Renamed '$($_.Name)' to '$newFileName'";
            } else {
                Write-Warning "Skipping '$($_.Name)' - No 'DateTimeOriginal' EXIF data found.";
            }
        } catch {
            Write-Error "Error processing file '$($_.Name)': $($_.Exception.Message)";
        } finally {
            if ($bitmap -ne $null) {
                $bitmap.Dispose();
            }
        }
    }
}