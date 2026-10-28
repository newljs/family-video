# 小小放映室 · Family Video

家庭局域网视频系统：家长收集内容，家庭电脑下载存储，孩子用 Flutter 安卓平板或电视观看。视频处理成功后直接可看，无需审核或发布。

Go 单进程提供 HTTP、SQLite 任务队列、下载调度、FFmpeg 处理和媒体服务。F2 SDK 在独立 Python 环境中负责抖音作品解析；主服务不需要 FastAPI、Uvicorn 或 Python worker。

家长端收集箱首页提供「查看待同步收集箱」和「查看导入任务列表」入口：待同步列表每次显示 20 条，上拉继续加载，底部始终保留同步全部待同步内容的按钮；任务列表每页 20 条，顶部固定全部/处理中/失败/已完成筛选。视频库每页 24 条，上拉加载更多，搜索和排序覆盖全库，支持下拉刷新和加载失败重试。服务端与家长端需一同重新构建以使用服务端分页；旧接口数组响应仍兼容。细节见 [家长端列表分页](docs/parent-pagination.md)。

## Android TV 轻量版（v0.1）

新增独立原生客户端 `apps/tv_app`，最低 Android 5.0 / API 21，包名 `cn.familyvideo.tv_app`，可与现有儿童端同时安装。打开搜索家庭电脑后直接全屏播放，上下切换、确认暂停、左键选合集，播完自动下一条并循环。仅一个播放器，不预加载下一条；地址、目录、观看事件和视频缓冲只留在内存，不建立磁盘媒体缓存或保存本地历史。家长设置的每日额度与安静合集继续生效。

运行 `scripts/build-tv.ps1` 生成压缩的体验 APK `bin/family-video-tv-trial.apk`；正式签名使用 `-Mode release`，发布到管理台增加 `-Publish`。新服务的安装包列表支持 `tv`，播放仍兼容原有 v0.9.2 接口。当前直接播放已有 MP4，未增加 720p 转码；老小米电视的安装、声音、解码与待机行为尚需真机验收。操作、零持久化边界及构建见 [TV 使用说明](apps/tv_app/README.md)，验证见 [TV v0.1](docs/verification-tv-v0.1.md)。

## 启动与升级

当前服务端源码为 v0.9.2，家长 APK 为 0.9.2+12，儿童 APK 为 0.9.2+15。构建产物需重新构建并显式发布；本轮已生成的版本化服务程序为 `bin/family-video-v0.9.2.exe`。先在旧服务终端按 Ctrl+C 停止旧进程，再启动：

```powershell
cd D:\demo\AI\family-video
.\bin\family-video-v0.9.2.exe
```

默认监听 `http://0.0.0.0:8765`。健康检查 `http://127.0.0.1:8765/health` 应返回 `backend: go`、`version: 0.9.2`、`access_mode: open_lan`、`content_mode: direct`、`library_mode: managed`。

首次使用两端会自动搜索同一局域网的家庭电脑，点选即可连接，无需填写 IP 地址、密钥或配对码。自动发现需要服务端同步升级至 v0.9.2；仍可展开“扫码或手动输入”，连接 `http://电脑局域网IP:8765`。访问模式保持免认证局域网直连。

已有数据目录可以沿用。当前 schema 为 v6。v1/v2 升级保留 `runtime/database/before-v3-*.sqlite3` 快照，v3–v5 升级生成 `before-v6-*.sqlite3`；迁移在事务中建立观看事件与资源索引，原有视频全部直接可看。备份失败则停止升级。程序先监听端口，再迁移数据库，避免旧服务仍占用端口时修改数据。

Ctrl+C 停止服务，执行中任务下次启动恢复。`-worker=false` 可仅启动 HTTP 供诊断。历史 Python 实现在 `legacy/python-server`，不参与当前服务。

## v0.9.2 局域网自动发现

