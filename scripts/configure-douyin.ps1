param([switch]$FromClipboard)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$dataPath = if ($env:FAMILY_DATA_DIR) { $env:FAMILY_DATA_DIR } else { 'runtime' }
$envFile = Join-Path $projectRoot '.env'
if (-not $env:FAMILY_DATA_DIR -and (Test-Path -LiteralPath $envFile)) {
    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -match '^\s*FAMILY_DATA_DIR\s*=\s*(.+)\s*$') { $dataPath = $Matches[1].Trim().Trim('"', "'") }
    }
}
if (-not [IO.Path]::IsPathRooted($dataPath)) { $dataPath = Join-Path $projectRoot $dataPath }
$privatePath = Join-Path $dataPath 'private'
$configPath = Join-Path $privatePath 'f2.yaml'
Write-Host '1. 在家庭电脑浏览器打开 https://www.douyin.com 并正常登录。'
Write-Host '2. 按 F12 → 网络，刷新页面，选一个 douyin.com 请求。'
Write-Host '3. 在请求标头中复制 Cookie 的完整值（不是 Set-Cookie）。'
Write-Host '内容只写入本机下载配置，不需要发到聊天中。'
if ($FromClipboard) {
    $cookie = (Get-Clipboard -Raw).Trim()
} else {
    $secureCookie = Read-Host '粘贴 Cookie 后回车（输入隐藏）' -AsSecureString
    $cookie = ([PSCredential]::new('douyin', $secureCookie)).GetNetworkCredential().Password.Trim()
}
$cookie = $cookie -replace '^(?i)cookie:\s*', ''
if ($cookie -notmatch '=' -or $cookie -cmatch '[\r\n\x00-\x1f\x7f-\uffff]') {
    throw '格式无效，请复制 Cookie 标头的一整行值，不包含换行。'
}
New-Item -ItemType Directory -Path $privatePath -Force | Out-Null
# JSON is a YAML subset and avoids escaping mistakes with cookie punctuation.
@{ douyin = @{ cookie = $cookie } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding utf8
$cookie = $null
Write-Host "已保存至 $configPath。新版服务会在下次下载时读取；回家长端点击失败任务的重试即可。"
Write-Host '若设置过 FAMILY_F2_CONFIG，请将它指向上述路径，重启服务后再试。'
