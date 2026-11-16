package com.rokaconnect.portal

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class Transfer(val id: Long, val title: String, val incoming: Boolean, val progress: Float, val status: String, val uri: Uri? = null)

/** Transfers + fly-animation requests, shared by the screen and the background service. */
object TransferLog {
    val items = mutableStateListOf<Transfer>()
    /** Latest send/receive, so the screen can play the fly animation. */
    val fly = mutableStateOf<Fly?>(null)
    private val main = Handler(Looper.getMainLooper())

    fun start(title: String, incoming: Boolean, status: String): Long {
        val id = System.nanoTime()
        main.post {
            items.add(0, Transfer(id, title, incoming, 0f, status))
            if (items.size > 40) items.removeRange(40, items.size)
            IslandBus.update(IslandState(title, 0f, incoming, active = true))
        }
        return id
    }

    fun progress(id: Long, p: Float) = edit(id) { it.copy(progress = p) }
    /** Live speed on the row while moving, e.g. "12.4 MB/s · Sending…" (keeps the "…" so it still counts as running). */
    fun rate(id: Long, verb: String, rate: String) = edit(id) { if (it.status.endsWith("…")) it.copy(status = "$rate · $verb…") else it }
    fun done(id: Long, title: String? = null, status: String, uri: Uri? = null) = edit(id) { it.copy(title = title ?: it.title, progress = 1f, status = status, uri = uri ?: it.uri) }
    fun failed(id: Long, msg: String) = edit(id) { it.copy(status = msg, progress = 0f) }

    private fun edit(id: Long, f: (Transfer) -> Transfer) = main.post {
        val i = items.indexOfFirst { it.id == id }
        if (i < 0) return@post
        val t = f(items[i]); items[i] = t
        val finished = t.progress >= 1f && !t.status.endsWith("…")
        val failed = t.progress == 0f && !t.status.endsWith("…")
        when {
            finished -> IslandBus.update(IslandState(t.title, 1f, t.incoming, done = true))
            failed -> IslandBus.update(IslandState())
            else -> IslandBus.update(IslandState(t.title, t.progress, t.incoming, active = true))
        }
    }

    fun flyNow(uri: Uri?, incoming: Boolean) = main.post { fly.value = Fly(System.nanoTime(), uri, incoming) }
}

/** Pairing + where the Mac is, readable from anywhere (screen or service). */
object Link {
    private fun prefs(c: Context) = c.getSharedPreferences("portal", Context.MODE_PRIVATE)
    fun key(c: Context): ByteArray? = prefs(c).getString("key", null)?.let { Base64.decode(it, Base64.NO_WRAP) }
    fun paired(c: Context) = key(c) != null

    fun target(c: Context, found: List<MacFinder.Mac>): Pair<String, Int>? {
        val p = prefs(c)
        p.getString("host", "")?.trim()?.takeIf { it.isNotEmpty() }?.let { h ->
            val parts = h.split(":"); return parts[0] to (parts.getOrNull(1)?.toIntOrNull() ?: Portal.PORT)
        }
        found.firstOrNull()?.let { return it.host to it.port }
        p.getString("lastHost", "")?.takeIf { it.isNotEmpty() }?.let { return it to p.getInt("lastPort", Portal.PORT) }
        return p.getString("qrHost", "")?.takeIf { it.isNotEmpty() }?.let { it to p.getInt("qrPort", Portal.PORT) }
    }

    /** Where the Mac was last seen on the network (used when the app isn't open to search). */
    fun rememberHost(c: Context, host: String, port: Int) { prefs(c).edit().putString("lastHost", host).putInt("lastPort", port).apply() }

    fun client(c: Context, found: List<MacFinder.Mac>): PortalClient? {
        val k = key(c) ?: return null
        val (h, port) = target(c, found) ?: return null
        return PortalClient(c.applicationContext, h, port, k)
    }

    /** Receive files the Mac sends to this phone automatically, even with the app closed. */
    fun autoReceive(c: Context) = prefs(c).getBoolean("autoReceive", true)
    fun setAutoReceive(c: Context, on: Boolean) { prefs(c).edit().putBoolean("autoReceive", on).apply(); IslandBus.sync(c) }

    /** Keep the phone and Mac clipboards in sync automatically. */
    fun autoClip(c: Context) = prefs(c).getBoolean("autoClip", true)
    fun setAutoClip(c: Context, on: Boolean) { prefs(c).edit().putBoolean("autoClip", on).apply() }
}

/** Saves files the Mac sent straight to this phone ("direct" items), once each. */
object AutoReceiver {
    private val lock = Mutex()

    private fun seen(c: Context): MutableSet<String> =
        c.getSharedPreferences("portal", Context.MODE_PRIVATE).getStringSet("seen", emptySet())!!.toMutableSet()

    private fun markSeen(c: Context, key: String) {
        val p = c.getSharedPreferences("portal", Context.MODE_PRIVATE)
        val s = seen(c); s += key
        p.edit().putStringSet("seen", s.toList().takeLast(300).toSet()).apply()
    }

    /** Call with a fresh listing; downloads anything new that was sent directly to this phone. */
    suspend fun handle(c: Context, client: PortalClient, files: List<MacFile>) = lock.withLock {
        for (f in files.filter { it.direct }) {
            val k = "${f.id}:${f.name}:${f.size}"
            if (k in seen(c)) continue
            val id = TransferLog.start(f.name, incoming = true, status = "Receiving…")
            try {
                val uri = client.download(f, onRate = { r -> TransferLog.rate(id, "Receiving", r) }) { p -> TransferLog.progress(id, p) }
                markSeen(c, k)
                TransferLog.done(id, status = "Saved to Downloads/Rokaconnect", uri = uri)
                TransferLog.flyNow(uri, incoming = true)
            } catch (e: Exception) {
                TransferLog.failed(id, e.message ?: "Couldn't receive")
                if (e is PortalException && e.message?.contains("stopped offering") == true) markSeen(c, k)
            }
        }
    }
}

/** Starts the app with an action (used by the island's quick menu). */
fun openApp(c: Context, action: String? = null) {
    val i = Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
    if (action != null) i.action = action
    c.startActivity(i)
}

const val ACTION_PICK_FILES = "com.rokaconnect.portal.PICK_FILES"
const val ACTION_SEND_CLIPBOARD = "com.rokaconnect.portal.SEND_CLIPBOARD"
const val ACTION_PICK_PHOTOS = "com.rokaconnect.portal.PICK_PHOTOS"

