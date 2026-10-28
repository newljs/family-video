param([switch]$NativeAndroid)
$ErrorActionPreference = 'Stop'
$checkRoot = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/go-env.ps1"
Push-Location $checkRoot
try {
    go -C server test ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go tests failed' }
    go -C server vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go vet failed' }
    foreach ($package in @('apps/parent_app', 'apps/kids_app', 'packages/family_api', 'packages/family_models', 'packages/video_player_android')) {
        Push-Location $package
        try {
            flutter pub get
            if ($LASTEXITCODE -ne 0) { throw "Dependency resolution failed: $package" }
            flutter analyze --no-fatal-infos
            if ($LASTEXITCODE -ne 0) { throw "Flutter analysis failed: $package" }
            if (Test-Path -LiteralPath 'test') {
                flutter test
                if ($LASTEXITCODE -ne 0) { throw "Flutter tests failed: $package" }
            }
        } finally { Pop-Location }
    }
    if ($NativeAndroid) {
        & "$PSScriptRoot/build-tv.ps1"
        if ($LASTEXITCODE -ne 0) { throw 'TV Android checks failed' }
        Push-Location 'apps/kids_app'
        try {
            flutter build apk --debug
            if ($LASTEXITCODE -ne 0) { throw 'Kids Android build failed' }
        } finally { Pop-Location }
        Push-Location 'apps/kids_app/android'
        try {
            if ($IsWindows -or $env:OS -eq 'Windows_NT') { & .\gradlew.bat :video_player_android:testDebugUnitTest :app:assembleDebug }
            else { & bash ./gradlew :video_player_android:testDebugUnitTest :app:assembleDebug }
            if ($LASTEXITCODE -ne 0) { throw 'Android player tests/build failed' }
        } finally { Pop-Location }
        Push-Location 'apps/parent_app'
        try {
            flutter build apk --debug
            if ($LASTEXITCODE -ne 0) { throw 'Parent Android build failed' }
        } finally { Pop-Location }
    }
} finally { Pop-Location }
