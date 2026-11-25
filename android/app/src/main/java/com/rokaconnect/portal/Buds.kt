package com.rokaconnect.portal

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.mutableStateOf
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Galaxy Buds on the phone: battery and noise control (Off · Noise cancelling · Ambient).
 * Talks to the buds over their Bluetooth serial channel — Samsung's unofficial protocol, the same one the
 * Mac app uses (frames: 0xFD | size(2, LE) | id | payload | CRC16-CCITT | 0xDD; tested on Buds2 Pro).
 * Needs Android's "Nearby devices" permission. Samsung's own Galaxy Wearable app may already hold the channel;
 * then [problem] says so and the controls stay hidden.
 */
@SuppressLint("MissingPermission")
object BudsLink {
    private val SPP: UUID = UUID.fromString("2e73a4ad-332d-41fc-90e2-16bef06523f2")
    private val main = Handler(Looper.getMainLooper())

    val name = mutableStateOf<String?>(null)          // connected buds (null = none / not reachable)
    val left = mutableStateOf<Int?>(null)
    val right = mutableStateOf<Int?>(null)
    val case = mutableStateOf<Int?>(null)
    val noise = mutableStateOf<Int?>(null)            // 0 off, 1 noise cancelling, 2 ambient
    /** Why the controls can't be shown: "permission" or "busy" (another app holds the buds' channel). */
    val problem = mutableStateOf<String?>(null)

    @Volatile private var socket: BluetoothSocket? = null
    @Volatile private var started = false

    fun hasPermission(ctx: Context) = Build.VERSION.SDK_INT < 31 ||
        ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    /** Starts watching for connected buds (every 10 s while none is linked). Safe to call many times. */
    fun start(ctx: Context) {
        if (started) return
        started = true
        val app = ctx.applicationContext
        thread(isDaemon = true, name = "buds") {
            while (true) {
                if (socket == null) runCatching { tryConnect(app) }
                Thread.sleep(10_000)
            }
        }
    }

    private fun tryConnect(ctx: Context) {
        if (!hasPermission(ctx)) { set { problem.value = "permission"; name.value = null }; return }
        val adapter = ctx.getSystemService(BluetoothManager::class.java)?.adapter ?: return
        if (!adapter.isEnabled) { set { name.value = null }; return }
        val dev = connectedBuds(ctx, adapter) ?: run { set { name.value = null; problem.value = null }; return }
        val s = runCatching { dev.createRfcommSocketToServiceRecord(SPP).also { it.connect() } }
            .onFailure { android.util.Log.d("RokaBuds", "connect to ${dev.name} failed: $it") }.getOrNull()
        if (s == null) { set { name.value = dev.name; problem.value = "busy" }; return }
        android.util.Log.d("RokaBuds", "connected to ${dev.name}")
        socket = s
        set { name.value = dev.name; problem.value = null }
        readLoop(s)
    }

    /** The connected Buds that offer Samsung's control channel (looks at classic audio, calls and LE Audio). */
    private fun connectedBuds(ctx: Context, adapter: BluetoothAdapter): BluetoothDevice? {
        val profiles = buildList { add(BluetoothProfile.A2DP); add(BluetoothProfile.HEADSET); if (Build.VERSION.SDK_INT >= 33) add(22 /* LE_AUDIO */) }
        val found = mutableSetOf<BluetoothDevice>()
        for (profile in profiles) {
            val latch = CountDownLatch(1)
            val ok = adapter.getProfileProxy(ctx, object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(p: Int, proxy: BluetoothProfile) {
                    runCatching { found += proxy.connectedDevices }
                    adapter.closeProfileProxy(p, proxy); latch.countDown()
                }
                override fun onServiceDisconnected(p: Int) {}
            }, profile)
            if (ok) latch.await(2, TimeUnit.SECONDS)
        }
        // fall back to paired Buds that offer the channel (connecting simply fails if they're not in range)
        if (found.isEmpty()) runCatching { found += adapter.bondedDevices.filter { d -> d.uuids?.any { it.uuid == SPP } == true } }
        android.util.Log.d("RokaBuds", "candidates: ${found.map { it.name }}")
        return found.firstOrNull { d -> d.uuids?.any { it.uuid == SPP } == true || (d.name ?: "").contains("Buds", ignoreCase = true) }
    }

    private fun readLoop(s: BluetoothSocket) {
        val ins = runCatching { s.inputStream }.getOrNull() ?: return close()
        val buf = ByteArray(2048); var acc = ByteArray(0)
        try {
            while (true) {
                val n = ins.read(buf); if (n < 0) break
                acc += buf.copyOf(n)
                while (true) {
                    val st = acc.indexOf(0xFD.toByte()); if (st < 0) { acc = ByteArray(0); break }
                    if (acc.size - st < 4) break
                    val size = ((acc[st + 1].toInt() and 0xFF) or ((acc[st + 2].toInt() and 0xFF) shl 8)) and 0x3FF
                    val end = st + 3 + size
                    if (end >= acc.size) break
                    val body = acc.copyOfRange(st + 3, end)           // id + payload + crc
                    acc = acc.copyOfRange(end + 1, acc.size)
                    if (body.size >= 3 && crc16(body.copyOf(body.size - 2)) == ((body[body.size - 2].toInt() and 0xFF) or ((body[body.size - 1].toInt() and 0xFF) shl 8))) {
                        handle(body[0].toInt() and 0xFF, body.copyOfRange(1, body.size - 2))
                    }
                }
            }
        } catch (_: Exception) { }
        close()
    }

    private fun handle(id: Int, p: ByteArray) {
        fun pct(i: Int) = p.getOrNull(i)?.toInt()?.and(0xFF)?.takeIf { it in 1..100 }
        when (id) {
            0x61 -> { android.util.Log.d("RokaBuds", "status L=${pct(2)} R=${pct(3)} case=${pct(7)}"); set { left.value = pct(2); right.value = pct(3); case.value = pct(7) } }      // extended status
            0x60 -> set { left.value = pct(1) ?: left.value; right.value = pct(2) ?: right.value; case.value = pct(6) ?: case.value }  // status update
            0x77 -> p.getOrNull(0)?.toInt()?.takeIf { it in 0..2 }?.let { m -> set { noise.value = m } }   // changed on the buds
        }
    }

    /** 0 = off, 1 = noise cancelling, 2 = ambient (message 0x78, as on the Mac). */
    fun setNoise(mode: Int) {
        val s = socket ?: return
        thread { runCatching { s.outputStream.write(frame(0x78, byteArrayOf(mode.toByte()))) }.onFailure { close() } }
        set { noise.value = mode }
    }

    private fun frame(id: Int, payload: ByteArray): ByteArray {
        val body = byteArrayOf(id.toByte()) + payload
        val c = crc16(body)
        return byteArrayOf(0xFD.toByte(), (body.size + 2).toByte(), 0) + body + byteArrayOf((c and 0xFF).toByte(), (c shr 8).toByte(), 0xDD.toByte())
    }

    private fun crc16(d: ByteArray): Int {
        var c = 0
        for (b in d) { c = c xor ((b.toInt() and 0xFF) shl 8); repeat(8) { c = if (c and 0x8000 != 0) (c shl 1) xor 0x1021 else c shl 1 }; c = c and 0xFFFF }
        return c
    }

    private fun close() {
        runCatching { socket?.close() }; socket = null
        set { name.value = null; left.value = null; right.value = null; case.value = null; noise.value = null }
    }

    private fun set(f: () -> Unit) = main.post(f)
}
