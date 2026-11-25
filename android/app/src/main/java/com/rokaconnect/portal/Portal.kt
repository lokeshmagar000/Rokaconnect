package com.rokaconnect.portal

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import org.json.JSONObject
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Rokaconnect Portal wire protocol — must match the Mac (PortalProtocol.swift).
 * One TCP connection per transfer. Each frame: 4-byte big-endian length, then a sealed
 * AES-256-GCM box laid out like CryptoKit's `combined`: 12-byte nonce | ciphertext | 16-byte tag.
 */
object Portal {
    const val SERVICE_TYPE = "_rokaportal._tcp."
    const val PORT = 52341
    const val CHUNK = 1 shl 20
    private const val ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

    fun normalize(code: String) = code.uppercase().filter { it in ALPHABET }

    fun pretty(code: String) = normalize(code).chunked(4).joinToString("-")

    /** SHA-256 iterated 50,000 times over "rokaconnect.portal.v1:" + code. */
    fun deriveKey(code: String): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        var d = ("rokaconnect.portal.v1:" + normalize(code)).toByteArray(Charsets.UTF_8)
        repeat(50_000) { d = md.digest(d) }
        return d
    }

    fun deviceName(ctx: Context): String =
        Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"
}

class PortalException(message: String) : Exception(message)

class PortalConnection(host: String, port: Int, private val key: ByteArray) : Closeable {
    private val socket = Socket().apply {
        // big buffers keep Wi-Fi busy while the next piece is being read and encrypted
        sendBufferSize = 4 shl 20; receiveBufferSize = 4 shl 20
    }
    private val input: DataInputStream
    private val output: DataOutputStream
    private val keySpec = SecretKeySpec(key, "AES")
    private val enc = Cipher.getInstance("AES/GCM/NoPadding")     // reused, not created per frame
    private val dec = Cipher.getInstance("AES/GCM/NoPadding")

    init {
        try {
            socket.connect(InetSocketAddress(host, port), 8_000)
        } catch (e: Exception) {
            throw PortalException("Can't reach the Mac. Is Rokaconnect running and on the same Wi-Fi?")
        }
        socket.soTimeout = 30_000
        socket.tcpNoDelay = true
        input = DataInputStream(socket.getInputStream().buffered(1 shl 20))
        output = DataOutputStream(socket.getOutputStream().buffered(1 shl 20))
    }

    /** Small control frames (headers, "OK"): sealed and sent right away. */
    fun sendFrame(plain: ByteArray, offset: Int = 0, length: Int = plain.size) {
        output.write(seal(enc, keySpec, plain, offset, length)); output.flush()
    }

    /** Writes an already-sealed frame (from [seal]); call [flush] at the end. */
    fun writeSealed(frame: ByteArray) = output.write(frame)
    fun flush() = output.flush()

    /** Reads one frame without decrypting it (so another thread can decrypt while the next one arrives). */
    fun recvSealed(): ByteArray {
        val n = try { input.readInt() } catch (e: Exception) {
            throw PortalException("The Mac closed the connection. Check the pairing code in Settings → Portal on the Mac.")
        }
        if (n <= 28 || n > Portal.CHUNK + 64) throw PortalException("Bad frame from Mac")
        return ByteArray(n).also { input.readFully(it) }
    }

    fun recvFrame(): ByteArray = open(dec, keySpec, recvSealed())

    override fun close() { runCatching { socket.close() } }

    companion object {
        private val random = SecureRandom()
        /** One wire frame: 4-byte length | 12-byte nonce | ciphertext | 16-byte tag (same as the Mac). */
        fun seal(c: Cipher, k: SecretKeySpec, plain: ByteArray, offset: Int, length: Int): ByteArray {
            val nonce = ByteArray(12).also(random::nextBytes)
            c.init(Cipher.ENCRYPT_MODE, k, GCMParameterSpec(128, nonce))
            val body = 12 + length + 16
            val out = ByteArray(4 + body)
            out[0] = (body ushr 24).toByte(); out[1] = (body ushr 16).toByte(); out[2] = (body ushr 8).toByte(); out[3] = body.toByte()
            System.arraycopy(nonce, 0, out, 4, 12)
            c.doFinal(plain, offset, length, out, 16)
            return out
        }
        fun open(c: Cipher, k: SecretKeySpec, body: ByteArray): ByteArray {
            c.init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(128, body, 0, 12))
            return try { c.doFinal(body, 12, body.size - 12) } catch (e: Exception) { throw PortalException("Pairing code doesn't match this Mac") }
        }
    }
}

