package com.rokaconnect.portal

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator

/**
 * "Ring phone" from the Mac island: plays the ringtone loudly (on the alarm channel, so it rings even in
 * silent mode) and vibrates, for up to 30 seconds. Stops when you open Rokaconnect or tap the island.
 */
object PhoneRinger {
    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var savedVolume = -1
    @Volatile var ringing = false
        private set

    fun start(ctx: Context) = main.post {
        if (ringing) return@post
        val app = ctx.applicationContext
        val am = app.getSystemService(AudioManager::class.java)
        savedVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
        am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        val uri = RingtoneManager.getActualDefaultRingtoneUri(app, RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
        player = runCatching {
            MediaPlayer().apply {
                setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                setDataSource(app, uri); isLooping = true; prepare(); start()
            }
        }.getOrNull()
        vibrator = app.getSystemService(Vibrator::class.java)?.also {
            it.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 600, 400), 0))
        }
        ringing = true
        IslandBus.update(IslandState("Ringing — tap to stop", 1f, incoming = true, active = true))
        main.postDelayed({ stop(app) }, 30_000)          // never rings forever
    }

    fun stop(ctx: Context) = main.post {
        if (!ringing) return@post
        ringing = false
        runCatching { player?.stop(); player?.release() }; player = null
        vibrator?.cancel(); vibrator = null
        if (savedVolume >= 0) runCatching {
            ctx.applicationContext.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0)
        }
        savedVolume = -1
        IslandBus.update(IslandState())
    }
}
