$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$buildTemp = Join-Path (Get-Location) 'runtime/build-temp'
New-Item -ItemType Directory -Force -Path $buildTemp | Out-Null
$env:TEMP = $buildTemp
$env:TMP = $buildTemp
foreach ($appName in @('parent_app', 'kids_app')) {
    Push-Location "apps/$appName"
    try { flutter build apk --debug; if ($LASTEXITCODE -ne 0) { throw "Build failed: $appName" } }
    finally { Pop-Location }
}