/** Measures speed for the status line ("12.4 MB/s"), updated about twice a second. */
class Speedometer(private val report: (String) -> Unit) {
    private val start = System.nanoTime(); private var last = 0L
    fun tick(bytes: Long) {
        val now = System.nanoTime()
        if (now - last < 500_000_000L) return
        last = now
        val secs = (now - start) / 1e9
        if (secs > 0.3) report(String.format("%.1f MB/s", bytes / 1048576.0 / secs))
    }
}

/** Keeps Wi-Fi in low-latency mode and the CPU awake while a transfer runs (Samsung saves power on Wi-Fi otherwise). */
object TransferLocks {
    private var count = 0
    private var wifi: android.net.wifi.WifiManager.WifiLock? = null
    private var cpu: android.os.PowerManager.WakeLock? = null
    @Synchronized fun <T> hold(ctx: Context, work: () -> T): T {
        if (count++ == 0) runCatching {
            val wm = ctx.applicationContext.getSystemService(android.net.wifi.WifiManager::class.java)
            wifi = wm.createWifiLock(android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "rokaconnect:transfer").apply { setReferenceCounted(false); acquire() }
            val pm = ctx.applicationContext.getSystemService(android.os.PowerManager::class.java)
            cpu = pm.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "rokaconnect:transfer").apply { setReferenceCounted(false); acquire(30 * 60_000L) }
        }
        try { return work() } finally {
            synchronized(this) { if (--count == 0) { runCatching { wifi?.release(); cpu?.release() }; wifi = null; cpu = null } }
        }
    }
}

data class MacFile(val id: Int, val name: String, val size: Long, val direct: Boolean = false)

/** High-level operations against one Mac. All calls block; run them off the main thread. */
class PortalClient(private val ctx: Context, private val host: String, private val port: Int, private val key: ByteArray) {
    private object End
    private val END: Any = End

    private fun header(kind: String, name: String, size: Long) = JSONObject().apply {
        put("kind", kind); put("name", name); put("size", size)
        put("transition", "classic"); put("ts", System.currentTimeMillis() / 1000.0)
        put("from", Portal.deviceName(ctx)); put("platform", "android")
        // battery for the Mac island's Devices widget
        ctx.getSystemService(android.os.BatteryManager::class.java)?.let { bm ->
            val pct = bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
            if (pct in 0..100) { put("battery", pct); put("charging", bm.isCharging) }
        }
    }.toString().toByteArray(Charsets.UTF_8)

    private fun expectOk(conn: PortalConnection) {
        val ack = String(conn.recvFrame(), Charsets.UTF_8)
        if (ack != "OK") throw PortalException("Mac didn't confirm")
    }

    /** Lists what the Mac offers. Also proves the pairing code is right. */
    fun list(): Pair<String, List<MacFile>> = PortalConnection(host, port, key).use { conn ->
        conn.sendFrame(header("list", "", 0))
        val j = JSONObject(String(conn.recvFrame(), Charsets.UTF_8))
        val arr = j.optJSONArray("files")
        val files = (0 until (arr?.length() ?: 0)).map {
            val f = arr!!.getJSONObject(it); MacFile(f.getInt("id"), f.getString("name"), f.getLong("size"), f.optBoolean("direct", false))
        }
        // a clipboard the Mac sent to this phone (menu bar → Send Clipboard to Phone)
        j.optString("clip").takeIf { it.isNotEmpty() && Link.autoClip(ctx) }?.let { ClipSync.applyFromMac(ctx, it, quiet = true) }
        // the Mac's island asked to ring this phone ("Ring phone")
        if (j.optBoolean("ring", false)) PhoneRinger.start(ctx)
        // the Mac's battery and Keep-awake state, for the island's Devices page
        if (j.has("macBattery")) MacState.update(j.optInt("macBattery", -1), j.optBoolean("macCharging"), j.optBoolean("macAwake"), j.optString("mac", "Mac"))
        j.optString("mac", "Mac") to files
    }

    /** A command for the Mac from the island's Devices page: "lock", "awake-on" or "awake-off". */
    fun command(name: String): Boolean = PortalConnection(host, port, key).use { conn ->
        conn.sendFrame(header("cmd", name, 0))
        String(conn.recvFrame(), Charsets.UTF_8) == "OK"
    }

    /** Asks the Mac for its clipboard text. */
    fun getClip(): String = PortalConnection(host, port, key).use { conn ->
        conn.sendFrame(header("clipget", "", 0))
        String(conn.recvFrame(), Charsets.UTF_8)
    }

