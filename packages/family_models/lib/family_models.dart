class FamilyVideo {
  final String id, title, description, mediaUrl, thumbnailUrl;
  final double duration;
  final String? streamUrl;
  FamilyVideo.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      title = json['title'] as String,
      description = json['description'] as String? ?? '',
      streamUrl = json['stream_url'] as String?,
      mediaUrl = json['media_url'] as String,
      thumbnailUrl = json['thumbnail_url'] as String,
      duration = (json['duration'] as num).toDouble();
}
