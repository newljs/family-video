# 第一阶段验证记录

日期：2026-10-23。

- 两个 Android 调试 APK 均已构建成功：`apps/parent_app/build/app/outputs/flutter-apk/app-debug.apk` 与 `apps/kids_app/build/app/outputs/flutter-apk/app-debug.apk`。当前是通用调试包，约 155MB，尚未配置正式签名。
- 服务端：`python -m pytest server/tests -q`，10 项通过；覆盖上传、处理入库、发布隔离、Range、下架、设备撤销、合集顺序、分享链接过滤、F2 参数适配和磁盘不足拒绝。
- 家长端：`flutter test --no-pub`，1 项通过；验证离线收集箱持久保存与删除。`flutter analyze --no-pub` 无问题。
- 儿童端：`flutter test --no-pub`，1 项通过；验证配对入口和无效服务器地址处理。`flutter analyze --no-pub` 无问题。
- 后端曾实际启动并通过 HTTP `/health` 返回 200，OpenAPI 包含 14 组路径。
- F2 0.0.1.7 已在独立 Python 3.11 环境安装，`f2 douyin --help` 参数与适配器匹配；上游真实下载未验证，不以 mock 测试替代平台验证。
- 两端没有连接实际安卓电视和平板，不宣称已完成真机适配验收。
- Windows Kotlin 跨 C/D 盘增量缓存错误通过关闭 Kotlin 增量编译、改为进程内编译解决；限制 Gradle 内存为 2GB、并行 worker 为 2。
- 本机 C 盘空间不足 3GB 曾触发预期的上传保护；功能测试隔离了磁盘容量，并另外测试低空间路径。真实数据默认在项目所在 D 盘，构建脚本将临时目录放入 runtime。
- `projects.json` 已登记本项目，`catalog.html` 由脚本生成。全工作区 `--check` 仍报告既有的 Voice-to-Visual、deck-studio、shaonianqikan 未登记，以及 tools 目录缺失；这些与本项目无关。

尚待验收：真实分享链接及登录配置、真机遥控/播放/待机恢复、断网缓存、下架离线传播、完整观看规则。