    fun sendText(text: String, auto: Boolean = false) = PortalConnection(host, port, key).use { conn ->
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size > 5_000_000) throw PortalException("Text is too long")
        conn.sendFrame(header("text", if (auto) "auto-clipboard" else "Clipboard", bytes.size.toLong()))
        var i = 0
        while (i < bytes.size) { val n = minOf(Portal.CHUNK, bytes.size - i); conn.sendFrame(bytes, i, n); i += n }
        expectOk(conn)
    }

    fun sendFile(uri: Uri, onRate: (String) -> Unit = {}, progress: (Float) -> Unit): String = TransferLocks.hold(ctx) {
        val (name, size) = describe(uri)
        PortalConnection(host, port, key).use { conn ->
            conn.sendFrame(header("file", name, size))
            // a second thread reads and encrypts the next pieces while this one sends — disk, crypto and Wi-Fi all work at once
            val queue = java.util.concurrent.ArrayBlockingQueue<Any>(6)
            val reader = kotlin.concurrent.thread(name = "portal-read") {
                try {
                    val c = Cipher.getInstance("AES/GCM/NoPadding"); val k = SecretKeySpec(key, "AES")
                    val buf = ByteArray(Portal.CHUNK)
                    (ctx.contentResolver.openInputStream(uri) ?: throw PortalException("Can't open $name")).use { ins ->
                        var read = 0L
                        while (read < size) {
                            val n = readFully(ins, buf, minOf(buf.size.toLong(), size - read).toInt())
                            if (n <= 0) break
                            queue.put(PortalConnection.seal(c, k, buf, 0, n)); read += n
                        }
                    }
                    queue.put(END)
                } catch (e: Throwable) { queue.put(e) }
            }
            val speed = Speedometer(onRate)
            var sent = 0L
            try {
                while (true) {
                    when (val item = queue.take()) {
                        is ByteArray -> { conn.writeSealed(item); sent += item.size - 32; progress(if (size > 0) sent.toFloat() / size else 1f); speed.tick(sent) }
                        is Throwable -> throw item
                        else -> break
                    }
                }
                conn.flush()
            } finally { reader.interrupt() }
            if (sent != size) throw PortalException("File changed while sending")
            expectOk(conn)
        }
        name
    }

    /** Downloads one item into Downloads/Rokaconnect and returns its content URI. */
    fun download(file: MacFile, onRate: (String) -> Unit = {}, progress: (Float) -> Unit): Uri = TransferLocks.hold(ctx) { PortalConnection(host, port, key).use { conn ->
        conn.sendFrame(header("get", file.id.toString(), 0))
        val meta = JSONObject(String(conn.recvFrame(), Charsets.UTF_8))
        if (meta.has("error")) throw PortalException("The Mac stopped offering this file")
        val name = meta.getString("name"); val size = meta.getLong("size")
        val resolver = ctx.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Rokaconnect")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw PortalException("Can't save to Downloads")
        try {
            (resolver.openOutputStream(uri) ?: throw PortalException("Can't save to Downloads")).use { out ->
                // a second thread decrypts and saves while the next pieces keep arriving
                val queue = java.util.concurrent.ArrayBlockingQueue<Any>(6)
                var failure: Throwable? = null
                val writer = kotlin.concurrent.thread(name = "portal-write") {
                    try {
                        val c = Cipher.getInstance("AES/GCM/NoPadding"); val k = SecretKeySpec(key, "AES")
                        while (true) { val item = queue.take(); if (item !is ByteArray) break; out.write(PortalConnection.open(c, k, item)) }
                    } catch (e: Throwable) { failure = e }
                }
                val speed = Speedometer(onRate)
                var got = 0L
                try {
                    while (got < size && failure == null) {
                        val body = conn.recvSealed()
                        got += body.size - 28
                        queue.put(body)
                        progress(if (size > 0) got.toFloat() / size else 1f); speed.tick(got)
                    }
                } finally { queue.put(END); writer.join() }
                failure?.let { throw it }
            }
            conn.sendFrame("OK".toByteArray())
            values.clear(); values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            uri
        } catch (e: Exception) {
            resolver.delete(uri, null, null); throw e
        }
    } }

    private fun describe(uri: Uri): Pair<String, Long> {
        var name = "file"; var size = -1L
        ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { c.getString(it)?.let { n -> name = n } }
                c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !c.isNull(it) }?.let { size = c.getLong(it) }
            }
        }
        if (size < 0) {   // provider didn't say: count it
            size = 0
            ctx.contentResolver.openInputStream(uri)?.use { val b = ByteArray(1 shl 16); while (true) { val n = it.read(b); if (n < 0) break; size += n } }
        }
        return name to size
    }

    private fun readFully(ins: InputStream, buf: ByteArray, want: Int): Int {
        var total = 0
        while (total < want) { val n = ins.read(buf, total, want - total); if (n < 0) break; total += n }
        return total
    }
}
