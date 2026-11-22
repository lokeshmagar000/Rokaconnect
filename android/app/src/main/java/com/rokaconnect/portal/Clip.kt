package com.rokaconnect.portal

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
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

    /** Puts text from the Mac on the phone's clipboard (apps may write it any time; only reading is limited). */
    fun applyFromMac(ctx: Context, text: String, quiet: Boolean = false) = main.post {
        lastFromMac = text
        ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("From Mac", text))
        if (!quiet) IslandBus.update(IslandState("Clipboard from Mac", 1f, incoming = true, done = true))
    }
}

