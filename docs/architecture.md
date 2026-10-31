# Go 与 Flutter 架构

## 运行结构

家长 Flutter → Go API → SQLite 持久任务 → Go worker → F2 SDK 解析子进程 → Go HTTP 下载 → FFmpeg → 视频库。
儿童 Flutter → 同一 API 目录 → 签名媒体 → 本地缓存。

HTTP 和 worker 共用进程，OS 文件锁阻止第二个 worker。先监听端口再迁移；Ctrl+C 取消下载与处理，未完成任务下次恢复。

## 源码

- `server/cmd/family-video/main.go`：启动、监听和退出。
- `server/internal/family/config.go`：环境配置、内部签名兼容。
- `store.go / schema.sql / migrations.go`：schema v3–v7、v1/v2/v6 快照及事务迁移。
- `http.go / manage.go`：目录、导入、上传、任务、合集和 Range。
- `watch.go / timelimit.go`：观看统计上报、每日时长限额与按天用量。
- `worker.go`：任务领取、重试调度、FFmpeg、原子入库、取消和恢复。
- `resolver.go / server/downloader/resolve.py`：隔离 F2 SDK、结构化结果、固定错误映射。
- `downloader.go / transfer.go`：候选地址、地址刷新、Go 流式传输和字节进度。
- `source_cache.go`：原始文件哈希校验与缓存。
- `apps/parent_app/lib/main.dart / ui.dart / library_panel.dart`：收集、任务和视频库。
- `apps/kids_app/lib/app_home.dart / pages.dart / feed.dart`：导航、目录、全屏播放及遥控。
- `packages/family_api / family_models`：共享接口和模型。

## 数据与可见性

视频检查、处理、封面全部完成后，在事务中插入视频并标记任务 completed，儿童即可访问。失败或未完成文件不进入目录。审核和发布操作已移除；旧 published 列只为兼容保留，不参与过滤，旧客户端修改该字段也不会隐藏视频。

v1/v2 升级前通过 VACUUM INTO 保存包含已提交 WAL 状态的快照，再事务增加任务阶段、字节、重试时间和错误分类字段，并将原有视频设为可见。v3–v5 升级生成 `before-v6-*`；v6 升级生成 `before-v7-*` 并建立按客户端观看表。备份失败中止，未来 schema 版本拒绝降级打开。

业务数据位于 runtime/database/family.sqlite3。credentials.json 仅需自动生成的 signing_key，旧 admin_key 被忽略。媒体 HMAC 格式兼容，http.ServeContent 支持 Range。上传流式写入数据目录，不在系统临时目录缓存完整请求体。

SQLite 使用单连接、WAL、foreign_keys 和 busy_timeout。取消先落库再取消 context；入库事务只允许 running→completed，防止取消与完成竞态。

## 任务

queued→running→completed/failed；queued/running/failed 可取消。瞬态下载错误转回 queued，phase=retry_wait，到 next_attempt_at 再执行；最多两次自动重试，默认等待 15 秒、60 秒，较长 Retry-After 优先。手动重试清空自动重试预算；登录/配置错误不自动循环。

阶段包括 cached、resolving、downloading、inspecting、processing、thumbnail。downloading 返回真实字节，总长度未知时显示不定进度；FFmpeg 不伪造百分比。服务停止恢复 queued，已取消任务不被覆盖。

## 按客户端观看数据（schema v7）

儿童端与 TV 在请求头携带 `X-Family-Client-Id`（客户端公开提示，不是认证）。`/api/watch` 同时写入全局 `watch_stats/watch_days/watch_events` 和按客户端的 `client_watch_stats/client_watch_days/client_watch_events`；`/api/videos`、`/api/settings/time-limit` 与安静模式对儿童角色使用该客户端的统计，家长/管理台继续使用全局聚合。

