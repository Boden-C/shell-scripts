Get-ChildItem -Recurse -File -Filter "*" | ForEach-Object { "# $($_.Name)`n`n" + (Get-Content $_.FullName -Raw) } | Set-Clipboard
