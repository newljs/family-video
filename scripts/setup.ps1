$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot
& "$PSScriptRoot/build-server.ps1"
foreach ($appName in @('parent_app', 'kids_app')) {
    Push-Location "apps/$appName"
    try { flutter pub get; if ($LASTEXITCODE -ne 0) { throw 'Flutter dependencies failed' } }
    finally { Pop-Location }
}
Write-Host 'Setup complete. Run bin/family-video.exe. HTTP and background downloads start together.'
Write-Host 'Parent and kids apps connect using only the home server URL. No key or pairing code required.'
