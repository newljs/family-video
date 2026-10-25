# v0.8.1 儿童端名称与图标

日期：2026-10-25。儿童版本 0.8.1+12，服务及家长应用不变。

- Android application label 与 Flutter title、连接页品牌名称更新为“抖音儿童版”。应用 ID 仍为 cn.familyvideo.kids_app。
- 使用应用宝抖音应用条目的 256×256 原始 PNG，像素文件未重绘；来源与 SHA-256 记录在 assets/branding/README.md。
- Android 24/25 普通图标使用 bitmap drawable，Android 26+ 使用原生 adaptive-icon 包装与安全区 inset，roundIcon 指向同一图标。TV banner 引用相同 PNG。
- 移除五个旧 Flutter 默认密度图标；Flutter 连接页使用同一原始资源，已检查截图。
- flutter analyze 无问题，儿童端原有 18 项测试通过；按项目约定 Go 25 项测试和 vet 通过。没有为纯名称和图标替换增加镜像测试。
- 包名、签名及存储路径保持兼容，采用 adb install -r 覆盖升级，不卸载或清除数据。

截图仍写入 runtime/ui/v05-kids-connection.png，是当前测试重新生成的页面。布局包含测试字体，不代表安装后的系统桌面遮罩；桌面形状由设备启动器决定。
