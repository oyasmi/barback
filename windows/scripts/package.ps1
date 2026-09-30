[CmdletBinding()]
param(
 [ValidateSet('x64','arm64')][string]$Architecture='x64',
 [string]$Version='0.1.0.0',
 [string]$Publisher='CN=Oyasmi',
 [string]$CertificateThumbprint,
 [string]$TimestampUrl='http://timestamp.digicert.com'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Use a four-part MSIX version.' }
Push-Location (Join-Path $PSScriptRoot '..')
try {
    $sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    $sdk=Get-ChildItem $sdkRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'x64/makeappx.exe') } | Sort-Object Name -Descending | Select-Object -First 1
    if (!$sdk) { throw 'Install the Windows SDK packaging tools.' }
    $makeappx=Join-Path $sdk.FullName 'x64/makeappx.exe'; $signtool=Join-Path $sdk.FullName 'x64/signtool.exe'
    $stage=Join-Path (Get-Location) "artifacts/package/$Architecture/$Version"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item $stage -ItemType Directory -Force | Out-Null
    foreach ($project in @('src/Barback.App','src/Barback.ConsoleHost')) {
        & dotnet publish $project -c Release -r "win-$Architecture" --self-contained true -p:RestoreLockedMode=true -p:Platform=$Architecture -o $stage
        if ($LASTEXITCODE) { throw "Publish failed: $project" }
    }
    Copy-Item packaging/Assets $stage -Recurse -Force
    [xml]$manifest=Get-Content packaging/AppxManifest.xml -Raw
    $manifest.Package.Identity.SetAttribute('Version',$Version); $manifest.Package.Identity.SetAttribute('Publisher',$Publisher); $manifest.Package.Identity.SetAttribute('ProcessorArchitecture',$Architecture)
    $manifest.Save((Join-Path $stage 'AppxManifest.xml'))
    New-Item dist -ItemType Directory -Force | Out-Null
    $package=Join-Path (Get-Location) "dist/Barback-$Version-$Architecture.msix"
    & $makeappx pack /d $stage /p $package /o
    if ($LASTEXITCODE) { throw 'MSIX packaging failed.' }
    if ($CertificateThumbprint) {
        & $signtool sign /fd SHA256 /sha1 $CertificateThumbprint /tr $TimestampUrl /td SHA256 $package
        if ($LASTEXITCODE) { throw 'Signing failed. Check that the certificate subject matches Publisher.' }
        & $signtool verify /pa $package
        if ($LASTEXITCODE) { throw 'Signature verification failed.' }
    } else { Write-Warning 'Unsigned build artifact only. A signed package and completed M0/W01–W40 evidence are required for release.' }
    $inventory=& dotnet list src/Barback.App package --include-transitive --format json
    if ($LASTEXITCODE) { throw 'Dependency inventory failed.' }
    $inventoryText=$inventory -join "`n"
    $inventoryText | Set-Content "$package.dependencies.json"
    $resolved=$inventoryText | ConvertFrom-Json
    $components=@()
    foreach ($project in $resolved.projects) {
        foreach ($framework in $project.frameworks) {
            foreach ($dependency in @($framework.topLevelPackages)+@($framework.transitivePackages)) {
                $components+=@{ type='library'; name=$dependency.id; version=$dependency.resolvedVersion; purl="pkg:nuget/$($dependency.id)@$($dependency.resolvedVersion)" }
            }
        }
    }
    $components=$components | Sort-Object { $_.purl } -Unique
    @{ bomFormat='CycloneDX'; specVersion='1.5'; serialNumber="urn:uuid:$([guid]::NewGuid())"; version=1; metadata=@{ timestamp=(Get-Date).ToUniversalTime().ToString('O') }; components=@($components) } | ConvertTo-Json -Depth 10 | Set-Content "$package.sbom.json"
    Get-FileHash $package -Algorithm SHA256 | Format-List
    & dotnet list src/Barback.App package --include-transitive | Out-File "$package.dependencies.txt"
} finally { Pop-Location }
