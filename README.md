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

## 客户端

儿童端显示名称为“抖音儿童版”，桌面、自适应图标、TV 入口与连接页采用抖音应用条目的原始图标；资源来源见 apps/kids_app/assets/branding/README.md。包名 cn.familyvideo.kids_app 保持不变，可覆盖升级并沿用缓存、喜欢与进度。家长端名称保持原有设置。

- 家长：链接收集、点击粘贴、重复提示、本地上传、任务筛选/取消/重试、下载字节和处理阶段；视频标题/描述搜索、预览、编辑信息和确认删除；合集创建、成员编辑、排序、重命名及删除。
- 儿童：黑底全屏推荐流、上下滑动、点击暂停、双击喜欢、喜欢/缓存/合集操作，以及合集、离线、喜欢、个人页。横竖视频按比例居中，标题和播放进度位于底部。
- 刷新失败保留已有列表，搜索包含缓存。打开搜索播放页会暂停首页播放器，返回恢复原来的播放意图。
- 处理中任务每 8 秒刷新；应用进入后台或任务结束后停止轮询。
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

待完成：Android 系统分享和后台同步、博主/平台合集批量导入、作品 ID 去重、整库清理、离线封面/断点续传/配额、多儿童档案、可靠观看额度、备份恢复界面、完整电视验收。当前离线上限 2GB，喜欢只在本地，二十分钟提示按当前页面计时，APK 为调试签名。

架构见 `docs/architecture.md`，清单见 `docs/roadmap.md`。
