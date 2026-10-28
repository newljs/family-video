package cn.familyvideo.tv_app

import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.util.UUID

data class DiscoveredServer(val name: String, val url: String)

class LanDiscovery {
    companion object {
        fun localPeer(address: InetAddress): Boolean {
            if (address !is Inet4Address || address.isLoopbackAddress) return false
            val bytes = address.address.map { it.toInt() and 255 }
            return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] in 16..31) ||
                (bytes[0] == 192 && bytes[1] == 168) || address.isLinkLocalAddress
        }
    }

    fun scan(): List<DiscoveredServer> {
        val nonce = UUID.randomUUID().toString().replace("-", "")
        val request = JSONObject().put("service", "family-video").put("kind", "discover")
            .put("protocol", 1).put("nonce", nonce).toString().toByteArray(Charsets.UTF_8)
        val candidates = linkedMapOf<String, DiscoveredServer>()
        val targets = mutableSetOf(InetAddress.getByName("255.255.255.255"))
        NetworkInterface.getNetworkInterfaces()?.toList()?.forEach { network ->
            network.interfaceAddresses.forEach { binding -> binding.broadcast?.let { targets += it } }
        }
        DatagramSocket().use { socket ->
            socket.broadcast = true
            socket.soTimeout = 250
            val deadline = System.nanoTime() + 4_000_000_000L
            var sent = 0L
            while (System.nanoTime() < deadline && !Thread.currentThread().isInterrupted) {
                val now = System.nanoTime()
                if (now - sent >= 1_000_000_000L) {
                    targets.forEach { target ->
                        try { socket.send(DatagramPacket(request, request.size, target, 8766)) }
                        catch (_: java.io.IOException) { /* Another interface may succeed. */ }
                    }
                    sent = now
                }
                val packet = DatagramPacket(ByteArray(513), 513)
                try { socket.receive(packet) } catch (_: SocketTimeoutException) { continue }
                if (packet.length > 512 || !localPeer(packet.address) || candidates.size >= 8) continue
                try {
                    val data = JSONObject(String(packet.data, packet.offset, packet.length, Charsets.UTF_8))
                    if (data.optString("service") != "family-video" || data.optString("kind") != "server" ||
                        data.optInt("protocol") != 1 || data.optString("nonce") != nonce ||
                        !data.optString("instance_id").matches(Regex("[a-f0-9]{32}"))) continue
                    val port = data.optInt("http_port")
                    if (port !in 1..65535) continue
                    val url = "http://${packet.address.hostAddress}:$port"
                    val name = data.optString("name", "家庭电脑").take(64).replace(Regex("[\\p{Cntrl}]"), " ")
                    candidates[url] = DiscoveredServer(name.ifBlank { "家庭电脑" }, url)
                } catch (_: Exception) { /* Ignore unrelated/malformed UDP packets. */ }
            }
        }
        return candidates.values.filter {
            if (Thread.currentThread().isInterrupted) false else {
                try { FamilyApi(it.url).verify(1000); true } catch (_: Exception) { false }
            }
        }
    }
}