首次启动未配置地址时，Android 两端自动搜索约 4 秒，列出通过 HTTP 健康检查的电脑名称和地址，由用户选择连接；多台电脑不会自动误选。搜索结束可重试，扫码和手动输入始终保留。已有地址时继续走缓存优先启动，不增加每次开机扫描等待。

发现使用 IPv4 局域网广播 UDP `8766`，HTTP 默认 TCP `8765`（自定义 HTTP 端口也可发现）。电脑防火墙需允许这两个端口的家庭局域网访问；访客网络、AP 隔离、跨子网或仅 IPv6 网络可能无法发现，此时可使用扫码/手动入口。服务只绑定回环地址时不提供发现；UDP 端口占用只关闭发现，不影响 HTTP。真机 Wi-Fi 与路由器行为尚未验收，协议、测试和升级说明见 [v0.9.2 验证](docs/verification-v0.9.2.md)。

## v0.9.1 快速进入与后台同步

两端已有服务器地址时，打开先恢复本机保存的目录和上次页签，后台并行同步视频、合集等信息；同步不会锁住整个页面。儿童端先恢复观看额度，并恢复上次视频和播放进度。服务器慢或离线时保留缓存页面，显示轻量状态并在前台退避重试，恢复前台时立即同步。

首次升级需成功同步一次才能建立目录快照。缓存目录不等于完整离线视频：网络视频在拿到新目录和签名之前只展示封面/标题；完整离线下载可直接观看。后台更新和媒体签名轮换不会重建正在使用的播放器。实现、请求超时和验证边界见 [v0.9.1 启动验证](docs/verification-v0.9.1.md)。
## v0.9 可靠性与日常维护

- 家长端接收 Android 系统文字分享，先落入本机收集箱；系统分享在已连接时提交，离线失败后在重新连接/回到前台重试，显示等待连接状态。手动收集仍可手动同步。
- worker 按 F2 作品 ID 去重，不同分享链接可关联已有视频；旧视频缺少身份记录时仍按原分享链接去重。
- 资源库筛选、排序、分页在 SQLite 执行；分类和标签在导入/编辑/迁移事务内维护。
- worker 空闲时每天生成数据库快照与媒体清单；完整备份、校验、恢复到新目录及孤儿文件隔离使用 CLI。
- 更新接口只提供通过校验的已发布 APK；正式构建从环境变量读取签名，缺失时明确失败。

升级快照、签名、APK 发布和备份恢复命令见 [v0.9 运维说明](docs/operations-v0.9.md)。
## 网页管理台

浏览器打开 `http://电脑局域网IP:8765/`（自动跳转 `/admin`），无需安装家长端即可管理：概览（磁盘剩余、各数据目录占用、ffmpeg/下载器/登录配置状态）、抖音分享导入与本地视频上传、任务进度与重试/取消、资源管理（已导入视频的搜索/预览/编辑/下载/删除，含文件大小与 HLS 状态）、合集管理、客户端 APK 安装包下载、抖音 Cookie 配置与解析验证。经 svc 统一入口时访问 `http://127.0.0.1:7777/family-video/admin`。

