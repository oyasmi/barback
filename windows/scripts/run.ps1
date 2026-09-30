[CmdletBinding()]
param([ValidateSet('x64','arm64')][string]$Architecture='x64')
$ErrorActionPreference='Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    $output="artifacts/dev/$Architecture"
    & dotnet publish src/Barback.App -c Debug -r "win-$Architecture" --self-contained true -p:RestoreLockedMode=true -o $output
    if ($LASTEXITCODE) { throw 'Application publish failed.' }
    & dotnet publish src/Barback.ConsoleHost -c Debug -r "win-$Architecture" --self-contained true -p:RestoreLockedMode=true -o $output
    if ($LASTEXITCODE) { throw 'ConsoleHost publish failed.' }
    Copy-Item packaging/Assets $output -Recurse -Force
    & (Join-Path (Get-Location) "$output/Barback.App.exe")
} finally { Pop-Location }
