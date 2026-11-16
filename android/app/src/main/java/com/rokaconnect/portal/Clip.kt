package com.rokaconnect.portal

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import kotlin.concurrent.thread

// ─────────────────────────────────────────────────────────────────────────────
// Clipboard both ways between the phone and the Mac.
//   phone → Mac : tap Copy anywhere → the accessibility service reads it during a brief focus → Mac
//   Mac → phone : copy on the Mac → arrives on the phone's next check-in (a few seconds)
// ─────────────────────────────────────────────────────────────────────────────

object ClipSync {
    private val main = Handler(Looper.getMainLooper())
    /** Last text that came FROM the Mac / was sent TO the Mac — never sent again (no ping-pong). */
    @Volatile private var lastFromMac: String? = null
    @Volatile private var lastSent: String? = null

    /** Automatic phone → Mac (after you tap Copy): quiet, skips repeats and text that came from the Mac. */
    fun autoSend(ctx: Context, text: String) {
        if (!Link.autoClip(ctx) || text.isEmpty() || text == lastFromMac || text == lastSent) return
        val c = Link.client(ctx, emptyList()) ?: return
        lastSent = text
        thread { runCatching { c.sendText(text, auto = true) }.onFailure { lastSent = null } }
    }

    /** Sends text to the Mac's clipboard (runs in the background; the island shows progress). */
    fun sendToMac(ctx: Context, text: String) {
        val c = Link.client(ctx, emptyList()) ?: run { toast(ctx, "Mac not found — open Rokaconnect once on the same Wi-Fi"); return }
        val id = TransferLog.start(text.take(60), incoming = false, status = "Sending…")
        thread {
            try { c.sendText(text); TransferLog.done(id, status = "Copied on Mac") }
            catch (e: Exception) { TransferLog.failed(id, e.message ?: "Couldn't reach the Mac") }
        }
    }

    /** Asks the Mac for its clipboard and puts it on the phone's clipboard. */
    fun fetchFromMac(ctx: Context) {
        val c = Link.client(ctx, emptyList()) ?: run { android.util.Log.d("RokaClip", "fetch: no Mac address"); toast(ctx, "Mac not found — open Rokaconnect once on the same Wi-Fi"); return }
        android.util.Log.d("RokaClip", "fetch: asking Mac")
        val id = TransferLog.start("Mac clipboard", incoming = true, status = "Getting…")
        thread {
            try {
                val text = c.getClip()
                if (text.isEmpty()) { TransferLog.failed(id, "Mac clipboard is empty"); toast(ctx, "Mac clipboard is empty"); return@thread }
                applyFromMac(ctx, text)
                TransferLog.done(id, title = text.take(60), status = "Copied from Mac")
            } catch (e: Exception) { android.util.Log.d("RokaClip", "fetch failed: $e"); TransferLog.failed(id, e.message ?: "Couldn't reach the Mac") }
        }
    }

    /** Puts text from the Mac on the phone's clipboard (apps may write it any time; only reading is limited). */
    fun applyFromMac(ctx: Context, text: String, quiet: Boolean = false) = main.post {
        lastFromMac = text
        ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("From Mac", text))
        if (!quiet) IslandBus.update(IslandState("Clipboard from Mac", 1f, incoming = true, done = true))
    }

    private fun toast(ctx: Context, msg: String) = main.post { Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show() }
}

