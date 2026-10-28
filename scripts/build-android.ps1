param(
    [ValidateSet('debug', 'release')][string]$Mode = 'debug',
    [switch]$Publish,
    [string]$Aapt = $env:FAMILY_AAPT
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$buildTemp = Join-Path (Get-Location) 'runtime/build-temp'
New-Item -ItemType Directory -Force -Path $buildTemp | Out-Null
$env:TEMP = $buildTemp
$env:TMP = $buildTemp
foreach ($appName in @('parent_app', 'kids_app')) {
    Push-Location "apps/$appName"
    try { flutter build apk "--$Mode"; if ($LASTEXITCODE -ne 0) { throw "Build failed: $appName" } }
    finally { Pop-Location }
    if ($Publish) {
        if (-not $Aapt) {
            $sdkRoot = $env:ANDROID_HOME
            if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
            if (-not $sdkRoot) { $sdkRoot = Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
            $Aapt = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'build-tools') -Directory |
                Sort-Object { [version]($_.Name -replace '-.*$', '') } -Descending |
                ForEach-Object { Join-Path $_.FullName 'aapt.exe' } |
                Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        }
        if (-not $Aapt) { throw 'aapt not found. Set FAMILY_AAPT to the Android SDK build-tools/aapt executable.' }
        . "$PSScriptRoot/go-env.ps1"
        $clientApp = if ($appName -eq 'kids_app') { 'kids' } else { 'parent' }
        $apkFile = Join-Path (Get-Location) "apps/$appName/build/app/outputs/flutter-apk/app-$Mode.apk"
        go -C server run ./cmd/family-video publish-apk -app $clientApp -apk $apkFile -aapt $Aapt
        if ($LASTEXITCODE -ne 0) { throw "APK publication failed: $appName" }
    }
}
