package cn.familyvideo.tv_app

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.mp4.FragmentedMp4Extractor
import androidx.media3.extractor.mp4.Mp4Extractor
import androidx.media3.ui.PlayerView
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.Future

@UnstableApi
class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private val network = Executors.newSingleThreadExecutor()
    private var scanTask: Future<*>? = null
    private lateinit var root: FrameLayout
    private lateinit var playerView: PlayerView
    private lateinit var status: TextView
    private lateinit var title: TextView
    private lateinit var connection: ScrollView
    private lateinit var connectionItems: LinearLayout
    private var dialog: AlertDialog? = null
    private var player: ExoPlayer? = null
    private var api: FamilyApi? = null
    private var queue = PlaybackQueue()
    private var ledger = WatchLedger()
    private var activeVideo: Video? = null
    private var active = false
    private var generation = 0
    private var refreshing = false
    private var recovering = false
    private var catalogFresh = false
    private var reporting = false
    private var wantsPlayback = true
    private var needsStart = true
    private var retryCount = 0
    private var playVersion = 0
    private var reconnectDelay = 3000L
    private var bufferSince = 0L
    private var lastRefresh = 0L
    private var lastReport = 0L
    private var pendingDelta = 0
    private val clientId: String by lazy {
        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
            ?.takeIf { Regex("^[A-Za-z0-9_-]{1,64}$").matches(it) }
            ?: UUID.randomUUID().toString()
    }
    private val switchVideo = Runnable {
        val delta = pendingDelta
        pendingDelta = 0
        advance(delta)
    }
    private val hideTitle = Runnable { title.visibility = View.GONE }
    private val reconnect = Runnable {
        queue.failed.clear()
        refresh(start = needsStart)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK); isFocusableInTouchMode = true }
        playerView = layoutInflater.inflate(R.layout.player, root, false) as PlayerView
        root.addView(playerView)
        title = text(20f).apply {
            setPadding(dp(30), dp(16), dp(30), dp(20))
            setBackgroundColor(0xCC000000.toInt())
            visibility = View.GONE
        }
        root.addView(title, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))
        status = text(24f).apply { gravity = Gravity.CENTER; setPadding(dp(40), dp(24), dp(40), dp(24)) }
        root.addView(status, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER))
        connectionItems = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(48), dp(28), dp(48), dp(28))
            gravity = Gravity.CENTER_HORIZONTAL
        }
        connection = ScrollView(this).apply {
            setBackgroundColor(Color.BLACK)
            isFillViewport = true
            isSaveEnabled = false
            addView(connectionItems)
        }
        root.addView(connection, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
        immersive()
        // Optional adb test entry, held in memory just like a manually entered address.
        intent.getStringExtra("server")?.let {
            try { api = FamilyApi(FamilyApi.normalize(it), clientId) } catch (_: Exception) { /* Show connection UI. */ }
        }
    }

    override fun onStart() {
        super.onStart()
        active = true
        generation++
        refreshing = false
        recovering = false
        catalogFresh = false
        ensurePlayer()
        if (api == null) discover() else {
            connection.visibility = View.GONE
            status("正在连接家庭电脑…")
            refresh(start = true)
        }
        handler.post(tick)
    }

    override fun onStop() {
        sample()
        ledger.seal()
        flushReports(force = true)
        // The response callback may be removed with the handler below; do not
        // leave reporting=true and block every future flush.
        reporting = false
        active = false
        generation++
        scanTask?.cancel(true)
        handler.removeCallbacksAndMessages(null)
        pendingDelta = 0
        dialog?.dismiss()
        dialog = null
        playerView.player = null
        player?.release()
        player = null
        activeVideo = null
        needsStart = true
        bufferSince = 0
        super.onStop()
    }

    override fun onDestroy() {
        // Let the final small watch report finish; no background playback or persistent worker.
        network.shutdown()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) immersive()
    }

    @Suppress("DEPRECATION")
    private fun immersive() {
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
    }

    private fun ensurePlayer() {
        if (player != null) return
        val http = DefaultHttpDataSource.Factory().setConnectTimeoutMs(4000).setReadTimeoutMs(6000)
            .setUserAgent("FamilyVideoTV/0.1.0")
            .setDefaultRequestProperties(mapOf("X-Family-Client" to "child", "Cache-Control" to "no-store"))
        val source = ProgressiveMediaSource.Factory(http, ExtractorsFactory {
            arrayOf(Mp4Extractor(0), FragmentedMp4Extractor(0))
        })
        val load = DefaultLoadControl.Builder().setBufferDurationsMs(3000, 8000, 500, 1000)
            .setTargetBufferBytes(4 * 1024 * 1024).setPrioritizeTimeOverSizeThresholds(false)
            .setBackBuffer(0, false).build()
        player = ExoPlayer.Builder(this).setMediaSourceFactory(source).setLoadControl(load).build().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            setHandleAudioBecomingNoisy(true)
            addListener(object : Player.Listener {
                override fun onIsPlayingChanged(isPlaying: Boolean) { sample() }
                override fun onPlaybackStateChanged(playbackState: Int) {
                    if (!active || recovering || needsStart) return
                    sample()
                    when (playbackState) {
                        Player.STATE_IDLE -> Unit
                        Player.STATE_BUFFERING -> {
                            if (bufferSince == 0L) bufferSince = SystemClock.elapsedRealtime()
                            status("正在缓冲…")
                        }
                        Player.STATE_READY -> {
                            bufferSince = 0
                            status.visibility = View.GONE
                        }
                        Player.STATE_ENDED -> {
                            ledger.seal(completed = true)
                            flushReports()
                            handler.post { if (active && player?.playbackState == Player.STATE_ENDED) advance(1) }
                        }
                    }
                }
                override fun onPlayerError(error: PlaybackException) {
                    if (active) recoverPlayback()
                }
            })
        }
        playerView.player = player
    }

    private fun text(size: Float) = TextView(this).apply { textSize = size; setTextColor(Color.WHITE) }
    private fun dp(value: Int) = (resources.displayMetrics.density * value).toInt()
    private fun status(message: String) { status.text = message; status.visibility = View.VISIBLE }
    private fun addButton(label: String, action: () -> Unit): Button = Button(this).apply {
        text = label
        textSize = 20f
        isAllCaps = false
        isSaveEnabled = false
        setOnClickListener { action() }
        connectionItems.addView(this, LinearLayout.LayoutParams(dp(480), -2))
    }

    private fun connectionScreen(message: String, servers: List<DiscoveredServer> = emptyList(), scanning: Boolean = false) {
        connection.visibility = View.VISIBLE
        status.visibility = View.GONE
        title.visibility = View.GONE
        connectionItems.removeAllViews()
        connectionItems.addView(text(30f).apply { text = "小小放映室 TV"; gravity = Gravity.CENTER })
        connectionItems.addView(text(18f).apply {
            text = message
            gravity = Gravity.CENTER
            setPadding(0, dp(14), 0, dp(18))
        })
        servers.forEach { server -> addButton("${server.name} · ${server.url}") { connect(server.url) } }
        if (!scanning) addButton("重新搜索家庭电脑") { discover() }
        addButton("手动输入电脑地址") { manualAddress() }
        connectionItems.getChildAt(2)?.requestFocus()
    }

    private fun discover() {
        val token = ++generation
        scanTask?.cancel(true)
        connectionScreen("正在搜索同一局域网的家庭电脑…", scanning = true)
        scanTask = network.submit {
            val servers = try { LanDiscovery().scan() } catch (_: Exception) { emptyList() }
            handler.post {
                if (!active || token != generation) return@post
                when (servers.size) {
                    1 -> connect(servers.first().url)
                    0 -> connectionScreen("没有找到电脑，请检查网络和服务程序，或手动输入地址。")
                    else -> connectionScreen("请选择家庭电脑", servers)
                }
            }
        }
    }

    private fun manualAddress() {
        scanTask?.cancel(true)
        generation++
        val input = EditText(this).apply {
            hint = "例如 192.168.1.10:8765"
            textSize = 20f
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            isSingleLine = true
            isSaveEnabled = false
            setText(api?.server ?: "")
        }
        val box = FrameLayout(this).apply {
            setPadding(dp(24), dp(10), dp(24), 0)
            addView(input)
        }
        dialog = AlertDialog.Builder(this).setTitle("家庭电脑地址").setView(box)
            .setPositiveButton("连接", null).setNegativeButton("取消", null).create().apply {
                setOnShowListener {
                    getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                        try {
                            val address = FamilyApi.normalize(input.text.toString())
                            dismiss()
                            connect(address)
                        } catch (_: Exception) { input.error = "请输入有效地址，例如 192.168.1.10:8765" }
                    }
                }
                setOnDismissListener {
                    dialog = null
                    if (api == null && active) connectionScreen("请选择搜索，或手动输入电脑地址。")
                }
                show()
            }
    }

    private fun connect(address: String) {
        generation++
        playVersion++
        scanTask?.cancel(true)
        handler.removeCallbacks(reconnect)
        sample()
        player?.stop()
        player?.clearMediaItems()
        api = FamilyApi(address, clientId)
        queue = PlaybackQueue()
        ledger = WatchLedger()
        activeVideo = null
        reporting = false
        refreshing = false
        recovering = false
        catalogFresh = false
        needsStart = true
        wantsPlayback = true
        retryCount = 0
        reconnectDelay = 3000
        connection.visibility = View.GONE
        root.requestFocus()
        status("正在连接家庭电脑…")
        refresh(start = true)
    }

    private fun refresh(start: Boolean = false) {
        val client = api ?: return
        if (refreshing || recovering || !active) return
        refreshing = true
        val token = generation
        val version = playVersion
        network.execute {
            try {
                client.verify()
                val catalog = client.catalog()
                handler.post {
                    if (!active || token != generation) return@post
                    refreshing = false
                    lastRefresh = SystemClock.elapsedRealtime()
                    reconnectDelay = 3000
                    catalogFresh = true
                    queue.applyCatalog(catalog)
                    if (queue.channelId.isNotEmpty() && catalog.channels.none { it.id == queue.channelId }) queue.channelId = ""
                    if (needsStart || (start && version == playVersion)) advance(0)
                }
            } catch (_: Exception) {
                handler.post {
                    if (!active || token != generation) return@post
                    refreshing = false
                    lastRefresh = SystemClock.elapsedRealtime()
                    catalogFresh = false
                    if (start || needsStart) {
                        needsStart = true
                        status("暂时连不上家庭电脑，正在重试…\n确认重试 · 左键连接设置")
                        scheduleReconnect()
                    }
                }
            }
        }
    }

    private fun advance(delta: Int) {
        if (!active || api == null || !catalogFresh || connection.visibility == View.VISIBLE) return
        if (delta != 0) wantsPlayback = true
        handler.removeCallbacks(reconnect)
        val video = queue.next(delta)
        if (video == null) {
            playVersion++
            recovering = false
            sample()
            ledger.seal()
            player?.stop()
            player?.clearMediaItems()
            activeVideo = null
            needsStart = true
            bufferSince = 0
            status("暂时没有可播放的视频\n确认刷新 · 左键选择合集")
            handler.postDelayed(reconnect, 30000)
            return
        }
        retryCount = 0
        play(video)
    }

    private fun play(video: Video, position: Long = 0, continuing: Boolean = false) {
        val current = player ?: return
        playVersion++
        sample()
        if (continuing) ledger.rebase(SystemClock.elapsedRealtime(), position)
        else ledger.start(video.id, SystemClock.elapsedRealtime(), position)
        activeVideo = video
        queue.currentId = video.id
        needsStart = false
        recovering = false
        bufferSince = SystemClock.elapsedRealtime()
        status("正在加载…")
        current.setMediaItem(MediaItem.Builder().setMediaId(video.id).setUri(video.url)
            .setMimeType(MimeTypes.VIDEO_MP4).build(), position)
        current.prepare()
        current.playWhenReady = wantsPlayback
        showTitle()
    }

    private fun showTitle() {
        val video = activeVideo ?: return
        val current = player
        val elapsed = (current?.currentPosition ?: 0) / 1000
        val duration = (current?.duration ?: 0).coerceAtLeast(0) / 1000
        val state = if (wantsPlayback) "" else " · 已暂停"
        title.text = "${video.title}$state\n${elapsed / 60}:${(elapsed % 60).toString().padStart(2, '0')} / " +
            "${duration / 60}:${(duration % 60).toString().padStart(2, '0')}    ↑↓ 切换   确认 暂停   ← 合集"
        title.visibility = View.VISIBLE
        handler.removeCallbacks(hideTitle)
        handler.postDelayed(hideTitle, 4000)
    }

    private fun recoverPlayback() {
        if (recovering || !active || needsStart) return
        val client = api ?: return
        val video = activeVideo ?: return
        sample()
        val position = player?.currentPosition ?: 0
        player?.stop()
        bufferSince = 0
        catalogFresh = false
        recovering = true
        val token = generation
        val version = playVersion
        status("正在重新连接…")
        network.execute {
            try {
                client.verify()
                val catalog = client.catalog()
                handler.post {
                    if (!active || token != generation || version != playVersion ||
                        connection.visibility == View.VISIBLE) {
                        recovering = false
                        return@post
                    }
                    recovering = false
                    catalogFresh = true
                    queue.applyCatalog(catalog)
                    val refreshed = queue.items()
                        .firstOrNull { it.id == video.id }
                    if (refreshed != null && retryCount++ == 0) play(refreshed, position, continuing = true)
                    else {
                        queue.failed += video.id
                        advance(1)
                    }
                }
            } catch (_: Exception) {
                handler.post {
                    if (!active || token != generation || version != playVersion ||
                        connection.visibility == View.VISIBLE) {
                        recovering = false
                        return@post
                    }
                    recovering = false
                    needsStart = true
                    status("网络暂时断开，正在重新连接…\n确认重试 · 左键连接设置")
                    scheduleReconnect()
                }
            }
        }
    }

    private fun scheduleReconnect() {
        handler.removeCallbacks(reconnect)
        handler.postDelayed(reconnect, reconnectDelay)
        reconnectDelay = (reconnectDelay * 2).coerceAtMost(30000)
    }

    private fun sample() {
        val current = player ?: return
        ledger.sample(SystemClock.elapsedRealtime(), current.currentPosition, active && current.isPlaying)
    }

    private fun flushReports(force: Boolean = false) {
        val client = api ?: return
        if (reporting && !force) return
        ledger.seal()
        val reportingLedger = ledger
        val events = reportingLedger.batch()
        if (events.isEmpty()) return
        reporting = true
        network.execute {
            val ok = try { client.report(events) } catch (_: Exception) { false }
            handler.post {
                if (ok) reportingLedger.acknowledge(events.map { it.id }.toSet())
                if (reportingLedger !== ledger) return@post
                reporting = false
            }
        }
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!active) return
            sample()
            val now = SystemClock.elapsedRealtime()
            if (now - lastReport >= 10000) {
                lastReport = now
                flushReports()
            }
            if (now - lastRefresh >= 30000 && !needsStart) refresh()
            if (bufferSince != 0L && now - bufferSince > 15000 && wantsPlayback) recoverPlayback()
            handler.postDelayed(this, 1000)
        }
    }

    private fun channels() {
        if (dialog?.isShowing == true) return
        val labels = mutableListOf<String>()
        val ids = mutableListOf<String>()
        labels += "全部视频"; ids += ""
        queue.catalog.channels.forEach { labels += it.title; ids += it.id }
        labels += "刷新内容"
        labels += "连接设置"
        dialog = AlertDialog.Builder(this).setTitle("选择播放合集")
            .setItems(labels.toTypedArray()) { _, which ->
                when {
                    which < ids.size -> {
                        wantsPlayback = true
                        queue.channelId = ids[which]
                        queue.currentId = ""
                        queue.failed.clear()
                        advance(0)
                    }
                    which == ids.size -> {
                        queue.failed.clear()
                        refresh(start = needsStart)
                        showTitle()
                    }
                    else -> {
                        sample()
                        ledger.seal()
                        flushReports()
                        generation++
                        playVersion++
                        recovering = false
                        refreshing = false
                        catalogFresh = false
                        handler.removeCallbacks(reconnect)
                        handler.removeCallbacks(switchVideo)
                        pendingDelta = 0
                        player?.stop()
                        activeVideo = null
                        needsStart = true
                        connectionScreen("电脑地址仅在本次运行中保留；退出后重新搜索。")
                    }
                }
            }.setNegativeButton("返回播放", null).create().apply {
                setOnDismissListener { dialog = null }
                show()
            }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (connection.visibility == View.VISIBLE) return super.dispatchKeyEvent(event)
        val handled = event.keyCode in setOf(KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN,
            KeyEvent.KEYCODE_CHANNEL_UP, KeyEvent.KEYCODE_CHANNEL_DOWN, KeyEvent.KEYCODE_DPAD_LEFT,
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_NEXT, KeyEvent.KEYCODE_MEDIA_PREVIOUS, KeyEvent.KEYCODE_MENU)
        if (!handled) return super.dispatchKeyEvent(event)
        if (event.action != KeyEvent.ACTION_DOWN || event.repeatCount > 0) return true
        val switching = event.keyCode in setOf(KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_CHANNEL_UP,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_CHANNEL_DOWN,
            KeyEvent.KEYCODE_MEDIA_NEXT)
        if (switching && (!catalogFresh || recovering)) return true
        when (event.keyCode) {
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_CHANNEL_UP, KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_CHANNEL_DOWN, KeyEvent.KEYCODE_MEDIA_NEXT -> {
                val previous = event.keyCode in setOf(KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_CHANNEL_UP,
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS)
                pendingDelta += if (previous) -1 else 1
                sample()
                player?.pause()
                handler.removeCallbacks(switchVideo)
                handler.postDelayed(switchVideo, 180)
            }
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MENU -> channels()
            KeyEvent.KEYCODE_DPAD_RIGHT -> showTitle()
            else -> {
                if (needsStart || recovering) {
                    queue.failed.clear()
                    refresh(start = true)
                } else {
                    sample()
                    wantsPlayback = when (event.keyCode) {
                        KeyEvent.KEYCODE_MEDIA_PLAY -> true
                        KeyEvent.KEYCODE_MEDIA_PAUSE -> false
                        else -> !wantsPlayback
                    }
                    player?.playWhenReady = wantsPlayback
                    showTitle()
                }
            }
        }
        return true
    }

    @Deprecated("Legacy back callback also works on API 21 TV remotes")
    override fun onBackPressed() {
        if (connection.visibility == View.VISIBLE && api != null) {
            connection.visibility = View.GONE
            root.requestFocus()
            refresh(start = true)
        } else if (title.visibility == View.VISIBLE) {
            title.visibility = View.GONE
        } else finish()
    }
}