- 新增接口：`GET /api/system`、`GET|PUT /api/config/douyin`、`POST /api/config/douyin/test`、`GET /api/apps`、`GET /api/apps/{app}/download`；`GET /api/videos` 返回每个视频的 `size_bytes`，`/media/{id}/video` 加 `dl=1` 参数时以附件形式下载（文件名取视频标题）。
- APK 下载只读取已发布清单与哈希命名的文件；版本从 APK 本身提取，按大小和 SHA-256 校验，未发布或损坏时不可下载。运行 `scripts/build-android.ps1 -Publish` 构建并发布，正式包加 `-Mode release`。详见 [v0.9 运维说明](docs/operations-v0.9.md)。
- 页面为零依赖单文件，`//go:embed` 内嵌于 `internal/family/admin.html`，随服务单二进制分发。
- 资源管理支持**分类筛选**（服务端按标题/描述关键词把内容归纳为英语启蒙、语文古诗、数学思维、历史人文、科普百科、动画故事、儿歌音乐、生活习惯、家庭教育等，见 `internal/family/library.go`）、**话题标签筛选**（导入/编辑时提取并保存索引，接口最多返回最高频 120 个）与**分页浏览**（每页 60 条，服务端搜索与排序）；批量操作按页选择。
- 相关接口：`GET /api/library`（offset/limit/search/category/tag/sort）、`GET /api/library/meta`（分类与标签计数）。
- **手机连接二维码**：概览页展示本机局域网地址（`GET /api/server-addresses` 枚举非回环 IPv4，多网卡可切换），生成「App 服务器地址」与「手机版管理台」两个二维码（`GET /qrcode?text=` 服务端渲染 PNG，仅允许 http/https）；安装包页每个已发布的 APK 附「扫码直接下载」二维码。手机与电脑同网扫码即可连接或安装。
- 管理台继承服务的免认证局域网开放模式，请仅在可信家庭网络中使用。
- macOS 上以 LaunchAgent + svc 托管运行（见 `tools/svc/svc.yaml`），FFmpeg 与 F2 下载器环境由 svc 注入的 `PATH`/`FAMILY_*` 环境变量提供；macOS 安装下载器用 `server/downloader-requirements.macos.lock`（原锁中的 pywin32/wmi/shadowcopy 为 Windows 专用）。

## 客户端

儿童端显示名称为“抖音儿童版”，桌面、自适应图标、TV 入口与连接页采用抖音应用条目的原始图标；资源来源见 apps/kids_app/assets/branding/README.md。包名 cn.familyvideo.kids_app 保持不变，可覆盖升级并沿用缓存、喜欢与进度。家长端名称保持原有设置。

**应用内更新**：两端连接服务端后自动调用 `GET /api/update/{app}`（家长 parent / 儿童 kids）比对版本号，服务端存在更新版本（以已发布 APK 的真实版本与构建号为准）时弹窗提示，经系统浏览器下载最新 APK 安装；检查失败静默跳过，不影响使用。旧版本服务端无此接口时同样静默。

**扫码连接**：两端连接页地址输入框带扫码按钮，扫描管理台「手机连接」面板的服务器地址二维码后自动填入并连接；识别 http/https 链接（取 scheme://host:port），非地址二维码忽略继续扫，相机不可用时显示提示并回退手输（`mobile_scanner`，Android 需相机权限）。

- 家长：链接收集、点击粘贴、重复提示、本地上传、任务筛选/取消/重试、下载字节和处理阶段；视频标题/描述搜索、预览、编辑信息和确认删除；合集创建、成员编辑、排序、重命名及删除。视频库按显示宽度虚拟化渲染并降采样解码缩略图，支持按播放/完播/观看时长排序与多选批量删除、批量加入合集；合集创建使用可搜索视频选择器。
- 儿童：黑底全屏推荐流、上下滑动、点击暂停、双击喜欢、喜欢/缓存/合集操作，以及合集、离线、喜欢、个人页。横竖视频按比例居中，标题和播放进度位于底部。播放增强：**长按屏幕 2 倍速**（松开恢复），**左右拖动快进/快退**（居中显示目标时间预览，一屏宽最多两分钟，松手定位；与上下滑切换、双击喜欢、底部进度条拖动互不影响）。**内容刷完后**在第一条继续下拉或最后一条继续上拉，自动拉取服务器最新视频（新内容按推荐顺序追加，当前视频保持播放位置；单次拖动只触发一次，失败时顶部横幅提示且播放不中断）。

