# Shell Scripts
Various scripts that can be easily executed in the shell for file management, system configuration, etc.

Available in
- Linux/MacOS (Bash)
- Windows (Powershell, Batch)

## Featured: Detect Process Locking File
This handy one-liner prompts for your file, automatically gets the process that is locking your file, and prompts to kill it


Windows Powershell:

```pwsh
$f=Read-Host "File";$t="$env:TEMP\h.exe";iwr https://live.sysinternals.com/handle.exe -OutF $t;& $t -accepteula $f|sls '^(\S+).*pid: (\d+)'|%{$n=$_.Matches.Groups[1].Value;$p=$_.Matches.Groups[2].Value;if((Read-Host "Kill $n ($p)? (y)")-eq 'y'){kill $p}}
```


Windows Batch (cmd):

```batch
set /p f=File: & curl -so %TEMP%\h.exe https://live.sysinternals.com/handle.exe & for /f "tokens=1,3" %a in ('%TEMP%\h.exe -accepteula %f% ^| find "pid:"') do choice /m "Kill %a (%b)" & if not errorlevel 2 taskkill /f /pid %b
```
