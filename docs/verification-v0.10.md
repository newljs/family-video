# v0.10 按客户端观看数据与推荐顺序

日期：2026-10-31。服务端 `0.10.0`，家长端 `0.9.3+13`，儿童端 `0.10.0+16`，TV `0.2.0+2`；数据库 schema v7。

## 行为

- 儿童端每次进程启动重新随机未看完内容；TV 每次进程启动后的首次目录随机“全部视频”顺序，刷新保留当前会话顺序并追加新内容。
- “已看”以实现中的 `completed`（完播）为准。该客户端已看完的视频不进入儿童推荐流/TV 全部视频队列；当前库全部看完后，服务端清空该客户端的 `plays/completed` 并保留已看时长，视频重新进入推荐。
- 儿童端安装 ID 持久化在 SharedPreferences；TV 使用系统 `ANDROID_ID`，不写入本地存储。两端通过 `X-Family-Client-Id` 上报，服务端按客户端保存已看视频、每日已看时长和额度。
- 每日额度按客户端分别计算；家长端/管理台继续使用全局聚合统计。
- 数据库 v6 → v7 自动生成 `before-v7-*.sqlite3`，建立 `client_watch_stats`、`client_watch_days`、`client_watch_events`；历史全局统计不迁移到具体客户端。

## 本机验证

- Go `go test -count=1 ./...`、`go vet ./...` 通过；覆盖客户端额度隔离、已看重置、全局家长视图、schema v7 迁移。
- 用隔离数据目录启动 `bin/family-video-v0.10.0.exe -worker=false`，`/health` 返回 `version: 0.10.0`，旧 schema 数据库成功迁移并生成升级前快照。
- Flutter：儿童端 44、家长端 21、family_api 20 个测试通过；analyze 仅有家长端既有 deprecation info。
- TV：`:app:testDebugUnitTest`、`:app:assembleDebug` 通过。
- 构建产物：家长 `0.9.3+13`、儿童 `0.10.0+16` debug APK，TV trial `0.2.0+2`。正式签名发布包尚未构建。

## 未验收

- 真实平板/TV 上双客户端并行观看、时区/时钟异常、全部看完后的跨启动重置。
- TV `ANDROID_ID` 在恢复出厂、不同签名包下的稳定性。
- 真实设备的推荐滑动与播放连续性。