**推荐排序与观看统计**：儿童端推荐流分桶排序——完全没播过的最上面（桶内随机、每次启动重新洗牌），播过未完播的居中，已完播的最后；观看过程按真实经过的时间采样，快进、暂停和缓冲不计时，倍速不额外扣额度。待上报队列每约 500ms 保存，每 30 秒按最多 50 条分批上报；事件 ID 在服务端去重，重启重试沿用原 ID，跨日补报按观看日期累计（数据库 schema v6）。该数据同时驱动排序与家长分析。

**每日观看时长**：家长端「连接设置 → 儿童观看时长」设定孩子每天可观看的总时长（0 表示不限制，滑动条 5–240 分钟），并可指定一个合集作为「额度用完后可看」的内容，经 `PUT /api/settings/time-limit` 保存；儿童端经 `GET /api/settings/time-limit` 读取限额与今日已看。时长以服务端按天累计的真实观看为准（`watch_days` 表，数据库 schema v5，超过一个月的旧日期自动清理），同一天多台设备共享额度。播放页顶部在额度充足时显示剩余时间小角标（最后 5 分钟变为红色）。

**安静模式（额度用完，无感知）**：达到每日限额后不弹任何提示、不暂停播放——当前视频自然播完，之后能刷到的只剩家长指定的那个合集：服务端对儿童角色的 `/api/videos` 与 `/api/collections` 静默过滤为该合集（未指定合集则整体隐藏，孩子只会觉得"没有内容了"），搜索、喜欢、离线页签同步收缩；家长角色始终看得到完整视频库。换天后额度重置，目录自动恢复；服务端不可达时儿童端沿用最近一次缓存的限额继续安静收缩，旧服务端无此接口时按不限制处理。注意：设备上已缓存的离线文件在安静模式下不再展示，但文件本身不会被删除。原有的单次连续观看 20 分钟休息提示保留，额度已耗尽时不再叠加显示。
- 刷新失败保留已有列表，搜索包含缓存。打开搜索播放页会暂停首页播放器，返回恢复原来的播放意图。
- 处理中任务每 8 秒刷新；应用进入后台或任务结束后停止轮询。

### 连接可靠性

- 两端共享 `FamilyApi` 持有一个 keep-alive `http.Client`（连接超时 6 秒、空闲 45 秒），刷新不再为每个请求重新握手；GET 在连接被重置或超时时自动重试一次，写请求绝不自动重试，避免重复导入或重复统计。
- 健康检查结果缓存 5 分钟，任务轮询时不再反复探测 `/health`；缩略图也复用独立的长连接。
- 刷新失败后按 5/10/20/40/60 秒退避自动重试；App 回到前台且超过 30 秒未刷新时静默刷新。儿童端在播放页打开期间不主动刷新，避免打断当前视频。
- 服务端对 `/api` JSON 响应启用 gzip（663 个视频的目录 936KB → 约 234KB，合集 249KB → 54KB），APK 下载与媒体文件不压缩；超过 2 秒的 API 请求写入服务日志，便于确认客户端请求是否到达。
- 媒体签名 URL 仍为 24 小时有效；长期挂起后自动或手动刷新目录即可获得新签名。
- 缩略图按视频 ID 在设备缓存目录落盘（family_api 的 `CachedThumbnail`）。服务端为缩略图签发月级稳定签名 URL 并返回 `Cache-Control: max-age`（内容随视频 ID 不变），目录刷新、签名轮换和 App 重启不再重复下载，离线时直接显示缓存封面；缓存目录按 60 天清理已删视频残留。管理台浏览器同样受益于该缓存头。
- 电视具有 TV launcher 和基础方向键/确认键操作，完整焦点及待机恢复仍需真实机型验收。

安装包：

- `apps/parent_app/build/app/outputs/flutter-apk/app-debug.apk`
- `apps/kids_app/build/app/outputs/flutter-apk/app-debug.apk`

服务采用免认证局域网模式。`X-Family-Client` 是公开提示；标为 child 的管理请求返回 403，但同网络其他客户端仍可调用管理接口。内部媒体签名由服务自动生成，无需填写密钥。

