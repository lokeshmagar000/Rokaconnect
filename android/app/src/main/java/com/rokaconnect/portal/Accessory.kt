package com.rokaconnect.portal

import android.app.Activity
import android.content.Context
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import androidx.compose.runtime.mutableStateOf
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

// ─────────────────────────────────────────────────────────────────────────────
// USB cable mode WITHOUT USB debugging — Android Open Accessory (AOA).
// The Mac switches the phone to "accessory mode"; Android asks once "Open Rokaconnect for this USB accessory?".
// Then this opens the accessory and listens on 127.0.0.1:52341 here on the phone. Every connection the app makes
// to that address is carried over the USB cable to the Mac's Portal (many at once, multiplexed), so the rest of
// the app works exactly like the adb cable mode — same encrypted protocol, nothing else to change.
//
// Wire format (both directions): [stream id: Int32][type: Byte][length: Int32][payload]
//   type 1 = open · 2 = data · 3 = close · 4 = padding (ignored) · 5 = hello — must match AOALink.swift on the Mac.
// ─────────────────────────────────────────────────────────────────────────────

object AoaLink {
    private const val OPEN: Byte = 1
    private const val DATA: Byte = 2
    private const val CLOSE: Byte = 3
    private const val PAD: Byte = 4
    private const val HELLO: Byte = 5          // "the phone app has opened the accessory" (sent once at start)
    private const val HEADER = 9

    @Volatile var active = false
        private set
    /** For the screen: true while the cable link (accessory mode) is up. */
    val state = mutableStateOf(false)

    private val main = Handler(Looper.getMainLooper())
    private var pfd: ParcelFileDescriptor? = null
    private var input: InputStream? = null
    private var output: OutputStream? = null
    private var server: ServerSocket? = null
    private val streams = ConcurrentHashMap<Int, Socket>()
    private val nextId = AtomicInteger(1)
    private val writeLock = Any()

