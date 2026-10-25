$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path bin/family-video.exe)) { & "$PSScriptRoot/build-server.ps1" }
& ./bin/family-video.exe
