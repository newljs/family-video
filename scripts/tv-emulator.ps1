param(
    [ValidateSet('start', 'create', 'delete')][string]$Action = 'start',
    [string]$AvdName = 'family_video_tv_api21',
    [string]$AvdHome = $env:FAMILY_AVD_HOME,
    [string]$Image = 'system-images;android-21;default;x86_64',
    [ValidateRange(512, 8192)][int]$DataPartitionMB = 2048,
    [switch]$WipeData
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
# The name becomes a directory that delete removes recursively.
if ($AvdName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') { throw "Invalid AVD name: $AvdName" }

$sdkRoot = $env:ANDROID_HOME
if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
if (-not $sdkRoot) {
    $localProperties = Join-Path $projectRoot 'apps/tv_app/local.properties'
    if (Test-Path -LiteralPath $localProperties) {
        $sdkLine = Get-Content -LiteralPath $localProperties | Where-Object { $_ -match '^sdk.dir=' } | Select-Object -First 1
        if ($sdkLine) { $sdkRoot = $sdkLine.Substring(8).Replace('\\', '\').Replace('\:', ':') }
    }
}
if (-not $sdkRoot) { $sdkRoot = Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
if (-not (Test-Path -LiteralPath $sdkRoot)) { throw 'Set ANDROID_HOME to the Android SDK directory.' }

$sdkRoot = [IO.Path]::GetFullPath($sdkRoot).TrimEnd('\')
$avdmanager = Join-Path $sdkRoot 'cmdline-tools/latest/bin/avdmanager.bat'
$emulator = Join-Path $sdkRoot 'emulator/emulator.exe'
if (-not (Test-Path -LiteralPath $avdmanager)) { throw "avdmanager not found: $avdmanager" }
if (-not (Test-Path -LiteralPath $emulator)) { throw "emulator not found: $emulator" }

# avdmanager needs JDK 17+ and exits 0 without it, so resolve the same JDK the
# Gradle builds use instead of trusting the exit code alone.
if (-not $env:JAVA_HOME) {
    $flutterSettings = Join-Path $env:APPDATA '.flutter_settings'
    if (Test-Path -LiteralPath $flutterSettings) {
        $flutterJdk = (Get-Content -Raw -LiteralPath $flutterSettings | ConvertFrom-Json).'jdk-dir'
        if ($flutterJdk) { $env:JAVA_HOME = $flutterJdk }
    }
}
if ($env:JAVA_HOME) { $env:PATH = "$env:JAVA_HOME\bin;$env:PATH" }

if (-not $AvdHome) {
    # Keep AVDs on the SDK drive but outside the repository: one device image is
    # several GB because QEMU preallocates the whole data partition.
    $AvdHome = Join-Path (Split-Path -Parent $sdkRoot) 'avd-home'
}
$AvdHome = [IO.Path]::GetFullPath($AvdHome).TrimEnd('\')
$repoPrefix = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\') + [IO.Path]::DirectorySeparatorChar
if (($AvdHome + [IO.Path]::DirectorySeparatorChar).StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "AVD home must stay outside the repository: $AvdHome"
}
$env:ANDROID_AVD_HOME = $AvdHome
New-Item -ItemType Directory -Force -Path $AvdHome | Out-Null
Write-Output "AVD home: $AvdHome"

$avdDir = Join-Path $AvdHome "$AvdName.avd"
$exists = Test-Path -LiteralPath $avdDir

if ($Action -eq 'delete') {
    if (-not $exists) { Write-Output "No AVD to delete at $avdDir"; return }
    & $avdmanager delete avd -n $AvdName 2>&1 | Out-Null
    # avdmanager drops the .ini registration yet happily leaves the multi-GB
    # data directory behind, and reclaiming that directory is the whole point.
    if (Test-Path -LiteralPath $avdDir) {
        Remove-Item -LiteralPath $avdDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $iniPath = Join-Path $AvdHome "$AvdName.ini"
    if (Test-Path -LiteralPath $iniPath) { Remove-Item -LiteralPath $iniPath -Force }
    if (Test-Path -LiteralPath $avdDir) {
        throw "AVD deletion failed for ${AvdName}: files are still locked, stop the emulator first."
    }
    Write-Output "Deleted AVD $AvdName"
    return
}

if (-not $exists) {
    Write-Output "Creating AVD $AvdName from $Image"
    'no' | & $avdmanager create avd -n $AvdName -k $Image --path $avdDir --force
    $createExit = $LASTEXITCODE
    $configFile = Join-Path $avdDir 'config.ini'
    if ($createExit -ne 0 -or -not (Test-Path -LiteralPath $configFile)) {
        throw "AVD creation failed for $AvdName (avdmanager exit $createExit). Set JAVA_HOME to JDK 17+."
    }
    # The android-21 image asks for a 10G data partition and QEMU preallocates
    # all of it on first boot, so cap it before anything starts the device.
    $config = Get-Content -Raw -LiteralPath $configFile
    $patched = $config -replace '(?m)^disk\.dataPartition\.size=.*$', "disk.dataPartition.size=${DataPartitionMB}M"
    if ($patched -notmatch "(?m)^disk\.dataPartition\.size=${DataPartitionMB}M$") {
        $patched = "$($patched.TrimEnd())`r`ndisk.dataPartition.size=${DataPartitionMB}M`r`n"
    }
    Set-Content -LiteralPath $configFile -Value $patched -NoNewline -Encoding ascii
    Write-Output "Data partition capped at ${DataPartitionMB}M in config.ini"
}

if ($Action -eq 'create') {
    Write-Output "AVD ready: $avdDir"
    return
}

# The snapshot flags keep the emulator from writing a multi-GB RAM snapshot on
# top of the data image.
$emuArgs = @('-avd', $AvdName, '-no-snapshot-load', '-no-snapshot-save', '-no-boot-anim')
if ($WipeData) { $emuArgs += '-wipe-data' }
Write-Output "Starting emulator: $AvdName"
& $emulator @emuArgs
exit $LASTEXITCODE
