package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;

import android.content.Context;
import android.net.Uri;
import androidx.media3.common.C;
import androidx.media3.database.StandaloneDatabaseProvider;
import androidx.media3.datasource.ByteArrayDataSource;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.TransferListener;
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor;
import androidx.media3.datasource.cache.SimpleCache;
import androidx.test.core.app.ApplicationProvider;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.util.Arrays;
import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.rules.TemporaryFolder;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public final class PlaybackDiskCacheTest {
  @Rule public TemporaryFolder temporary = new TemporaryFolder();

  private static final String SEGMENT="http://192.168.1.2:8765/media/video-a/segment00000.ts";

  private static final class Network implements DataSource.Factory {
    final byte[] data;
    int opens=0,bytesRead=0;
    boolean unavailable=false;
    Network(int length) {
      data=new byte[length];
      for(int i=0;i<length;i++) data[i]=(byte)(i%251);
    }
    @Override public DataSource createDataSource() {
      return new DataSource() {
        final ByteArrayDataSource source=new ByteArrayDataSource(data);
        @Override public void addTransferListener(TransferListener listener) { source.addTransferListener(listener); }
        @Override public long open(DataSpec spec) throws IOException {
          opens++;
          if(unavailable) throw new IOException("upstream unavailable");
          return source.open(spec);
        }
        @Override public int read(byte[] target,int offset,int length) throws IOException {
          int read=source.read(target,offset,length);
          if(read>0) bytesRead+=read;
          return read;
        }
        @Override public Uri getUri() { return source.getUri(); }
        @Override public void close() throws IOException { source.close(); }
      };
    }
  }

  private static DataSpec spec(String uri,long start,long length) {
    return new DataSpec.Builder().setUri(uri).setPosition(start).setLength(length).build();
  }
  private static byte[] read(SimpleCache cache,Network network,DataSpec spec) throws IOException {
    DataSource source=PlaybackDiskCache.factory(cache,network).createDataSource();
    try {
      source.open(spec);
      ByteArrayOutputStream bytes=new ByteArrayOutputStream();
      byte[] buffer=new byte[1024];
      int count;
      while((count=source.read(buffer,0,buffer.length))!=C.RESULT_END_OF_INPUT) bytes.write(buffer,0,count);
      return bytes.toByteArray();
    } finally { source.close(); }
  }

  @Test public void bytesSurvivePlayerAndCacheRecreationAndSignatureRefresh() throws Exception {
    Context context=ApplicationProvider.getApplicationContext();
    File folder=temporary.newFolder();
    StandaloneDatabaseProvider database=new StandaloneDatabaseProvider(context);
    SimpleCache cache=new SimpleCache(folder,new LeastRecentlyUsedCacheEvictor(1024*1024),database);
    Network network=new Network(32*1024);
    try {
      // More distinct videos than the Flutter native-player pool can retain.
      for(int video=0;video<6;video++) {
        String uri=SEGMENT.replace("video-a","video-"+video)+"?expires=1&sig=first";
        assertArrayEquals(network.data,read(cache,network,spec(uri,0,network.data.length)));
      }
      assertEquals(6,network.opens);
    } finally { cache.release();database.close(); }
    // Reopen the real disk cache with fresh indexes/data sources, as after an app restart.
    StandaloneDatabaseProvider reopenedDatabase=new StandaloneDatabaseProvider(context);
    SimpleCache reopened=new SimpleCache(folder,new LeastRecentlyUsedCacheEvictor(1024*1024),reopenedDatabase);
    network.unavailable=true;
    int opensBefore=network.opens;
    try {
      for(int video=0;video<6;video++) {
        String uri=SEGMENT.replace("video-a","video-"+video)+"?expires=999&sig=refreshed";
        assertArrayEquals(network.data,read(reopened,network,spec(uri,0,network.data.length)));
      }
      assertEquals("cached replay must not open the upstream",opensBefore,network.opens);
      assertEquals(6*network.data.length,reopened.getCacheSpace());
    } finally { reopened.release();reopenedDatabase.close(); }
  }

  @Test public void overlappingMp4RangesOnlyReadMissingBytes() throws Exception {
    Context context=ApplicationProvider.getApplicationContext();
    StandaloneDatabaseProvider database=new StandaloneDatabaseProvider(context);
    SimpleCache cache=new SimpleCache(temporary.newFolder(),new LeastRecentlyUsedCacheEvictor(1024*1024),database);
    Network network=new Network(32*1024);
    String uri="http://home:8765/media/video-a/video";
    try {
      assertArrayEquals(Arrays.copyOfRange(network.data,0,8192),read(cache,network,spec(uri+"?sig=a",0,8192)));
      assertArrayEquals(Arrays.copyOfRange(network.data,4096,12288),read(cache,network,spec(uri+"?sig=b",4096,8192)));
      assertEquals(12288,network.bytesRead);
    } finally { cache.release();database.close(); }
  }

  @Test public void lruBudgetEvictsOldBytesInsteadOfLimitingVideoCount() throws Exception {
    Context context=ApplicationProvider.getApplicationContext();
    StandaloneDatabaseProvider database=new StandaloneDatabaseProvider(context);
    SimpleCache cache=new SimpleCache(temporary.newFolder(),new LeastRecentlyUsedCacheEvictor(8192),database);
    Network network=new Network(4096);
    String a=SEGMENT.replace("video-a","a"),b=SEGMENT.replace("video-a","b"),c=SEGMENT.replace("video-a","c");
    try {
      read(cache,network,spec(a,0,4096));Thread.sleep(10);
      read(cache,network,spec(b,0,4096));Thread.sleep(10);
      read(cache,network,spec(a,0,4096));Thread.sleep(10);
      read(cache,network,spec(c,0,4096));
      assertTrue(cache.getCacheSpace()<=8192);
      network.unavailable=true;
      assertArrayEquals(network.data,read(cache,network,spec(a,0,4096)));
      assertThrows(IOException.class,()->read(cache,network,spec(b,0,4096)));
    } finally { cache.release();database.close(); }
  }

  @Test public void keysIsolateServersVideosAndFreshManifests() {
    DataSpec old=spec(SEGMENT+"?sig=a&expires=1",0,1024);
    DataSpec fresh=spec(SEGMENT+"?sig=b&expires=2",1024,1024);
    assertEquals(PlaybackDiskCache.key(old),PlaybackDiskCache.key(fresh));
    assertNotEquals(PlaybackDiskCache.key(old),PlaybackDiskCache.key(spec(SEGMENT.replace("video-a","video-b"),0,1024)));
    assertNotEquals(PlaybackDiskCache.key(old),PlaybackDiskCache.key(spec(SEGMENT.replace("192.168.1.2","192.168.1.3"),0,1024)));
    String playlist=SEGMENT.replace("segment00000.ts","stream.m3u8");
    assertNotEquals(PlaybackDiskCache.key(spec(playlist+"?sig=a",0,1024)),PlaybackDiskCache.key(spec(playlist+"?sig=b",0,1024)));
    assertFalse(PlaybackDiskCache.eligible(Uri.parse("https://other.test/movie.mp4")));
    assertFalse(PlaybackDiskCache.eligible(Uri.parse("file:///media/a/video")));
  }
  @Test public void clearingPlaybackBytesPreservesExplicitOfflineFiles() throws Exception {
    Context context=ApplicationProvider.getApplicationContext();
    File offline=new File(context.getFilesDir(),"offline/manual-video.mp4");
    assertTrue(offline.getParentFile().mkdirs() || offline.getParentFile().isDirectory());
    java.nio.file.Files.write(offline.toPath(),new byte[]{1,2,3,4});
    try {
      SimpleCache cache=PlaybackDiskCache.get(context);
      Network network=new Network(4096);
      read(cache,network,spec(SEGMENT,0,4096));
      assertEquals(4096L,PlaybackDiskCache.snapshot(context).get("bytes"));
      assertEquals(0L,PlaybackDiskCache.clear(context).get("bytes"));
      assertArrayEquals(new byte[]{1,2,3,4},java.nio.file.Files.readAllBytes(offline.toPath()));
    } finally { PlaybackDiskCache.releaseForTests(); }
  }

}