    /** The accessory is plugged in and allowed: open it and start carrying connections. */
    @Synchronized fun start(ctx: Context, accessory: UsbAccessory) {
        if (active) return
        val um = ctx.getSystemService(UsbManager::class.java) ?: return
        if (!um.hasPermission(accessory)) return
        val fd = runCatching { um.openAccessory(accessory) }.getOrNull() ?: return
        pfd = fd
        input = FileInputStream(fd.fileDescriptor)
        output = FileOutputStream(fd.fileDescriptor)
        active = true
        main.post { state.value = true }
        thread(isDaemon = true, name = "aoa-usb-read") { readLoop() }
        send(0, HELLO, null, 0, 0)
        // local door for the app: 127.0.0.1:52341. While adb's cable link holds it (USB debugging on — that path
        // is faster), keep trying: this link takes over by itself as soon as adb's link goes away.
        thread(isDaemon = true, name = "aoa-accept") {
            while (active && server == null) {
                server = runCatching {
                    ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), Portal.PORT)) }
                }.getOrNull()
                if (server == null) Thread.sleep(1_000)
            }
            server?.let { acceptLoop(it) }
        }
    }

    /**
     * When the app starts with the cable already in accessory mode: open it, or — if Android hasn't allowed it
     * yet — ask ("Allow Rokaconnect to access this USB accessory?"), then open it once you tap OK.
     */
    fun startIfAttached(ctx: Context) {
        val um = ctx.getSystemService(UsbManager::class.java) ?: return
        val acc = um.accessoryList?.firstOrNull { it.manufacturer == "Rokaconnect" } ?: return
        if (um.hasPermission(acc)) { start(ctx.applicationContext, acc); return }
        val app = ctx.applicationContext
        val action = "com.rokaconnect.portal.USB_PERMISSION"
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: Context, i: android.content.Intent) {
                runCatching { app.unregisterReceiver(this) }
                if (i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) start(app, acc)
            }
        }
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, android.content.IntentFilter(action), Context.RECEIVER_NOT_EXPORTED)
        else @Suppress("UnspecifiedRegisterReceiverFlag") app.registerReceiver(receiver, android.content.IntentFilter(action))
        val pi = android.app.PendingIntent.getBroadcast(app, 0, android.content.Intent(action).setPackage(app.packageName),
            android.app.PendingIntent.FLAG_MUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT)
        um.requestPermission(acc, pi)
    }

    @Synchronized fun stop() {
        if (!active) return
        active = false
        main.post { state.value = false }
        runCatching { server?.close() }; server = null
        streams.values.forEach { runCatching { it.close() } }; streams.clear()
        runCatching { input?.close() }; runCatching { output?.close() }; runCatching { pfd?.close() }
        input = null; output = null; pfd = null
    }

    // app connection → new stream over USB
    private fun acceptLoop(s: ServerSocket) {
        while (active) {
            val sock = runCatching { s.accept() }.getOrNull() ?: break
            val id = nextId.getAndIncrement()
            sock.tcpNoDelay = true
            streams[id] = sock
            send(id, OPEN, null, 0, 0)
            thread(isDaemon = true, name = "aoa-sock-$id") {
                val buf = ByteArray(128 * 1024)
                runCatching {
                    val ins = sock.getInputStream()
                    while (true) { val n = ins.read(buf); if (n <= 0) break; send(id, DATA, buf, 0, n) }
                }
                send(id, CLOSE, null, 0, 0)
            }
        }
    }

    // USB → the matching app connection
    private fun readLoop() {
        val ins = input ?: return
        val buf = ByteArray(64 * 1024)               // accessory reads must be at least 16 KB
        var acc = ByteArray(512 * 1024); var have = 0
        try {
            while (active) {
                val n = ins.read(buf)
                if (n < 0) break
                if (n == 0) continue
                if (have + n > acc.size) acc = acc.copyOf(maxOf(acc.size * 2, have + n))
                System.arraycopy(buf, 0, acc, have, n); have += n
                var off = 0
                while (have - off >= HEADER) {
                    val id = readInt(acc, off); val type = acc[off + 4]; val len = readInt(acc, off + 5)
                    if (have - off - HEADER < len) break
                    when (type) {
                        DATA -> streams[id]?.let { s -> runCatching { s.getOutputStream().write(acc, off + HEADER, len) }.onFailure { streams.remove(id); runCatching { s.close() } } }
                        CLOSE -> streams.remove(id)?.let { s -> runCatching { s.shutdownOutput() }; runCatching { s.close() } }
                    }
                    off += HEADER + len
                }
                if (off > 0) { System.arraycopy(acc, off, acc, 0, have - off); have -= off }
            }
        } catch (_: Exception) { }
        stop()                                         // cable unplugged / accessory closed
    }

    /** Writes one frame; adds a padding frame when the size is an exact multiple of the USB packet size. */
    private fun send(id: Int, type: Byte, data: ByteArray?, off: Int, len: Int) {
        val out = output ?: return
        val total = HEADER + len
        val pad = total % 512 == 0
        val frame = ByteArray(total + if (pad) HEADER else 0)
        writeInt(frame, 0, id); frame[4] = type; writeInt(frame, 5, len)
        if (data != null && len > 0) System.arraycopy(data, off, frame, HEADER, len)
        if (pad) { writeInt(frame, total, 0); frame[total + 4] = PAD; writeInt(frame, total + 5, 0) }
        synchronized(writeLock) { runCatching { out.write(frame) }.onFailure { stop() } }
    }

    private fun readInt(b: ByteArray, o: Int) =
        ((b[o].toInt() and 0xFF) shl 24) or ((b[o + 1].toInt() and 0xFF) shl 16) or ((b[o + 2].toInt() and 0xFF) shl 8) or (b[o + 3].toInt() and 0xFF)
    private fun writeInt(b: ByteArray, o: Int, v: Int) {
        b[o] = (v ushr 24).toByte(); b[o + 1] = (v ushr 16).toByte(); b[o + 2] = (v ushr 8).toByte(); b[o + 3] = v.toByte()
    }
}

/**
 * Android opens this when the Mac turns the phone into a Rokaconnect accessory ("Open Rokaconnect for this
 * USB accessory?"). It starts the cable link and closes itself straight away — nothing is shown.
 */
class UsbAccessoryActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val acc: UsbAccessory? = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        if (acc != null) AoaLink.start(applicationContext, acc) else AoaLink.startIfAttached(this)
        UsbLink.start(applicationContext)
        finish()
    }
}
