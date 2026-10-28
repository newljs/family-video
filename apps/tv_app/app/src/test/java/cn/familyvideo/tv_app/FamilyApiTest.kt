package cn.familyvideo.tv_app

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress

class FamilyApiTest {
    @Test fun manualAddressValidationPreservesProxyPrefix() {
        assertEquals("http://192.168.1.2:8765", FamilyApi.normalize("192.168.1.2:8765/"))
        assertEquals("http://server:7777/family-video", FamilyApi.normalize(" http://server:7777/family-video/ "))
        listOf("", "file:///data", "http://user:pass@server", "http://server?x=1", "http://server:99999").forEach {
            try { FamilyApi.normalize(it); fail("Accepted $it") } catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun onlyPrivateIpv4PeersParticipateInDiscovery() {
        assertTrue(LanDiscovery.localPeer(InetAddress.getByName("192.168.1.2")))
        assertTrue(LanDiscovery.localPeer(InetAddress.getByName("172.16.0.1")))
        assertFalse(LanDiscovery.localPeer(InetAddress.getByName("172.32.0.1")))
        assertFalse(LanDiscovery.localPeer(InetAddress.getByName("127.0.0.1")))
        assertFalse(LanDiscovery.localPeer(InetAddress.getByName("8.8.8.8")))
        assertFalse(LanDiscovery.localPeer(InetAddress.getByName("::1")))
    }

    @Test fun apiUsesChildRoleNoCacheAndStableWatchIds() {
        val server = MockWebServer()
        listOf(
            """{"status":"ok","backend":"go"}""",
            """[{"id":"a","title":"A","media_url":"/media/a/video?sig=test"}]""",
            """[{"id":"songs","title":"儿歌","videos":[{"id":"a","title":"A","media_url":"/media/a/video?sig=test"}]}]""",
            """{"limit_minutes":10,"watched_ms_today":1234,"day":"2026-10-26","after_limit_collection_id":"songs"}""",
        ).forEach { server.enqueue(MockResponse().setBody(it)) }
        server.start()
        try {
            val base = server.url("/family-video").toString()
            val api = FamilyApi(base)
            api.verify()
            val catalog = api.catalog()
            assertEquals("$base/media/a/video?sig=test", catalog.videos.single().url)
            assertEquals("a", catalog.channels.single().videos.single().id)
            val event = WatchEvent(day = "2026-10-26", videoId = "a", watchedMs = 1000, played = true)
            val budget = api.report(listOf(event))
            assertEquals("songs", budget.afterChannel)
            val requests = (1..4).map { server.takeRequest() }
            assertEquals(listOf("/family-video/health", "/family-video/api/videos",
                "/family-video/api/collections", "/family-video/api/watch"), requests.map { it.path })
            val reported = JSONObject(requests.last().body.readUtf8()).getJSONArray("reports").getJSONObject(0)
            assertEquals(event.id, reported.getString("event_id"))
            assertEquals(1000, reported.getInt("watched_ms"))
            assertTrue(requests.all { it.getHeader("X-Family-Client") == "child" &&
                it.getHeader("Cache-Control") == "no-store" })
        } finally { server.shutdown() }
    }
}
