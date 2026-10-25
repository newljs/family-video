$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path -LiteralPath '.downloader-venv/Scripts/python.exe')) {
    uv venv --python 3.11 .downloader-venv
    if ($LASTEXITCODE -ne 0) { throw 'Downloader environment failed' }
}
uv pip install --python .downloader-venv/Scripts/python.exe -r server/downloader-requirements.lock
if ($LASTEXITCODE -ne 0) { throw 'F2 installation failed' }
Write-Host 'F2 installed from a pinned upstream commit (see downloader-requirements.lock).'
Write-Host 'Set up Douyin login locally with scripts/configure-douyin.ps1; the Go server automatically reads runtime/private/f2.yaml.'
