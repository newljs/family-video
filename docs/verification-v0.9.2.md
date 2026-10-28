# v0.9.2 首次使用发现家庭服务器

日期：2026-10-26。Go 服务端 `0.9.2`，家长端 `0.9.2+12`，儿童端 `0.9.2+15`，数据库仍为 schema v6。

## 使用与升级

首次安装、清除地址或未配置时，Android 两端展示“搜索家庭服务器”，自动搜索约 4 秒。找到的服务逐个显示电脑名称、地址和连接按钮；即使只有一个结果也由用户选择。未找到时可重新搜索，或展开“扫码或手动输入”。已有地址的再次启动继续先展示缓存、后台连接，不等待扫描。桌面调试版本需主动点击搜索。

需要同时更新 Go 服务端。默认 HTTP TCP 8765，发现固定使用 UDP 8766，修改 HTTP 端口不影响发现。Windows 私有网络防火墙需允许服务程序接收 UDP 8766 和配置的 HTTP TCP 端口。不要开放到公网。此轮没有自动修改系统防火墙。

电脑与设备需处于可互通的 IPv4 局域网；电脑可使用同一路由器的有线连接。访客网络、无线 AP 隔离、跨子网、VPN 路由或仅 IPv6 网络可能阻断广播。服务端只监听回环地址时不启用发现；多个服务进程争用 UDP 端口时，未占到端口的实例仍能通过扫码/手动连接。旧服务端没有发现响应，但仍可手动连接。

当前 Android 构建使用现有 INTERNET 权限。以后升级至 target SDK 37+ 时，需接入 ACCESS_LOCAL_NETWORK 运行时授权，再开始发现与 HTTP 访问；Android 16 主动启用局域网限制的测试环境也需另行验收。参考 [Android 局域网权限](https://developer.android.com/privacy-and-security/local-network-permission) 与 [Flutter 局域网权限说明](https://docs.flutter.dev/platform-integration/android/local-network-permission)。

## 协议与资源边界

- 请求发送到 IPv4 广播 UDP 8766，携带 service=family-video、kind=discover、protocol=1 和 32 位十六进制 nonce；每秒重发一次，4 秒结束。
- 服务回复 nonce、kind=server、随机 instance_id、主机名、实际 HTTP 端口和服务版本，不发送凭据或内容。服务端限制私有来源、报文长度和回复频率。
- 客户端从 UDP 来源构造 HTTP 地址，忽略报文中的 URL；校验本次 nonce、协议、端口、来源和实例格式。最多验证 16 个端点，每端点最多尝试两次；通过 900ms 截止的健康检查后才进入选择列表，按实例去重。
- 发现只验证服务能力，不认证电脑身份，符合现有免认证家庭局域网模式。点选后再走既有保存/验证流程。没有自动选中多台服务器中的任意一台。
- 搜索结束、取消、页面销毁、进入后台和选中结果均会关闭 socket、HTTP client 和计时器；后台不持续扫描。

## 验证记录

- Go `test ./...`、`vet ./...` 通过，包含发现协议、错误请求、实际 UDP 回环收发和取消关闭测试。
- 双端与共享包、播放器适配包 Flutter 分析通过；家长端仍有 4 条原有弃用 info，无分析错误。`scripts/check.ps1` 执行后修正儿童端测试中的输入焦点/滚动等待，使用 `--no-pub` 重跑儿童端和后续共享包全部检查通过。
- 家长端 12 项、儿童端 40 项、共享 API 17 项、播放器适配包 58 项测试通过，共 127 项。新增覆盖 nonce 过滤、重复回复去重、UDP 来源地址构造、HTTP 不兼容过滤、无响应截止与资源释放、多服务需用户选择、首次选择后保存地址、再次启动不扫描，以及家长断开后重连仍能同步。扫码/手动入口、大字体和键盘布局也完成回归。
- 用编译后的 Go 可执行程序在隔离数据目录、关闭下载 worker、随机 HTTP 端口的条件下完成本机联调：实际 UDP 回复包含正确 nonce、实例 ID 和 HTTP 端口，随后真实 `/health` 返回 Go / 0.9.2。测试进程已关闭。
- `scripts/build-android.ps1` 串行构建双端 debug APK 成功；aapt 核对家长 `0.9.2+12`、儿童 `0.9.2+15`，两端 target SDK 均为 36。两端 kernel 产物时间晚于最终源文件修改时间。

生成的服务程序为 `bin/family-video-v0.9.2.exe`；双端 APK 位于 `apps/parent_app/build/app/outputs/flutter-apk/app-debug.apk` 与 `apps/kids_app/build/app/outputs/flutter-apk/app-debug.apk`。未重启当前家庭服务，也未修改已发布 APK 清单。

本机 UDP 回环、真实本机 HTTP 与模拟客户端测试不等同于真实 Android Wi-Fi 验收；尚未验证手机/平板、电视遥控、具体路由器广播转发、防火墙首次提示及正式签名覆盖安装。
