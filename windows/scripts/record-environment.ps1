[CmdletBinding()]
param([string]$OutputDirectory='artifacts/evidence')
$ErrorActionPreference='Stop'
New-Item $OutputDirectory -ItemType Directory -Force | Out-Null
$os=Get-CimInstance Win32_OperatingSystem
[ordered]@{ date=(Get-Date).ToUniversalTime().ToString('O'); caption=$os.Caption; version=$os.Version; build=$os.BuildNumber; architecture=$env:PROCESSOR_ARCHITECTURE; session=$env:SESSIONNAME; sdk=(& dotnet --version); commit=(& git rev-parse HEAD) } | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'environment.json')
Get-HotFix | Select-Object HotFixID,InstalledOn | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'patches.json')
