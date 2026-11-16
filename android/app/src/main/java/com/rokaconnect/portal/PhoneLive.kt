package com.rokaconnect.portal

import android.app.ActivityOptions
import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf

// ─────────────────────────────────────────────────────────────────────────────
// Live data the island shows: the music playing on the phone.
// Android calls the needed permission "Notification access", but it is only used for music here.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Android only lets an app see the phone's music if it has "Notification access", so this service
 * exists for that one reason. It never reads, keeps or sends your notifications.
 */
class NotifService : NotificationListenerService() {
    override fun onListenerConnected() { PhoneMedia.start(this) }
    override fun onNotificationPosted(sbn: StatusBarNotification) {}     // ignored on purpose
    override fun onNotificationRemoved(sbn: StatusBarNotification) {}    // ignored on purpose
}

/** What's playing on the phone (Spotify, YouTube Music, Samsung Music…). */
data class PhoneTrack(
    val title: String, val artist: String, val art: Bitmap?, val playing: Boolean,
    val position: Long, val duration: Long, val updatedAt: Long, val speed: Float, val app: String,
) {
    /** Current position, moving forward while playing. */
    fun now(): Long = if (!playing) position else (position + ((SystemClock.elapsedRealtime() - updatedAt) * speed).toLong()).coerceAtMost(maxOf(duration, position))
}

object PhoneMedia {
    val track = mutableStateOf<PhoneTrack?>(null)

    /** True when the user has allowed "Notification access" (Android's name for it) for Rokaconnect. */
    fun allowed(c: Context): Boolean {
        val flat = Settings.Secure.getString(c.contentResolver, "enabled_notification_listeners") ?: return false
        return flat.contains(ComponentName(c, NotifService::class.java).flattenToString())
    }
    private var controller: MediaController? = null
    private var manager: MediaSessionManager? = null
    private val main = Handler(Looper.getMainLooper())

    private val callback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = publish()
        override fun onPlaybackStateChanged(state: PlaybackState?) = publish()
        override fun onSessionDestroyed() { controller = null; pickActive() }
    }

    private val sessionsChanged = MediaSessionManager.OnActiveSessionsChangedListener { pickActive() }

    /** Starts watching music sessions (needs Notification access). */
    fun start(c: Context) {
        if (manager != null) return
        val m = c.getSystemService(MediaSessionManager::class.java)
        val comp = ComponentName(c, NotifService::class.java)
        runCatching {
            m.addOnActiveSessionsChangedListener(sessionsChanged, comp, main)
            manager = m
            ctx = c.applicationContext
            pickActive()
        }
    }

    private var ctx: Context? = null

    /** Prefers the session that is playing; otherwise the most recent one. */
    private fun pickActive() {
        val m = manager ?: return
        val c = ctx ?: return
        val list = runCatching { m.getActiveSessions(ComponentName(c, NotifService::class.java)) }.getOrDefault(emptyList())
        val best = list.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: list.firstOrNull()
        if (best?.sessionToken != controller?.sessionToken) {
            controller?.unregisterCallback(callback)
            controller = best
            best?.registerCallback(callback, main)
        }
        publish()
    }

    private fun publish() {
        val ctl = controller
        val md = ctl?.metadata
        if (ctl == null || md == null) { track.value = null; return }
        val st = ctl.playbackState
        val app = runCatching { ctx!!.packageManager.getApplicationLabel(ctx!!.packageManager.getApplicationInfo(ctl.packageName, 0)).toString() }.getOrDefault(ctl.packageName)
        track.value = PhoneTrack(
            title = md.getString(MediaMetadata.METADATA_KEY_TITLE) ?: md.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE) ?: "",
            artist = md.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: md.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: "",
            art = md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: md.getBitmap(MediaMetadata.METADATA_KEY_ART),
            playing = st?.state == PlaybackState.STATE_PLAYING,
            position = st?.position ?: 0, duration = md.getLong(MediaMetadata.METADATA_KEY_DURATION),
            updatedAt = st?.lastPositionUpdateTime ?: SystemClock.elapsedRealtime(), speed = st?.playbackSpeed ?: 1f, app = app,
        )
    }

    fun playPause() { val c = controller ?: return; if (c.playbackState?.state == PlaybackState.STATE_PLAYING) c.transportControls.pause() else c.transportControls.play() }
    fun next() { controller?.transportControls?.skipToNext() }
    fun previous() { controller?.transportControls?.skipToPrevious() }
    fun seek(ms: Long) { controller?.transportControls?.seekTo(ms) }
}

/** Draws any icon into a square bitmap. */
fun Drawable.toBitmap(size: Int): Bitmap {
    val b = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val cv = Canvas(b); setBounds(0, 0, size, size); draw(cv)
    return b
}
