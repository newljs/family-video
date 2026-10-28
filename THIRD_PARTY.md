# 第三方依赖

- 下载器：[Johnserf-Seed/f2](https://github.com/Johnserf-Seed/f2)，Apache-2.0，独立安装并固定上游提交 `f6be8c0ffba9a127075bbeafe4838716650b6325`（v0.0.1.8-pw3 分支；包内版本号仍为 0.0.1.7），完整依赖见 server/downloader-requirements.lock。原 PyPI 0.0.1.7 对当前抖音接口返回 403，本项目用实际分享链接验证该提交能下载。
- 下载器源码未复制入本仓库；具体依赖许可见所安装包的 LICENSE/METADATA。
- Go 主后端依赖 modernc.org/sqlite、github.com/gofrs/flock 和 golang.org/x/sys，版本由 server/go.mod 与 go.sum 固定。
- Flutter、Go 依赖、FFmpeg 及其他依赖各自保留其原有许可证。分发安装包或捆绑运行环境前汇总对应许可文件。
- 项目当前未决定自身开源许可证，不为用户擅自授予代码再分发许可。

- 儿童端 Android 播放器采用 Flutter 官方 video_player_android 2.12.2 的本地适配，保留上游源码、BSD-3-Clause LICENSE/AUTHORS 与 Pigeon 定义，位于 packages/video_player_android；FAMILY_CHANGES.md 列出注入 Media3 磁盘缓存和管理通道的改动。家长端仍使用上游包。Media3 1.9.2 为 Apache-2.0，Gradle 固定版本；缓存采用其 SimpleCache/CacheDataSource/LRU，未自行实现视频格式或平台算法。

- 儿童端应用名称按用户指定为“抖音儿童版”，图标来自应用宝抖音应用条目 https://sj.qq.com/appdetail/com.ss.android.ugc.aweme；原始文件、来源 URL 和摘要见 apps/kids_app/assets/branding/README.md。品牌图形归原权利人所有，不是本项目原创图形。

- 应用内更新依赖 package_info_plus（读取自身版本号）与 url_launcher（调起系统浏览器下载 APK），均为 flutter-community 维护的 BSD-3-Clause 插件，版本由两端 pubspec.yaml 固定。

- 扫码连接依赖 mobile_scanner（基于 ML Kit / CameraX 的二维码扫描插件，MIT 许可），用于家长端与儿童端连接页扫描管理台「手机连接」面板的服务器地址二维码；Android 相机权限由两端 AndroidManifest 声明。

- 独立 TV 客户端位于 apps/tv_app，使用 Kotlin 标准库和 AndroidX Media3 ExoPlayer/UI 1.5.1（Apache-2.0），为兼容 Android API 21 固定版本。仅使用上游播放能力，未复制解码算法，不引入 FFmpeg 原生库。测试依赖 JUnit 4.13.2、org.json 20240303、MockWebServer 4.12.0，不进入 APK。TV 图标和 banner 为本仓库原创矢量图形。
