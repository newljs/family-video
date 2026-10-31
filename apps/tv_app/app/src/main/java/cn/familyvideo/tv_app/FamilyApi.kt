package cn.familyvideo.tv_app

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

class HttpFailure(val status: Int) : IOException("HTTP $status")

/** No HTTP response cache, file IO, database, preferences or image loader. */
class FamilyApi(val server: String, private val clientId: String = "") {
    companion object {
        fun normalize(raw: String): String {
            val value = raw.trim().let { if (it.contains("://")) it else "http://$it" }
            val uri = try { URI(value) } catch (error: java.net.URISyntaxException) {
                throw IllegalArgumentException("请输入电脑的 HTTP 地址", error)
            }
            require(uri.scheme in listOf("http", "https") && !uri.host.isNullOrEmpty() &&
                uri.userInfo == null && uri.query == null && uri.fragment == null &&
                (uri.port == -1 || uri.port in 1..65535)) { "请输入电脑的 HTTP 地址" }
            return value.trimEnd('/')
        }
    }

    fun request(path: String, body: JSONObject? = null, timeout: Int = 4000): String {
        val connection = URL(server + path).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = timeout
            connection.readTimeout = timeout
            connection.useCaches = false
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("X-Family-Client", "child")
            // 电视端标识：服务端据此豁免每日时长限制（安静模式不收缩电视目录），
            // 观看统计仍按设备照常记录。
            connection.setRequestProperty("X-Family-App", "tv")
            if (clientId.isNotEmpty()) {
                connection.setRequestProperty("X-Family-Client-Id", clientId)
            }
            connection.setRequestProperty("Cache-Control", "no-store")
            if (body != null) {
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            if (status !in 200..299) throw HttpFailure(status)
            return connection.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                // Protect low-memory devices from an accidental unbounded directory response.
                val result = StringBuilder()
                val buffer = CharArray(4096)
                while (true) {
                    val count = reader.read(buffer)
                    if (count < 0) break
                    if (result.length + count > 8 * 1024 * 1024) throw IOException("视频目录过大")
                    result.append(buffer, 0, count)
                }
                result.toString()
            }
        } finally { connection.disconnect() }
    }

    fun verify(timeout: Int = 2000) {
        val health = JSONObject(request("/health", timeout = timeout))
        require(health.optString("backend") == "go" && health.optString("status") == "ok") {
            "这不是家庭视频服务器"
        }
    }

    private fun videos(array: JSONArray): List<Video> = (0 until array.length()).mapNotNull { index ->
        val item = array.getJSONObject(index)
        val id = item.optString("id")
        val media = item.optString("media_url")
        if (id.isEmpty() || media.isEmpty()) null else {
            val url = if (media.startsWith('/')) server + media else URI(server + "/").resolve(media).toString()
            Video(id, item.optString("title", "家庭视频"), url, item.optInt("completed_count", 0) > 0)
        }
    }

    fun catalog(): Catalog {
        val videos = videos(JSONArray(request("/api/videos")))
        val collections = JSONArray(request("/api/collections"))
        val channels = (0 until collections.length()).map { index ->
            val item = collections.getJSONObject(index)
            Channel(item.getString("id"), item.optString("title", "合集"),
                videos(item.optJSONArray("videos") ?: JSONArray()))
        }
        return Catalog(videos, channels)
    }

    /** 上报观看事件；返回是否成功。电视端不参与每日时长限制，响应的额度字段忽略。 */
    fun report(events: List<WatchEvent>): Boolean {
        val reports = JSONArray()
        events.forEach {
            reports.put(JSONObject().put("event_id", it.id).put("day", it.day).put("video_id", it.videoId)
                .put("watched_ms", it.watchedMs).put("played", it.played).put("completed", it.completed))
        }
        request("/api/watch", JSONObject().put("reports", reports))
        return true
    }
}
