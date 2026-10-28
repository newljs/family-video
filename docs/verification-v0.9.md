# v0.9 可靠性、收集与运维验证

日期：2026-10-26。验证环境为 Windows，Go 1.26.0、Flutter 3.44.6 / Dart 3.12.2、Android SDK 36、JBR 21、Gradle 8.11.1、AGP 8.9.1、Kotlin 2.1.0。CI 配置使用 JDK 17，尚未在远程 GitHub Actions 执行。

## 已通过

- Go `test ./...` 与 `vet ./...`。新增回归覆盖事件重试去重、跨日补报、不同分享链接按作品 ID 复用、资源索引随编辑更新与删除级联、v5→v6 快照及索引迁移、安装包版本与源码解耦、损坏包拒绝下载、构建号未递增拒绝发布、完整备份恢复、恢复不覆盖已有目录、非法路径及截断备份拒绝、孤儿文件预览/隔离、维护命令与服务文件锁互斥。
- 儿童端 Flutter 测试 **35 项**：含积压 121 个视频按 50/50/21 分批、失败重启沿用相同事件 ID、发送期间新采样不改变重试载荷、跨页面共享队列、跨日保留观看日期、切换服务器隔离队列、旧服务端暂存事件等待升级、快进/暂停/倍速计时、关闭限额覆盖旧缓存，以及原有播放、安静模式、布局与缓存回归。
- 家长端 Flutter 测试 **10 项**：含分享保存失败时不确认接收，重试保存成功后才确认，以及原有收集箱、管理、每日额度与布局流程。
- 共享 API 包 Flutter 测试 **7 项**，播放器适配包 Dart 测试 **58 项**；合计 **110 项**。共享模型包无测试目录，完成静态分析。
- 两端、共享 API/模型及播放器适配包静态分析。家长端保留 **4 项弃用 info**，用于旧 Flutter 兼容；无 warning/error。播放器适配包修正了自身平台接口约束与旧版兼容测试，独立分析不再与应用 override 产生冲突。
- 双端 debug APK 构建完成，版本为家长 **0.9.0+10**、儿童 **0.9.0+13**。儿童端最后一次增量构建包含最终的观看协议与持久队列代码；核对过源文件、kernel 和 APK 生成时间，没有将旧构建目录文件当作本次产物。
- 使用 SDK 36 的真实 `aapt.exe` 对双端最终 APK 执行 `publish-apk` 成功：在独立验证数据目录中生成发布清单，从 APK 读取到对应包名、版本/构建号，并记录大小和 SHA-256。元数据读取和哈希均针对同一份已复制的文件快照。
- Android 原生播放器 `:video_player_android:testDebugUnitTest --max-workers=1` 成功：**96 项测试，0 失败、0 错误、0 跳过**，包含磁盘缓存、播放器、平台视图及事件监听测试。结果来自 12 份 JUnit XML 报告。
- Go 服务端构建成功，输出 `bin/family-video-v0.9.0.exe`，没有替换或重启已有运行服务。`git diff --check` 通过。

## 产物与命令

- `apps/parent_app/build/app/outputs/flutter-apk/app-debug.apk`
- `apps/kids_app/build/app/outputs/flutter-apk/app-debug.apk`
- `bin/family-video-v0.9.0.exe`（先停止旧服务，再从项目根目录运行）
- `scripts/check.ps1`：统一 Go / Flutter 检查。
- `scripts/check.ps1 -NativeAndroid`：额外执行 Android APK 构建和原生播放器测试。
- 发布、签名、备份、校验、恢复及隔离命令见 [operations-v0.9.md](operations-v0.9.md)。

验证使用独立临时数据或 `runtime/*verification*` 目录，没有对现有视频库执行升级、恢复或清理，也没有将测试 APK 切换为当前家庭服务的发布包。

## 设备和平台边界

Android 系统分享的冷/热启动、真正的进程被杀恢复、原签名覆盖升级、多设备每日额度、电视遥控/待机及长时间连续播放仍需真实设备验收。正式 release 签名读取环境变量的配置已加入，但本轮未创建签名密钥，也未构建或安装正式签名包。macOS/Dart 3.7 兼容环境本轮未重新执行；Flutter 3.44 构建提示现有 Gradle/AGP/Kotlin 组合未来将停止支持，当前 debug 构建仍成功。