儿童端安装 ID 在 SharedPreferences 中生成一次；TV 使用系统 `ANDROID_ID`（不落盘），因此 TV 仍不保存目录/历史/媒体缓存。客户端已看完的视频不进入推荐流；当该客户端完成当前库内全部视频时，服务端把该客户端的 `plays/completed` 清零但保留已看时长，下一次目录请求会让视频重新成为未看。

## API v0.7

GET /health、GET /api/me、POST /api/imports、POST /api/uploads、GET /api/tasks、POST /api/tasks/{id}/retry、POST /api/tasks/{id}/cancel、GET /api/videos、PATCH /api/videos/{id}、DELETE /api/videos/{id}、GET /api/collections、POST /api/collections、PUT /api/collections/{id}、DELETE /api/collections/{id}、GET /media/{id}/{resource}。

后续版本增加：POST /api/watch（儿童观看统计批量上报，响应携带每日额度）、GET /api/settings/time-limit（儿童与家长读取限额、今日已看与安静模式合集）、PUT /api/settings/time-limit（仅家长，0–720 分钟，0 为不限制，可指定额度用完后的可见合集）等。

v0.9/v0.9.2 管理台与发布接口：GET /api/system、GET|PUT /api/config/douyin、POST /api/config/douyin/test、GET /api/apps、GET /api/apps/{app}/download、GET /api/update/{app}、GET /api/library、GET /api/library/meta、GET /api/server-addresses、GET /qrcode；局域网发现使用 UDP 8766。管理台请求携带 `X-Family-Client: parent`，避免额度耗尽时被儿童角色的安静模式过滤。

时长额度用完后服务端进入安静模式：对儿童角色的目录与合集查询按指定合集过滤（未指定则返回空），不做任何提示；家长角色不受影响。儿童端本地预算同步收缩推荐流与各页签，当前播放经已签发地址自然播完。

视频 PATCH 修改标题和可选描述，空描述可清除旧值。合集提交完整有序 video_ids，事务验证所有视频；删除合集保留视频。任务返回 phase、字节、错误代码、自动重试次数及下次时间。

无 Authorization、密钥或配对码。health 返回 access_mode=open_lan、content_mode=direct、library_mode=managed，v0.7 客户端校验兼容能力。X-Family-Client: child 的管理请求返回 403；这是公开提示，不是认证。所有目录包含全部成功视频；儿童合集隐藏空合集。

旧配对/设备接口返回 410。客户端只保存服务器地址，旧 token 只定位本地缓存/喜欢，不发送服务端。

## 下载边界

F2 算法不复制入业务代码，固定上游提交及依赖隔离安装。Python 只输出作品 ID、标题、最多 8 个源和浏览器元数据。Cookie 仅用于作品接口，不给 CDN。子进程输出有界、错误固定映射，不返回原始日志或签名源地址。

Go 下载候选源，失败后重新解析一次；429 不立即轮询。连接和重定向校验地址，禁用环境代理，拨号只连验证过的公网 IP。单文件最多 2GB，先检查磁盘空间，失败文件删除。

原始视频经 ffprobe 确认视频轨后可缓存，读取校验大小和 SHA-256；24 小时有效，单文件 256MiB、有效缓存总额 512MiB。转码失败重试可复用；网络中断从头获取。缓存按来源链接摘要索引；v0.9 起 worker 另用平台作品 ID（`video_sources`）去重，不同分享链接可复用同一视频。

## 客户端

`apps/tv_app` 是独立 Kotlin 原生 TV 客户端（API 21+），使用单个 Media3 1.5.1 ExoPlayer + SurfaceView，复用 Go 的儿童角色目录、合集、MP4 Range、时长上报和 UDP 发现协议。播放器使用显式 MP4 extractors 与 HTTP 数据源，不接入 Flutter 的磁盘缓存 fork；客户端无数据库、目录快照、偏好或离线视频。观看事件保存在有界内存队列中，稳定 ID 支持当前进程内重试去重；进程丢失时未上报事件不保留。退后台释放播放器，回前台同步规则并从头恢复当前条目。已播放期间的列表刷新不替换当前 MediaItem，额度耗尽在下一条选片时切至安静合集；目录刷新失败或恢复中不接受旧目录换片。TV 0.2 在每次进程启动后的首次目录上随机“全部视频”顺序，刷新时保留会话顺序并追加新内容；已看完视频不进入全部视频队列，使用系统 `ANDROID_ID` 区分客户端统计。详情见 [TV 使用说明](../apps/tv_app/README.md)。


