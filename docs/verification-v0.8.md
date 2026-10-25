# v0.8.0 Android 长期播放缓存验证

日期：2026-10-25。儿童版本 0.8.0+11，兼容现有 v0.7 后端；家长端不需要更新。

## 机制

v0.7.1 只保留最近 3 个原生播放器，退出页面或淘汰后仍需重新读取媒体。v0.8 增加独立的 Media3 SimpleCache + CacheDataSource：边读边写磁盘，播放器释放不删除字节，应用进程重启后可再次打开。容量按字节管理，默认上限 2GiB，按最近使用淘汰，没有按视频个数或固定天数清理。

仅儿童应用用 dependency_overrides 引用 packages/video_player_android 的上游 2.12.2 本地适配，保留 LICENSE/AUTHORS/Pigeon 定义，改动清单见 FAMILY_CHANGES.md。缓存位于 Android filesDir/playback-cache-v1，HLS 分片与 MP4 范围都使用原生 SDK 写盘；不是 Dart 层模拟下载，也不以播放器还在内存中冒充持久缓存。

缓存键隔离服务器与不可变视频 ID；媒体字节键移除过期签名查询，清单键保留完整签名，使新清单中的片段地址有效。元数据刷新可能读取少量清单，未读取范围仍需补取。重建播放器仍有解码初始化，并不承诺任何情况下零等待。

“我 → 播放缓存”显示用量并提供确认清理。自动播放缓存与手动离线文件相互独立；手动离线仍用于保证完整下载，播放过的局部范围不等于整片已离线。

## 原生真实磁盘缓存回归

命令（Windows 使用项目 JBR 与 Gradle 缓存）：

```powershell
$env:JAVA_HOME='D:\Programs\Android\Android Studio\jbr'
$env:GRADLE_USER_HOME='D:\GradleUserHome'
cd apps\kids_app\android
.\gradlew.bat :video_player_android:testDebugUnitTest --tests io.flutter.plugins.videoplayer.PlaybackDiskCacheTest
```

Robolectric Android SDK 34，真实 Media3 缓存对象和临时文件系统，5 项通过，0 失败、0 错误、0 跳过：

- 6 份资源（超过 3 个播放器保留范围）写盘，释放 SimpleCache 和数据库提供者后重建，用新签名重新读取全部数据。将上游数据源设为不可用，所有读取仍正确，额外上游 open 次数为 0。
- MP4 两次重叠 8192 字节请求，上游只读取 12288 字节，缓存部分直接复用。
- 小容量 LRU 实际淘汰较少使用的字节，保留近期命中的数据，不按视频个数清理。
- 不同服务器、不同视频键隔离；片段换签名键保持一致，清单换签名键不同。
- 清理自动播放缓存后 bytes=0，手动 offline 测试文件内容完整保留。

测试报告 XML：apps/kids_app/build/video_player_android/test-results/testDebugUnitTest/TEST-io.flutter.plugins.videoplayer.PlaybackDiskCacheTest.xml。数据源采用受控字节数据，测试证明磁盘存储/索引/读取及签名策略，未将其表述为真机播放流畅度验收。

## 其他验证

- 儿童端 flutter analyze 无问题，18 项测试通过；包括用量展示、取消/确认清理、接口不可用不影响页面，以及原有切换/续播/随机/布局回归。
- Go 25 项测试及 vet 通过；未改后端业务。
- 新增原生代码已由 Gradle 编译并运行以上测试。

本机首次下载测试运行时遇到网络截断，通过分段续取并与仓库 SHA-1 校验后补齐测试依赖，未使用未校验的残缺文件。Robolectric 仓库默认 Maven Central，可通过 FAMILY_ROBOLECTRIC_REPO_URL 指定开发环境镜像；此配置不影响应用运行。

## 边界

磁盘缓存中的字节不会因为播放器被淘汰而删除，但容量淘汰、手动清理、清除应用数据或卸载会使其丢失。自动缓存未增加离线内容目录和完整性承诺。HLS 清单随授权更新可能有少量网络请求；源文件以不可变 ID 为前提。当前未执行手机/电视原生播放与重启后的实机验收。
