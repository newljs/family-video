$projectRoot = Split-Path -Parent $PSScriptRoot
# Use an isolated official toolchain; this machine's global Go source tree is mixed.
$env:GOTOOLCHAIN = 'go1.26.0'
$env:GOMODCACHE = Join-Path $projectRoot 'runtime/go-mod'
$env:GOCACHE = Join-Path $projectRoot 'runtime/go-build'
if (-not $env:GOPROXY) { $env:GOPROXY = 'https://goproxy.cn,direct' }
