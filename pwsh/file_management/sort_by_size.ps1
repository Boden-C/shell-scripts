(Get-ChildItem -File |
    Select-Object Name,
        @{Name="Type";Expression={"File"}},
        @{Name="Size";Expression={$_.Length}}) +
(Get-ChildItem -Directory |
    Select-Object Name,
        @{Name="Type";Expression={"Directory"}},
        @{Name="Size";Expression={[long](Get-ChildItem -Path $_.FullName -Recurse -File | Measure-Object -Property Length -Sum).Sum}}) |
Sort-Object Size |
Select-Object @{Name="Name";Expression={ $_.Name.Substring(0, [Math]::Min(50, $_.Name.Length)) }},
    Type,
    @{Name="Size (MB)";Expression={ [Math]::Round($_.Size / 1MB, 2) }} |
Format-Table -AutoSize
