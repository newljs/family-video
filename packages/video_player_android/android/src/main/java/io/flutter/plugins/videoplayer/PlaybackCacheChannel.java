package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Only statistics and explicit cleanup cross the bridge; never expose URLs. */
final class PlaybackCacheChannel {
  private final MethodChannel channel;
  private final ExecutorService io=Executors.newSingleThreadExecutor();
  private final Handler main=new Handler(Looper.getMainLooper());

  PlaybackCacheChannel(Context context,BinaryMessenger messenger) {
    channel=new MethodChannel(messenger,"family_video/playback_cache");
    channel.setMethodCallHandler((call,result)->{
      if(!call.method.equals("stats") && !call.method.equals("clear")) {
        result.notImplemented();return;
      }
      io.execute(()->{
        try {
          Map<String,Object> info=call.method.equals("clear")
              ? PlaybackDiskCache.clear(context):PlaybackDiskCache.snapshot(context);
          main.post(()->result.success(info));
        } catch(Exception unavailable) {
          main.post(()->result.error("cache_unavailable","暂时无法管理播放缓存",null));
        }
      });
    });
  }

  void close() { channel.setMethodCallHandler(null);io.shutdown(); }
}
