# 小小放映室 · Family Video

家庭局域网视频系统：家长收集内容，家庭电脑下载存储，孩子用 Flutter 安卓平板或电视观看。视频处理成功后直接可看，无需审核或发布。

Go 单进程提供 HTTP、SQLite 任务队列、下载调度、FFmpeg 处理和媒体服务。F2 SDK 在独立 Python 环境中负责抖音作品解析；主服务不需要 FastAPI、Uvicorn 或 Python worker。

## 启动与升级

当前服务为 v0.7.0，家长 APK 为 0.7.0+9，儿童 APK 为 0.8.1+12。先在旧服务终端按 Ctrl+C 停止旧进程，再启动：

```powershell
cd D:\demo\AI\family-video
.\bin\family-video.exe
```

默认监听 `http://0.0.0.0:8765`。健康检查 `http://127.0.0.1:8765/health` 应返回 `backend: go`、`version: 0.7.0`、`access_mode: open_lan`、`content_mode: direct`、`library_mode: managed`。

两端只填 `http://电脑局域网IP:8765`，无需密钥、配对码或设备注册。v0.7 客户端要求同步更新服务端，以支持视频删除、描述和 HLS；访问模式仍为免认证局域网直连。

已有数据目录可以沿用。从 schema v1/v2 首次升级时，在 `runtime/database/before-v3-*.sqlite3` 自动保存数据库快照，再事务升级到 v3；原有视频全部直接可看。备份失败则停止升级。程序先监听端口，再迁移数据库，避免旧服务仍占用端口时修改数据。

Ctrl+C 停止服务，执行中任务下次启动恢复。`-worker=false` 可仅启动 HTTP 供诊断。历史 Python 实现在 `legacy/python-server`，不参与当前服务。

## 网页管理台

浏览器打开 `http://电脑局域网IP:8765/`（自动跳转 `/admin`），无需安装家长端即可管理：概览（磁盘剩余、各数据目录占用、ffmpeg/下载器/登录配置状态）、抖音分享导入与本地视频上传、任务进度与重试/取消、资源管理（已导入视频的搜索/预览/编辑/下载/删除，含文件大小与 HLS 状态）、合集管理、客户端 APK 安装包下载、抖音 Cookie 配置与解析验证。经 svc 统一入口时访问 `http://127.0.0.1:7777/family-video/admin`。

- 新增接口：`GET /api/system`、`GET|PUT /api/config/douyin`、`POST /api/config/douyin/test`、`GET /api/apps`、`GET /api/apps/{app}/download`；`GET /api/videos` 返回每个视频的 `size_bytes`，`/media/{id}/video` 加 `dl=1` 参数时以附件形式下载（文件名取视频标题）。
- APK 下载扫描 `apps/<应用>/build/app/outputs/flutter-apk/`（优先 app-release.apk），版本号读自各应用 pubspec.yaml；未构建时页面如实标注并提示构建方式。
- 页面为零依赖单文件，`//go:embed` 内嵌于 `internal/family/admin.html`，随服务单二进制分发。
- 资源管理支持**分类筛选**（服务端按标题/描述关键词把内容归纳为英语启蒙、语文古诗、数学思维、历史人文、科普百科、动画故事、儿歌音乐、生活习惯、家庭教育等，见 `internal/family/library.go`）、**话题标签筛选**（从 #标签 文本即时提取计数，取最高频 24 个）与**分页浏览**（每页 60 条，服务端搜索与排序）；批量操作按页选择。
- 相关接口：`GET /api/library`（offset/limit/search/category/tag/sort）、`GET /api/library/meta`（分类与标签计数）。
- **手机连接二维码**：概览页展示本机局域网地址（`GET /api/server-addresses` 枚举非回环 IPv4，多网卡可切换），生成「App 服务器地址」与「手机版管理台」两个二维码（`GET /qrcode?text=` 服务端渲染 PNG，仅允许 http/https）；安装包页每个已构建的 APK 附「扫码直接下载」二维码。手机与电脑同网扫码即可连接或安装。
- 管理台继承服务的免认证局域网开放模式，请仅在可信家庭网络中使用。
- macOS 上以 LaunchAgent + svc 托管运行（见 `tools/svc/svc.yaml`），FFmpeg 与 F2 下载器环境由 svc 注入的 `PATH`/`FAMILY_*` 环境变量提供；macOS 安装下载器用 `server/downloader-requirements.macos.lock`（原锁中的 pywin32/wmi/shadowcopy 为 Windows 专用）。

