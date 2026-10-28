param(
    [ValidateSet('trial', 'debug', 'release')][string]$Mode = 'trial',
    [switch]$Publish,
    [string]$JavaHome = $env:JAVA_HOME,
    [string]$Aapt = $env:FAMILY_AAPT
)
$ErrorActionPreference = 'Stop'
$tvRoot = Split-Path -Parent $PSScriptRoot
if (-not $PSBoundParameters.ContainsKey('JavaHome')) {
    $flutterSettings = Join-Path $env:APPDATA '.flutter_settings'
    if (Test-Path -LiteralPath $flutterSettings) {
        $flutterJdk = (Get-Content -Raw -LiteralPath $flutterSettings | ConvertFrom-Json).'jdk-dir'
        if ($flutterJdk) { $JavaHome = $flutterJdk }
    }
}
if (-not $JavaHome) { throw 'Set JAVA_HOME to JDK 17+ or pass -JavaHome.' }
$env:JAVA_HOME = $JavaHome
$sdkRoot = $env:ANDROID_HOME
if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
$localProperties = Join-Path $tvRoot 'apps/tv_app/local.properties'
if (-not $sdkRoot -and (Test-Path -LiteralPath $localProperties)) {
    $sdkLine = Get-Content -LiteralPath $localProperties | Where-Object { $_ -match '^sdk.dir=' } | Select-Object -First 1
    if ($sdkLine) { $sdkRoot = $sdkLine.Substring(8).Replace('\\', '\').Replace('\:', ':') }
}
if (-not $sdkRoot) { $sdkRoot = Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
if (-not (Test-Path -LiteralPath $sdkRoot)) { throw 'Set ANDROID_HOME to the Android SDK directory.' }
$env:ANDROID_HOME = $sdkRoot
$taskSuffix = (Get-Culture).TextInfo.ToTitleCase($Mode)
Push-Location (Join-Path $tvRoot 'apps/tv_app')
try {
    & ./gradlew.bat ":app:assemble$taskSuffix" :app:testDebugUnitTest :app:lintDebug --console=plain
    if ($LASTEXITCODE -ne 0) { throw 'TV build or checks failed' }
} finally { Pop-Location }
$apkFile = Join-Path $tvRoot "apps/tv_app/app/build/outputs/apk/$Mode/app-$Mode.apk"
$artifactDir = Join-Path $tvRoot 'bin'
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
$artifact = Join-Path $artifactDir "family-video-tv-$Mode.apk"
Copy-Item -LiteralPath $apkFile -Destination $artifact
Get-Item -LiteralPath $artifact | Select-Object FullName,Length
if ($Publish) {
    if (-not $Aapt) {
        $Aapt = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'build-tools') -Directory |
            Sort-Object { [version]($_.Name -replace '-.*$', '') } -Descending |
            ForEach-Object { Join-Path $_.FullName 'aapt.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $Aapt) { throw 'aapt not found. Set FAMILY_AAPT.' }
    . "$PSScriptRoot/go-env.ps1"
    go -C (Join-Path $tvRoot 'server') run ./cmd/family-video publish-apk -app tv -apk $artifact -aapt $Aapt
    if ($LASTEXITCODE -ne 0) { throw 'TV APK publication failed' }
}
