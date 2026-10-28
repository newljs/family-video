# v0.9 运行、发布与数据维护

## 升级

停止旧服务，构建并启动新服务。数据库升级到 schema v6；v3–v5 升级前自动生成 `database/before-v6-*.sqlite3` 快照，v1/v2 保留 `before-v3-*` 快照流程。备份失败中止升级，未来版本数据库拒绝降级打开。v6 新增观看事件回执、作品身份、分类与标签索引；历史视频在升级事务内建立分类索引。

服务与离线维护命令共用 `server.lock`，包括 `-worker=false` 的诊断服务。下载、处理、HLS 补片和数据库定期快照仍由随 HTTP 启动的 Go worker 执行。

## 观看统计和时长

儿童端按服务器共享本地待上报队列，每 500ms 左右保存一次快照，每 30 秒发送，每批最多 50 条。已经尝试发送的事件不可变，断网、响应丢失、页面切换或应用重启后复用同一事件 ID 重试。正常离页/退后台立即尝试上报并保存；操作系统强杀仍可能丢失尚未完成落盘的最后一小段采样，不承诺零丢失。

服务端在同一事务内保存事件回执、累加视频统计和按观看日期累加额度。重复事件不再计时；删除视频后的迟到记录被忽略。只接收服务端当天及之前 31 天的日期，过期、未来或非法记录忽略，不阻塞其他有效记录。客户端和家庭服务应使用相同本地时区；离线记录跨午夜补报归属记录携带的观看日期。采样区间跨午夜时以该次采样结束日期归属，最大误差为一个采样区间。

旧客户端仍可不带事件 ID 上报，但无法获得重试去重保证。新版儿童端发送前检查 `watch_protocol=events_v1`，连接旧服务时保留待上报队列，直到服务端更新再发送，以免旧服务忽略 ID 导致重复计时。新版儿童端应与 v0.9 服务一起更新；连接旧服务期间，本机额度继续执行，但多设备用量无法及时同步。

时长按真实经过的观看时间计数：暂停、缓冲、快进跳跃不累计；2 倍速播放 2 秒视频只扣约 1 秒额度。关闭限额会覆盖旧的离线缓存。额度用完继续使用原有安静模式，当前视频自然播完。

## Android 系统分享

在其他应用分享文字/链接时选择家长端。支持冷启动和已有页面的 `ACTION_SEND text/*`。Android 先将分享保存到自己的私有偏好设置，Dart 收集箱保存成功后才确认接收。保存失败时原分享保留，下次启动或回到前台再次接收；重复分享文案不会重复加入当前收集箱。

分享内容先进入收集箱。服务器已连接时自动提交系统分享；离线失败保留，重新连接或回到前台重试。手动粘贴收集的条目仍使用“同步”按钮。这里的重试发生在应用启动/回到前台/重新连接时，没有常驻 Android 后台服务，也不承诺进程被杀后自动唤醒同步。服务不可达时显示等待连接家庭电脑。

F2 解析返回作品 ID 后，在 Go 下载阶段查询 `(platform, source_id)` 唯一身份，已导入作品直接关联现有视频，任务显示 `phase=duplicate`；不会再次请求 CDN 或转码。原始下载缓存携带作品 ID，新视频提交时在同一事务内保存身份与分类索引。旧视频若没有保存过作品身份，无法凭短链接自动推断；原来的相同链接去重仍然有效。

## APK 发布

更新接口和管理台只提供数据目录中 `releases/<parent|kids>/release.json` 指向、且 SHA-256 与大小校验通过的 APK。清单记录从 APK 本身读取的版本名、构建号、包名、哈希、大小和发布时间。APK 使用内容哈希命名；源码 `pubspec.yaml` 或其他构建目录文件变化不会改变已发布包。下载 URL 携带哈希，期间发布了新版本时旧 URL 返回 409，重新检查更新即可。

Windows 调试包：

```powershell
.\scripts\build-android.ps1 -Publish -Aapt D:\Android\Sdk\build-tools\36.0.0\aapt.exe
```

正式包从以下环境变量读取签名，不写入源码；缺少配置时 release 构建直接失败，不回退 debug 签名：

- `FAMILY_ANDROID_KEYSTORE`：现有签名库的绝对路径。
- `FAMILY_ANDROID_STORE_PASSWORD`：签名库密码。
- `FAMILY_ANDROID_KEY_ALIAS`：别名。
- `FAMILY_ANDROID_KEY_PASSWORD`：私钥密码，可省略，默认与库密码一致。