## v0.7 视频管理与播放

- 删除从全部合集中移除视频，删除关联的完成任务以允许重新导入，并清理 MP4、封面、HLS 和对应原始缓存。Windows 文件被播放占用时，持久清理队列稍后重试；删除后的目录和媒体接口立即不可访问。手机上已缓存的副本保留，可在该设备删除。
- 未手填标题时，从分享文案、平台原始文案和视频内嵌 title/description/comment 提取。平台完整文案可补全被截断的分享文字，手填标题优先；描述最多 4000 字，标题最多 200 字。没有元数据的本地视频使用文件名，不伪造内容说明；本轮不含语音或画面 AI 识别。
- 新视频生成 HLS VOD 清单与 MPEG-TS 分片，儿童直接用原生网络播放器边收边播，不先下载整片。旧视频在后台逐个补分片；未就绪或 HLS 初始化失败时回退 MP4 Range 渐进播放，缓存仍下载完整 MP4。保留 MP4 与 HLS 会增加服务器存储占用。
- v0.7.1 儿童端保留最近 3 条视频的原生播放器、播放位置和缓冲，划走只暂停，滑回不重新初始化或 seek。按最近使用顺序释放更早的播放器，内存紧张时释放非当前播放器，退出播放页时全部释放。超过保留范围、切换来源或页面已销毁后，仍需重新初始化并恢复进度。
- 每个视频的进度按服务器保存在设备本地，每两秒及离页/退后台时保存；推荐、搜索和离线播放共享进度。滑回或重启恢复未看完的位置，接近结尾的内容从头开始。进度不跨设备同步。
- 每次启动随机推荐顺序；当前会话刷新保留相对顺序，新内容加入队列。合集维持家长编排。

## v0.8 儿童端长期播放缓存

已读取的视频数据由 Android Media3 原生数据源边播放边写入磁盘，不再依赖最近 3 个播放器是否仍在内存。默认上限 2GiB，无固定按天过期，跨播放器释放和应用进程重启保留，空间满后按最近使用淘汰。播放页的 3 个播放器仅负责即时切换。

HLS 分片和 MP4 字节范围按服务器、不可变视频 ID 与资源路径识别，播放签名刷新仍可复用相同字节。HLS 清单保留完整签名作为缓存键，新的授权会读取新的清单，避免旧清单中片段链接过期。因此再次观看可能读取少量清单或补充尚未缓存的片段；重建播放器也仍有解码初始化过程，不能承诺零加载。

“我 → 播放缓存”显示用量与清理入口。自动播放缓存与手动保存的离线视频分别管理，清理前确认，手动离线文件保留。自动缓存不是完整离线下载：跳过的部分可能未保存，想确保离线可看仍使用缓存按钮。

