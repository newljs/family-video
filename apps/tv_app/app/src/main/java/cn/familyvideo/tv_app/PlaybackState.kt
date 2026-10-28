package cn.familyvideo.tv_app

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

data class Video(val id: String, val title: String, val url: String)
data class Channel(val id: String, val title: String, val videos: List<Video>)
data class Catalog(val videos: List<Video>, val channels: List<Channel>)
data class WatchEvent(
    val id: String = UUID.randomUUID().toString(),
    val day: String,
    val videoId: String,
    val watchedMs: Long,
    val played: Boolean = false,
    val completed: Boolean = false,
)

/** In-memory queue only. A single failed item must not create an endless skip loop. */
class PlaybackQueue {
    var catalog = Catalog(emptyList(), emptyList())
    var channelId = ""
    var currentId = ""
    val failed = mutableSetOf<String>()

    private fun source(quiet: Boolean, quietChannel: String): List<Video> =
        if (quiet) {
            catalog.channels.firstOrNull { it.id == quietChannel }?.videos ?: emptyList()
        } else if (channelId.isEmpty()) catalog.videos
        else catalog.channels.firstOrNull { it.id == channelId }?.videos ?: emptyList()

    fun items(quiet: Boolean, quietChannel: String): List<Video> =
        source(quiet, quietChannel).filterNot { it.id in failed }

    fun next(delta: Int, quiet: Boolean, quietChannel: String): Video? {
        val items = items(quiet, quietChannel)
        if (items.isEmpty()) return null
        val current = items.indexOfFirst { it.id == currentId }
        val index = if (current < 0) {
            val original = source(quiet, quietChannel)
            val oldIndex = original.indexOfFirst { it.id == currentId }
            if (oldIndex >= 0 && delta != 0) {
                val direction = if (delta < 0) -1 else 1
                val neighbor = (1..original.size).map { step ->
                    original[((oldIndex + direction * step) % original.size + original.size) % original.size]
                }.first { it.id !in failed }
                val first = items.indexOfFirst { it.id == neighbor.id }
                ((first + delta - direction) % items.size + items.size) % items.size
            } else if (delta < 0) items.lastIndex else 0
        } else ((current + delta) % items.size + items.size) % items.size
        return items[index].also { currentId = it.id }
    }
}

/** Samples advancing playback using monotonic time; pauses, seeks and buffering cost no time. */
class WatchLedger {
    private var sampleTime = 0L
    private var samplePosition = 0L
    private var samplePlaying = false
    private var videoId = ""
    private var played = false
    private var milliseconds = 0L
    private var totalMilliseconds = 0L
    private var day = today()
    private val pending = mutableListOf<WatchEvent>()

    companion object {
        fun today(): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
    }

    fun start(id: String, now: Long, position: Long = 0) {
        seal()
        videoId = id
        sampleTime = now
        samplePosition = position
        samplePlaying = false
        played = false
        milliseconds = 0
        totalMilliseconds = 0
        day = today()
    }

    fun rebase(now: Long, position: Long) {
        sampleTime = now
        samplePosition = position
        samplePlaying = false
    }

    fun sample(now: Long, position: Long, isPlaying: Boolean, date: String = today()): Long {
        if (date != day) {
            seal()
            day = date
        }
        val elapsed = now - sampleTime
        val advanced = position - samplePosition
        val counted = if (videoId.isNotEmpty() && samplePlaying && elapsed in 1..2500 &&
            advanced > 0 && advanced <= elapsed + 500) minOf(elapsed, advanced) else 0
        milliseconds += counted
        totalMilliseconds += counted
        sampleTime = now
        samplePosition = position
        samplePlaying = isPlaying
        return counted
    }

    fun seal(completed: Boolean = false) {
        if (videoId.isEmpty()) return
        val reportPlay = !played && totalMilliseconds >= 1000
        if (milliseconds > 0 || reportPlay || completed) {
            // Bounded RAM even during a very long outage; no on-disk retry queue.
            if (pending.size >= 512) pending.removeAt(0)
            pending += WatchEvent(day = day, videoId = videoId, watchedMs = milliseconds,
                played = reportPlay, completed = completed)
            if (reportPlay) played = true
            milliseconds = 0
        }
    }

    fun batch(): List<WatchEvent> = pending.take(50)
    fun acknowledge(ids: Set<String>) { pending.removeAll { it.id in ids } }
    fun unreportedMs(date: String): Long = pending.filter { it.day == date }.sumOf { it.watchedMs } +
        if (day == date) milliseconds else 0
}

class DailyBudget {
    var limitMinutes = 0
    var serverWatchedMs = 0L
    var day = WatchLedger.today()
    var afterLimitChannel = ""
    fun exhausted(ledger: WatchLedger): Boolean = limitMinutes > 0 &&
        serverWatchedMs + ledger.unreportedMs(day) >= limitMinutes * 60000L
}
