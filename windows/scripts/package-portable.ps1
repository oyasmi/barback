[CmdletBinding()]
param(
    [ValidateSet('x64','arm64')][string]$Architecture='x64',
    [string]$Version='0.3.2.0',
    [switch]$FrameworkDependent
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Use a four-part version.' }
Push-Location (Join-Path $PSScriptRoot '..')
try {
    # A fresh directory prevents stale dependencies from entering the archive.
    $name="Barback-$Version-$Architecture-portable"
    if ($FrameworkDependent) { $name+='-framework-dependent' }
    $selfContainedValue=if ($FrameworkDependent) { 'false' } else { 'true' }
    $stage=Join-Path (Get-Location) "artifacts/portable/$name-$([guid]::NewGuid().ToString('N'))"
    New-Item $stage -ItemType Directory -Force | Out-Null
    foreach ($project in @('src/Barback.App','src/Barback.ConsoleHost')) {
        # English resources are embedded; the UI additionally supports simplified Chinese.
        & dotnet publish $project -c Release -r "win-$Architecture" --self-contained $selfContainedValue -p:SatelliteResourceLanguages=zh-Hans -p:Platform=$Architecture -p:RestoreLockedMode=true -p:NuGetAudit=false -p:PublishSingleFile=false -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false -m:1 -o $stage
        if ($LASTEXITCODE) { throw "Portable publish failed: $project" }
    }
    Copy-Item packaging/Assets $stage -Recurse -Force
    $requiredFiles=@('Barback.App.exe','Barback.ConsoleHost.exe','Assets/Barback.ico','zh-Hans/Barback.App.resources.dll')
    if (!$FrameworkDependent) { $requiredFiles+=@('coreclr.dll','hostfxr.dll') }
    foreach ($required in $requiredFiles) {
        if (!(Test-Path (Join-Path $stage $required) -PathType Leaf)) { throw "Portable output is missing: $required" }
    }
    $runtimeNote=if ($FrameworkDependent) {
        'Requires an installed .NET 10 Desktop Runtime for the matching CPU architecture. Download: https://dotnet.microsoft.com/en-us/download/dotnet/10.0'
    } else { 'Includes the .NET runtime; no separate .NET runtime installation is required.' }
    @"
Barback for Windows (portable)

Extract the entire ZIP into a folder, then launch Barback.App.exe as a standard user.
Keep Barback.ConsoleHost.exe, Assets and all DLLs alongside the application.
No MSIX installation is required.
$runtimeNote
Requires Windows 10 build 19041 or later, with the matching CPU architecture.
Includes English and simplified Chinese resources; other locales fall back to English.

Data is stored in %LOCALAPPDATA%\Barback\Dev, shared with unpackaged development
builds. This is an installation-free build; data does not travel with the folder.
Export configuration from Settings to move it to another PC. Secrets use Windows
user DPAPI and must be entered again on another PC/user account.
The built-in Windows login startup setting requires an MSIX installation.
Close the application and stop its tasks before replacing its files for an upgrade.
This remains a development candidate; see windows/docs/implementation-status.md
in the source repository for the validation status.
"@ | Set-Content (Join-Path $stage 'README-portable.txt') -Encoding UTF8
    New-Item dist -ItemType Directory -Force | Out-Null
    $archive=Join-Path (Get-Location) "dist/$name.zip"
    $compression=if ([Enum]::GetNames([IO.Compression.CompressionLevel]) -contains 'SmallestSize') {
        [IO.Compression.CompressionLevel]::SmallestSize
    } else { [IO.Compression.CompressionLevel]::Optimal }
    $temporaryArchive=Join-Path (Get-Location) "dist/$name-$([guid]::NewGuid().ToString('N')).zip"
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $temporaryArchive, $compression, $false)
    Move-Item -LiteralPath $temporaryArchive -Destination $archive -Force
    Get-FileHash $archive -Algorithm SHA256 | Format-List
    Write-Output "Portable executable: $(Join-Path $stage 'Barback.App.exe')"
    Write-Output "Portable archive: $archive"
} finally { Pop-Location }