Android 适配见 packages/video_player_android/FAMILY_CHANGES.md，依据 [Media3 缓存说明](https://developer.android.com/media/media3/exoplayer/network-stacks#caching-media)。儿童 v0.8 与现有 v0.7 服务端兼容。

## 下载链路

v0.6 使用 F2 SDK 解析作品及候选地址，由 Go 流式下载。仅向视频源传 User-Agent/Referer，不向 CDN 转发登录 Cookie，不向客户端返回签名源地址或上游原始日志。

- CDN 拒绝时尝试候选源，再重新解析一次获取新地址；频率限制遵循 Retry-After。
- 瞬态网络/源站错误最多自动重试两次，默认等待 15 秒、60 秒；登录或配置错误需要修正后手动重试。
- 任务显示解析、实际下载字节、检查、处理、封面和等待重试阶段。
- 确认含视频轨的原始文件缓存 24 小时，读取校验 SHA-256；单文件最多 256MiB，有效缓存总额最多 512MiB，处理失败后重试可复用。
- 需要重编码的源（如 4K/1440p HEVC）输出长边不超过 1920，降至 1080p 档以缩短转码时间；可直拷贝的 H.264/AAC 源保持原始分辨率。
- 重编码优先使用 ffmpeg 硬件 H.264 编码器（按序探测 h264_videotoolbox / h264_nvenc / h264_qsv / h264_amf），失败自动回退 libx264 并在本次服务运行内不再重试硬件；libx264 路径限制为约一半 CPU 核心（2–8 线程），导入不挤占家庭电脑日常使用。硬件编码按输出分辨率给目标码率（1080p 档 5 Mbps），与原 CRF 23 软编码的画质取舍需在部署机上验收。
- 失败或中断文件不会入库；取消可终止解析、传输及转码。网络重试目前从头下载，不支持断点续传。

家长提供的真实抖音链接已完成自动解析、下载、HEVC 转 H.264/AAC、入库、儿童目录及媒体 Range 实测，见 `docs/verification-v0.6.md`。登录状态和平台接口变化仍会影响其他作品，不能以单条成功保证全部链接可下载。

登录配置：在 Edge 抖音网页登录后，F12 → 网络 → 刷新，复制 douyin.com 请求标头 Cookie 完整值，运行：

```powershell
.\scripts\configure-douyin.ps1
# 已复制到电脑剪贴板时：
.\scripts\configure-douyin.ps1 -FromClipboard
```

脚本通过隐藏输入或本机剪贴板保存至数据目录 `private/f2.yaml`。每次解析自动读取；`FAMILY_F2_CONFIG` 优先。不要把 Cookie 发到聊天或提交仓库。[上游登录说明](https://f2.wiki/guide/apps/douyin/cli)。

## 环境与构建

FFmpeg/ffprobe 需要在 PATH 中。抖音导入使用 Python 3.11、uv 与固定提交的隔离 F2 环境，见 THIRD_PARTY.md。客户端开发使用 Flutter 3.44 / Dart 3.12、Android SDK、JDK。

```powershell
.\scripts\setup.ps1
.\scripts\setup-downloader.ps1
.\scripts\build-server.ps1
.\scripts\build-android.ps1
```

`.env.example` 复制为 `.env` 可设置端口、数据目录及下载器路径。EXE 需与项目中的 `server/downloader/resolve.py`、下载器环境和 FFmpeg 一起使用，不能单独复制 EXE 当作完整运行包。

源码可在 `server` 目录运行 `go run ./cmd/family-video`。本机全局 Go 有版本文件冲突，构建脚本使用项目隔离的官方 Go 1.26.0 工具链；go-env.ps1 只修改当前 PowerShell 环境，缓存位于 runtime。

## 验证与边界

```powershell
. .\scripts\go-env.ps1
go -C server test ./...
go -C server vet ./...
```

统一执行 `scripts/check.ps1`；加 `-NativeAndroid` 可构建双端 debug APK 并运行原生播放器测试。GitHub Actions 固定 Go 1.26.0 / Flutter 3.44.6 / JDK 17。测试加 `--update-goldens --dart-define=CAPTURE_UI=true` 可生成 runtime/ui 截图；截图用测试视频背景。

电视端模拟器冒烟统一走 `scripts/tv-emulator.ps1`，不要在仓库内直接建 AVD：

```powershell
.\scripts\tv-emulator.ps1                # 启动测试设备（不存在时自动创建）
.\scripts\tv-emulator.ps1 -Action create # 只创建，不启动
.\scripts\tv-emulator.ps1 -Action delete # 删除设备并回收占用
```

脚本把 `ANDROID_AVD_HOME` 固定在仓库外（默认 SDK 同级的 `avd-home`，可用 `-AvdHome` 或 `FAMILY_AVD_HOME` 覆盖，指进仓库会直接报错），并在创建后把 android-21 镜像默认的 `disk.dataPartition.size=10G` 压到 2048M。QEMU 会按分区整块预分配：此前一个建在 `runtime/` 下的设备实占 14 GB，改到仓库外并压小分区后运行期约 5.3 GB。启动带 `-no-snapshot-load -no-snapshot-save`，不再额外落 2 GB 的 `snapshots/*/ram.img`。

v0.9 本轮验证记录见 [verification-v0.9.md](docs/verification-v0.9.md)。真机系统分享、原签名覆盖升级、电视焦点、待机与长时间播放仍需设备验收。历史版本验证保留在对应版本文档中。

本轮网络加固（2026-10-28）已完成：Go test/vet 通过；服务端重建并部署，`/api/settings/time-limit` 返回 200、数据库 schema v5 迁移成功；gzip 经 curl 与 Dart `http` 客户端验证（解压后 936496 字节完整，线上传输 233565 字节）；两端 `flutter analyze` 0 问题、`flutter test` 全过（儿童 28 / 家长 9），release APK 已构建并出现在安装包页（儿童 0.8.2+14、家长 0.7.1+11）。链路侧在本机连续 10 分钟每秒 ping 网关，0 丢包、IP 与信道未变化；但**真机冷启动、待机唤醒后的自动恢复仍需在平板/电视上复测**，本机没有连接 Android 设备。

### macOS 本机构建（Windows 不可用时）

工具链均在用户目录、不污染系统：Flutter 3.29.3（`~/apply/flutter-3.29.3`，git 远端指向 gitee 镜像）、JDK 17 Corretto（`~/apply/jdk-17`）、Android SDK（`~/apply/android-sdk`，platform 35/36 + build-tools 35）。3.44 工具链要求 macOS 14+，本机 macOS 12 只能运行 Dart 3.7，相关适配：

- `environment.sdk` 放宽至 `>=3.7.0`；依赖按兼容矩阵降级（video_player 2.10.1、shared_preferences ^2.5.3、package_info_plus ^9、url_launcher ^6.3.2、file_picker 11、flutter_lints ^5、mobile_scanner ^7.4.2），`video_player_platform_interface` override 6.6.0；
- `packages/video_player_android` Dart 代码已向后移植到 6.6.0（`video_track_compat.dart` 垫片；back buffer 因门面 2.10.1 不透传 options 而不可达）；
- Android 组合：AGP 8.9.1 + Gradle 8.11.1（wrapper 走腾讯镜像）+ Kotlin 2.1.0；app 模块显式 `id("kotlin-android")`；minSdk 24、compileSdk 36（mobile_scanner 的 androidx.camera 1.6 要求）；`gradle.properties` 已加 suppressUnsupportedCompileSdk=36；
- 构建命令（`--ignore-deprecation` 为 Flutter 3.29 工具对 v2 布局的保守误判，安全跳过）：

```bash
export JAVA_HOME=~/apply/jdk-17/Contents/Home ANDROID_HOME=~/apply/android-sdk
export PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn FLUTTER_GIT_URL=https://gitee.com/mirrors/flutter
export PATH=~/apply/flutter-3.29.3/bin:$PATH
cd apps/kids_app && flutter build apk --release --ignore-deprecation
cd ../parent_app && flutter build apk --release --ignore-deprecation
```

产物落入 `apps/*/build/app/outputs/flutter-apk/app-release.apk`；v0.9 需按 [发布说明](docs/operations-v0.9.md) 配置原签名并显式运行 `publish-apk`，才会进入管理台与应用更新接口。Windows 构建机仍可用原 `scripts/build-android.ps1`（Flutter 3.44 无需以上适配；pubspec 的 sdk 下限两端通用）。

待完成：Android 系统分享和后台同步、博主/平台合集批量导入、作品 ID 去重、整库清理、离线封面/断点续传/配额、多儿童档案、可靠观看额度、备份恢复界面、完整电视验收。当前离线上限 2GB，喜欢只在本地，二十分钟提示按当前页面计时，APK 为调试签名。

架构见 `docs/architecture.md`，清单见 `docs/roadmap.md`。