家长端没有审核、发布或下架开关。完整刷新成功后替换数据，失败保留原目录。儿童 Stack 占满区域，导航叠加，横竖视频居中；搜索路由暂停首页并保存返回时的播放意图。离线和喜欢仍在设备本地，旧数据兼容。其余能力见 roadmap。


## v0.7 元数据、流媒体与进度

schema v3 增加视频 description/stream_state、任务 share_text/title_manual 以及 video_deletions 清理队列。导入保留原分享文案；解析器标题写入任务临时 metadata.json，原始缓存也保存元数据。worker 结合平台文案、分享文案和 ffprobe tags 生成标题/描述，手填优先，不调用外部 AI。

新任务完成前用 FFmpeg 复制编码生成 HLS 分片及 VOD 清单，保存 runtime/streams/{video_id}。不重复编码，但保留 MP4，因此增加一份分片存储。GET /media/{id}/stream.m3u8 返回每段带独立 HMAC 的地址；GET /media/{id}/segmentNNNNN.ts 提供流式内容和 Range。删除时每次读取仍验证视频存在，旧签名不可绕过删除。

旧视频 stream_state=pending 由空闲 worker 逐个补分片，失败标记 failed，不无限重做。儿童优先 stream_url，HLS 初始化失败退回 media_url；缺少分片时使用已有 faststart MP4 Range。离线下载与在线播放相互独立。

删除事务移除所有合集关联、关联任务与视频，记录 video_deletions；物理文件清理在提交后执行，打开文件导致失败则由 worker 重试，重启仍保留。mediaMu 协调分片安装与删除，防止后台补片复活已删除内容。

playback_progress.dart 用服务器哈希命名的 SharedPreferences 保存最多 1000 条进度，内存更新、串行且合并写盘；切换先保存旧位置，初始化后 seek 再 play。页面销毁/后台和周期保存共享逻辑。recommendations.dart 维护本次会话随机 ID 序列，刷新时合并数据，合集序列不变。


## v0.7.1 播放器复用

feed_player_cache.dart 管理当前播放页最近使用的最多 3 个 CachedFeedPlayer。划走记录位置并暂停，load 取得缓存条目后等待同一个 ready Future；已初始化条目不再 initialize/seek，保留原生缓冲和实际暂停位置。唯一活动页决定 play，过期 generation 不能自动播放隐藏视频。HLS 回退生成的 MP4 控制器也留在同一条目中复用。

来源变化、已失败条目重新创建；容量超限按最近使用淘汰。初始化等待有 25 秒超时，淘汰/退出通过释放信号取消等待和计时器。内存压力释放非活动条目，页面 dispose 关闭全部条目。应用退后台或播放器 inactive 时仅暂停，不自动播放迟到的初始化结果。

这是当前页面内有限的播放器与缓冲复用；较早视频被淘汰或页面重建后仍使用进度持久化恢复，不是无限内存缓存或磁盘分片缓存。


## v0.8 原生磁盘字节缓存

仅儿童 app 通过 dependency_overrides 使用 packages/video_player_android 的 2.12.2 本地适配。HttpVideoAsset 的工厂注入共享 CacheDataSource，底层 SimpleCache 位于 Android filesDir/playback-cache-v1，数据库索引配合 2GiB LeastRecentlyUsedCacheEvictor。HLS 分片与 MP4 范围均由原生层实际写入/读取；播放器释放不删除磁盘缓存，应用退出后仍可打开。缓存只接入本系统 /media/{id} 路由，其他资源仍走原数据源。

