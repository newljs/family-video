$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/go-env.ps1"
Set-Location $projectRoot
New-Item -ItemType Directory -Force bin | Out-Null
go -C server build -trimpath -o ../bin/family-video.exe ./cmd/family-video
if ($LASTEXITCODE -ne 0) { throw 'Go server build failed' }
