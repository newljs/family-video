/// platform_interface 6.7.0 起才提供 VideoTrack；当前依赖 6.6.0，
/// 由本文件提供字段兼容定义（仅本包内部选轨辅助逻辑使用，门面不会触达）。
class VideoTrack {
  VideoTrack({
    required this.id,
    required this.isSelected,
    this.label,
    this.bitrate,
    this.width,
    this.height,
    this.frameRate,
    this.codec,
  });

  final String id;
  final bool isSelected;
  final String? label;
  final int? bitrate;
  final int? width;
  final int? height;
  final double? frameRate;
  final String? codec;
}