## 客户端

儿童端显示名称为“抖音儿童版”，桌面、自适应图标、TV 入口与连接页采用抖音应用条目的原始图标；资源来源见 apps/kids_app/assets/branding/README.md。包名 cn.familyvideo.kids_app 保持不变，可覆盖升级并沿用缓存、喜欢与进度。家长端名称保持原有设置。

**应用内更新**：两端连接服务端后自动调用 `GET /api/update/{app}`（家长 parent / 儿童 kids）比对版本号，服务端存在更新版本（以各应用 pubspec.yaml 版本 + 已构建 APK 为准）时弹窗提示，经系统浏览器下载最新 APK 安装；检查失败静默跳过，不影响使用。旧版本服务端无此接口时同样静默。

**扫码连接**：两端连接页地址输入框带扫码按钮，扫描管理台「手机连接」面板的服务器地址二维码后自动填入并连接；识别 http/https 链接（取 scheme://host:port），非地址二维码忽略继续扫，相机不可用时显示提示并回退手输（`mobile_scanner`，Android 需相机权限）。

- 家长：链接收集、点击粘贴、重复提示、本地上传、任务筛选/取消/重试、下载字节和处理阶段；视频标题/描述搜索、预览、编辑信息和确认删除；合集创建、成员编辑、排序、重命名及删除。视频库按显示宽度虚拟化渲染并降采样解码缩略图，支持按播放/完播/观看时长排序与多选批量删除、批量加入合集；合集创建使用可搜索视频选择器。
- 儿童：黑底全屏推荐流、上下滑动、点击暂停、双击喜欢、喜欢/缓存/合集操作，以及合集、离线、喜欢、个人页。横竖视频按比例居中，标题和播放进度位于底部。播放增强：**长按屏幕 2 倍速**（松开恢复），**左右拖动快进/快退**（居中显示目标时间预览，一屏宽最多两分钟，松手定位；与上下滑切换、双击喜欢、底部进度条拖动互不影响）。**内容刷完后**在第一条继续下拉或最后一条继续上拉，自动拉取服务器最新视频（新内容按推荐顺序追加，当前视频保持播放位置；单次拖动只触发一次，失败时顶部横幅提示且播放不中断）。

**推荐排序与观看统计**：儿童端推荐流分桶排序——完全没播过的最上面（桶内随机、每次启动重新洗牌），播过未完播的居中，已完播的最后；观看过程中按采样累计每个视频的观看时长、播放次数与完播情况，每 30 秒批量上报服务端（`watch_stats` 表，数据库 schema v4），失败保留重试、不阻塞播放。该数据同时驱动排序与家长分析。
- 刷新失败保留已有列表，搜索包含缓存。打开搜索播放页会暂停首页播放器，返回恢复原来的播放意图。
- 处理中任务每 8 秒刷新；应用进入后台或任务结束后停止轮询。
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

两端应用及共享 API 包分别执行 `flutter analyze` 和 `flutter test`。测试加 `--update-goldens --dart-define=CAPTURE_UI=true` 可生成 runtime/ui 截图；截图用测试视频背景。

v0.9 变更的服务端部分（`/api/update`、APK 下载公开化）已通过 Go 测试并在 macOS 服务端部署验证；**Flutter 端改动（应用内更新、儿童端播放手势）尚未在装有 Flutter 3.44 的构建环境运行 `flutter analyze` / `flutter test` / 构建 APK，首次构建时如遇 package_info_plus / url_launcher 版本约束问题，可在两端 pubspec 中放宽后 `flutter pub upgrade`**。真机上的长按倍速与拖动快进表现仍待验收。本轮缩略图磁盘缓存（family_api 新增 `path_provider`，两端调用点与 pubspec.lock 需重新 `flutter pub get`）与上述改动同属未在 Flutter 3.44 环境验证的范围。重编码硬件加速在无 ffmpeg 的开发机上仅通过单元测试（桩探测器、编造编码器名的回退路径）验证，真实 GPU 编码的可用性与画质待部署机验收；部署机若无可用的硬件编码器，服务自动保持 libx264 行为。

待完成：Android 系统分享和后台同步、博主/平台合集批量导入、作品 ID 去重、整库清理、离线封面/断点续传/配额、多儿童档案、可靠观看额度、备份恢复界面、完整电视验收。当前离线上限 2GB，喜欢只在本地，二十分钟提示按当前页面计时，APK 为调试签名。

架构见 `docs/architecture.md`，清单见 `docs/roadmap.md`。
