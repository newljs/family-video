// Family Video adaptation. Upstream plugin BSD license remains in LICENSE.
package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.net.Uri;
import androidx.annotation.OptIn;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.database.StandaloneDatabaseProvider;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.cache.Cache;
import androidx.media3.datasource.cache.CacheDataSource;
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor;
import androidx.media3.datasource.cache.SimpleCache;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Pattern;

/** A process-wide byte cache, independent of native player instances. */
@OptIn(markerClass = UnstableApi.class)
final class PlaybackDiskCache {
  static final long MAX_BYTES = 2L * 1024 * 1024 * 1024;
  private static final Pattern MEDIA = Pattern.compile("^/media/[A-Za-z0-9_-]{1,80}/(?:video|stream\\.m3u8|segment[0-9]{5,8}\\.ts)$");
  private static SimpleCache instance;
  private static StandaloneDatabaseProvider database;

  private PlaybackDiskCache() {}

  static boolean eligible(Uri uri) {
    String scheme=uri.getScheme();
    return ("http".equals(scheme)||"https".equals(scheme))
        && uri.getHost()!=null && uri.getUserInfo()==null
        && uri.getPath()!=null && MEDIA.matcher(uri.getPath()).matches();
  }

  static synchronized SimpleCache get(Context context) {
    if(instance==null) {
      Context app=context.getApplicationContext();
      database=new StandaloneDatabaseProvider(app);
      instance=new SimpleCache(new File(app.getFilesDir(),"playback-cache-v1"),
          new LeastRecentlyUsedCacheEvictor(MAX_BYTES),database);
    }
    return instance;
  }

  static DataSource.Factory wrap(Context context,String source,DataSource.Factory upstream) {
    if(source==null || !eligible(Uri.parse(source))) return upstream;
    try {
      SimpleCache cache=get(context);
      cache.checkInitialization();
      return factory(cache,upstream);
    } catch(Exception unavailable) {
      // Playback stays available when disk caching cannot be initialized.
      return upstream;
    }
  }

  static CacheDataSource.Factory factory(Cache cache,DataSource.Factory upstream) {
    return new CacheDataSource.Factory().setCache(cache)
        .setUpstreamDataSourceFactory(upstream)
        .setCacheKeyFactory(PlaybackDiskCache::key)
        .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR);
  }

  static String key(DataSpec spec) {
    Uri uri=spec.uri;
    // A newly signed playlist must not contain expired URLs from an old one.
    // Immutable media bytes, however, are shared across authorization refreshes.
    String canonical=eligible(uri) && !uri.getPath().endsWith(".m3u8")
        ? uri.buildUpon().clearQuery().fragment(null).build().toString()
        : (spec.key!=null?spec.key:uri.toString());
    try {
      byte[] digest=MessageDigest.getInstance("SHA-256").digest(canonical.getBytes(StandardCharsets.UTF_8));
      StringBuilder result=new StringBuilder(64);
      for(byte b:digest) result.append(String.format(java.util.Locale.ROOT,"%02x",b & 0xff));
      return result.toString();
    } catch(NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
  }

  @androidx.annotation.VisibleForTesting
  static synchronized void releaseForTests() {
    if(instance!=null) { instance.release();instance=null; }
    if(database!=null) { database.close();database=null; }
  }

  static Map<String,Object> snapshot(Context context) {
    SimpleCache cache=get(context);
    Map<String,Object> info=new HashMap<>();
    info.put("bytes",cache.getCacheSpace());
    info.put("limitBytes",MAX_BYTES);
    info.put("resources",cache.getKeys().size());
    return info;
  }

  static Map<String,Object> clear(Context context) throws Cache.CacheException {
    SimpleCache cache=get(context);
    for(String key:cache.getKeys()) cache.removeResource(key);
    return snapshot(context);
  }
}
