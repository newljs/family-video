# Family Video local Android player adaptation

Based on Flutter video_player_android 2.12.2 from pub.dev (BSD-3-Clause; LICENSE and AUTHORS retained).
Upstream: https://github.com/flutter/packages/tree/main/packages/video_player/video_player_android

Local changes: PlaybackDiskCache and PlaybackCacheChannel; inject a shared Media3 CacheDataSource into HttpVideoAsset for Family Video media routes, attach cache management channel in VideoPlayerPlugin, add explicit media3-database dependency and native cache regression tests. Dart API and generated Pigeon sources are unchanged. Only kids_app overrides this package.

Cache data is in application filesDir/playback-cache-v1, with a 2 GiB LRU budget. Byte ranges persist across native player disposal and process restart. Media keys include the server and immutable video ID, excluding expiring signature query parameters; playlist keys retain the query so refreshed authorizations fetch a fresh manifest. Cache errors fall back to network. Explicit offline downloads remain separate.