媒体键是包含服务器地址、视频 ID、资源路径的摘要，移除 expires/role/sig 查询后复用不可变媒体字节；清单键包含完整 URL 的摘要，使新签名对应新清单。业务约束是视频 ID 不复用，替换视频产生新 ID。缓存不覆盖未读取范围，容量满时按片段最近使用淘汰，不承诺一个视频始终完整保留。

family_video/playback_cache 通道只提供 stats/clear，不公开路径与源链接；磁盘操作在单个 IO 线程执行，结果回主线程。清理只调用此缓存的 removeResource，不触及 offline 目录。页面级 3 个播放器缓存与该字节缓存互相独立，内存压力可以释放播放器而不删除已观看数据。

## v0.9 数据可靠性与维护

观看事件回执与统计在同一事务提交，日期随事件保存，客户端持久队列按 50 条分批；Go worker 按作品身份复用已有视频。video_catalog / video_tags 在导入和编辑事务内更新，管理台通过 SQLite 筛选与分页。发布包元数据从 APK 读取，服务只提供 releases 中通过 SHA-256 校验的文件。server.lock 覆盖 HTTP 及离线维护命令，完整备份与恢复需要停服；定期数据库快照在空闲 worker 执行。操作与边界见 [operations-v0.9.md](operations-v0.9.md)。

## v0.9.1 启动与连接

family_api 提供按服务器/角色隔离的 StartupCache 与前台 BackgroundSync。两端先读本地快照后显示主页面，再并行校验兼容性与加载各数据段；成功数据独立落盘。儿童额度先于目录恢复，网络视频等待新授权后初始化。显式刷新淘汰旧后台读结果并保持原有失败保留语义；同一媒体的签名轮换保留原生播放器。请求使用共享 HTTP client 与可中止截止时间，重试随生命周期暂停，详见 verification-v0.9.1.md。

## v0.9.2 服务发现

Go 在 HTTP 启动时并行监听 UDP 8766，随进程 context 关闭；绑定失败仅记录日志，HTTP 与 worker 继续运行。发现请求与回复使用 family-video / protocol=1 和每次扫描的随机 nonce。回复包含随机进程实例 ID、主机名、实际 HTTP 端口及版本，不包含凭据。仅响应 IPv4 私有、链路本地或回环来源，限制报文长度与每来源回复速率。

共享 LanDiscovery 在各 IPv4 私有网卡发短时广播，不遍历地址段。只接受本次 nonce，HTTP 主机取自 UDP 来源；900ms 内通过现有能力健康检查后才提供选择，按实例去重。一次搜索最多 4 秒，限制候选数量和验证次数；结束、选择、页面销毁或退后台释放 socket、HTTP client 和计时器。首次 Android 配置自动开始；已有地址不阻塞启动。多个服务由用户选择，扫码/手动入口作为回退。详见 verification-v0.9.2.md。
## 客户端连接与传输加固

`family_api` 的 `FamilyApi` 持有一个 keep-alive `http.Client`（连接超时 6 秒、空闲 45 秒、每主机最多 8 个连接），刷新不再为每个请求重新建连。GET 在连接被重置或超时时自动重试一次，导入、上传、观看统计等写请求不自动重试，避免服务端已提交后被重复执行。`/health` 成功结果缓存 5 分钟，父端任务轮询不再每 8 秒重复探测。缩略图缓存使用独立的长连接（每主机最多 4 个连接）。

刷新失败后客户端按 5/10/20/40/60 秒退避重试；App 回到前台且距上次成功刷新超过 30 秒时静默刷新。儿童端播放页打开期间暂停自动刷新，防止正在观看的内容被目录替换。

服务端 `withGzipJSON` 对 `/api/` 的 GET JSON 响应启用 gzip（排除 APK 下载，媒体路由 `/media/` 不经过），减少弱网下目录刷新的传输量；`route` 对超过 2 秒的 API 请求记录方法、路径、客户端角色和远端地址，便于确认客户端请求是否到达。媒体签名 URL 仍为 24 小时有效。