```powershell
.\scripts\build-android.ps1 -Mode release -Publish
```

已安装版本需要继续使用相同签名证书才能覆盖升级。如果此前用 debug 证书发布，应先确认原签名库并明确配置；本轮不会自动生成或替换签名密钥。密钥和密码由本机或 CI 的私密配置管理，不提交仓库。

其他平台或已经构建的 APK，可直接运行以下命令；`aapt` 来自 Android SDK build-tools，服务无需在日常运行时安装 Android SDK：

```text
family-video publish-apk -app kids -apk /path/app-release.apk -aapt /path/android-sdk/build-tools/36.0.0/aapt
```

该命令可在 HTTP 服务运行时执行。它不负责构建或签名，只在成功读取 APK 元数据后复制文件并切换发布清单。未带 `-Publish` 的构建不会进入更新接口；旧构建目录不会被自动扫描或发布。

不同 APK 必须递增 `versionCode`（pubspec 的 `+构建号`）；重复发布相同内容可以重试，构建号未递增时拒绝替换已有发布包。

## 备份与恢复

worker 首次空闲及之后每小时检查当天数据库快照，保存在 `backups/database/YYYY-MM-DD.sqlite3`，附 `.media.json` 视频清单。保留最近 14 天及当天的快照。快照是数据库备份，不包含视频文件；整个磁盘丢失时不能靠它恢复媒体。`-worker=false` 不会执行定期快照。

完整备份需要先停止服务。以下命令示例在项目根目录运行，先执行 `scripts/build-server.ps1` 生成当前二进制：

```powershell
.\bin\family-video.exe backup -output D:\Backups\family-video-2026-10-26.zip
.\bin\family-video.exe verify-backup -input D:\Backups\family-video-2026-10-26.zip
.\bin\family-video.exe restore -input D:\Backups\family-video-2026-10-26.zip -data D:\FamilyVideo-Restored
```

完整包包含 SQLite 一致性快照、数据库引用的视频、现存封面与 HLS 文件，以及每个文件的大小和 SHA-256 清单；不含 Cookie、签名密钥、设备缓存、临时导入文件、APK 或其他已有备份。输出文件必须尚不存在。恢复先校验全部文件，再写入一个尚不存在的新目录，最后检查数据库完整性、外键和视频文件。原数据目录保持可用。确认新目录内容后把 `FAMILY_DATA_DIR` 指向新目录并重新启动；登录配置、APK 发布包需要另行重新配置。恢复会生成新的内部媒体签名密钥。

未完成的导入任务在恢复后标记失败并提示重新导入，因为完整备份不携带导入临时文件。没有完成入库的视频不会在儿童端出现。

## 孤儿文件维护

停止服务后先预览；只扫描视频、封面、HLS 中不再被数据库引用且修改时间超过 24 小时的常规文件：

```powershell
.\bin\family-video.exe orphans
.\bin\family-video.exe orphans -apply
```

`-apply` 将候选文件移到 `quarantine/<时间-随机ID>/`，保存原相对路径清单，不直接删除。核对后可以手动移回，或在备份后自行清理隔离目录。设备手动离线文件不受服务端清理影响。

## 开发检查

CI 固定 Go 1.26.0、Flutter 3.44.6 / Dart 3.12.2、JDK 17 和 Android SDK 36。本地仍可使用 README 记录的 Dart 3.7 兼容环境；兼容环境需要独立验收。

```powershell
.\scripts\check.ps1
.\scripts\check.ps1 -NativeAndroid
```

第一条执行 Go tests/vet、两端与共享包/播放器适配包的 Flutter 分析，以及存在的 Dart 测试；第二条额外构建双端 debug APK 并运行播放器 Java 单元测试。分析保留旧 Flutter 兼容 API 的弃用 info，不允许 warning/error。原生构建需要可用的 JDK、Android SDK、Gradle 和依赖下载网络。GitHub Actions 配置在 `.github/workflows/check.yml`，本地运行通过不等于远程 CI 已运行。

真机验收：Android 系统分享冷/热启动、连续滑动与倍速/快进计时、后台/待机恢复、断网重连、多设备额度、磁盘缓存清理、使用原签名的覆盖升级，以及电视遥控焦点。单元测试与 APK 编译不能替代这些设备检查。
