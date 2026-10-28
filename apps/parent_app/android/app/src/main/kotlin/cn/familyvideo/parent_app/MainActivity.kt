package cn.familyvideo.parent_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.os.Bundle
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

class MainActivity : FlutterActivity() {
    private var shares: MethodChannel? = null
    private val prefs get() = getSharedPreferences("family_shares", MODE_PRIVATE)
    private fun pending() = JSONArray(prefs.getString("pending", "[]") ?: "[]")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) acceptShare(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        shares = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "family_video/shares")
        shares!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "pendingShares" -> {
                    val items = pending()
                    result.success((0 until items.length()).map {
                        val item = items.getJSONObject(it)
                        mapOf("id" to item.getString("id"), "text" to item.getString("text"))
                    })
                }
                "ackShare" -> {
                    val items = pending()
                    val retained = JSONArray()
                    for (i in 0 until items.length()) {
                        val item = items.getJSONObject(i)
                        if (item.getString("id") != call.arguments as? String) retained.put(item)
                    }
                    if (prefs.edit().putString("pending", retained.toString()).commit()) result.success(null)
                    else result.error("storage", "无法保存分享收集箱", null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptShare(intent)
    }

    private fun acceptShare(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND || intent.type?.startsWith("text/") != true) return
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim() ?: return
        if (text.isEmpty() || text.length > 10000) return
        val items = pending()
        // Recreating this Activity with the same Intent must not enqueue twice.
        val id = intent.getStringExtra("family_share_id") ?: UUID.randomUUID().toString().also {
            intent.putExtra("family_share_id", it)
        }
        if ((0 until items.length()).any { items.getJSONObject(it).getString("id") == id }) return
        items.put(JSONObject().put("id", id).put("text", text))
        if (prefs.edit().putString("pending", items.toString()).commit()) shares?.invokeMethod("sharesAvailable", null)
    }
}
