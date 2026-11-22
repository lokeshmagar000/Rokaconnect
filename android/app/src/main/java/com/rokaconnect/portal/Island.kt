package com.rokaconnect.portal

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.text.TextPaint
import android.text.TextUtils
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.animation.OvershootInterpolator
import android.view.animation.PathInterpolator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.cancelChildren
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.dp

/** What the island shows. Updated from the app or the service, drawn by the overlay. */
data class IslandState(val title: String = "", val progress: Float = 0f, val incoming: Boolean = false, val active: Boolean = false, val done: Boolean = false)

enum class IslandPosition(val label: String) { CAMERA("Camera"), LEFT("Left"), RIGHT("Right"), BOTTOM("Bottom") }

/** Island settings + live state shared between the app and the overlay. */
object IslandBus {
    private val main = Handler(Looper.getMainLooper())
    private val listeners = mutableListOf<() -> Unit>()
    var state = IslandState(); private set
    private var clear: Runnable? = null

    fun listen(l: () -> Unit) { listeners += l }
    fun unlisten(l: () -> Unit) { listeners -= l }
    fun notifyChanged() = main.post { listeners.toList().forEach { it() } }

    fun update(s: IslandState) {
        clear?.let(main::removeCallbacks); clear = null
        state = s; notifyChanged()
        if (s.done) { clear = Runnable { state = IslandState(); notifyChanged() }.also { main.postDelayed(it, 2400) } }
    }

    // settings
    private fun prefs(c: Context) = c.getSharedPreferences("island", Context.MODE_PRIVATE)
    fun enabled(c: Context) = prefs(c).getBoolean("on", false)
    fun position(c: Context) = runCatching { IslandPosition.valueOf(prefs(c).getString("pos", "CAMERA")!!) }.getOrDefault(IslandPosition.CAMERA)
    // the island fits the camera by itself; these optional fine-tune values are added on top
    fun nudge(c: Context) = prefs(c).getFloat("nudge2", 0f)          // dp, negative = left
    fun lift(c: Context) = prefs(c).getFloat("lift2", 0f)            // dp, positive = down
    fun scale(c: Context) = prefs(c).getFloat("scale2", 1f)          // 0.8 … 1.4
    fun showIdle(c: Context) = prefs(c).getBoolean("idle", true)
    fun set(c: Context, on: Boolean? = null, pos: IslandPosition? = null, nudge: Float? = null, lift: Float? = null, scale: Float? = null, idle: Boolean? = null) {
        prefs(c).edit().apply {
            on?.let { putBoolean("on", it) }; pos?.let { putString("pos", it.name) }
            nudge?.let { putFloat("nudge2", it) }; lift?.let { putFloat("lift2", it) }
            scale?.let { putFloat("scale2", it) }; idle?.let { putBoolean("idle", it) }
        }.apply()
        notifyChanged()
    }

    fun canDraw(c: Context) = Settings.canDrawOverlays(c) || IslandAccessibility.running

    /** The service runs while the island is on or the phone should receive in the background. */
    fun sync(c: Context) {
        val i = Intent(c, IslandService::class.java)
        val need = (enabled(c) && canDraw(c)) || (Link.autoReceive(c) && Link.paired(c))
        if (need) runCatching { c.startForegroundService(i) } else c.stopService(i)
    }

    /** Where the island sits, as a fraction of the screen — the in-app fly animation aims at the camera. */
    @Suppress("UNUSED_PARAMETER")
    fun target(c: Context): Pair<Float, Float> = 0.5f to 0.02f
}

/** Lets Compose run inside a plain overlay window (normally an Activity provides these). */
class OverlayOwner : androidx.lifecycle.LifecycleOwner, androidx.savedstate.SavedStateRegistryOwner, androidx.lifecycle.ViewModelStoreOwner {
    private val registry = androidx.lifecycle.LifecycleRegistry(this)
    private val saved = androidx.savedstate.SavedStateRegistryController.create(this)
    override val lifecycle: androidx.lifecycle.Lifecycle get() = registry
    override val savedStateRegistry: androidx.savedstate.SavedStateRegistry get() = saved.savedStateRegistry
    override val viewModelStore = androidx.lifecycle.ViewModelStore()
    fun start() { saved.performRestore(null); registry.currentState = androidx.lifecycle.Lifecycle.State.RESUMED }
    fun stop() { registry.currentState = androidx.lifecycle.Lifecycle.State.DESTROYED; viewModelStore.clear() }
}

/**
 * Owns the island's two windows:
 *  • DRAW window — big enough for the open card, never moves or resizes (so nothing jitters),
 *    and lets every touch fall through to the app underneath.
 *  • TOUCH window — invisible, exactly the size of the pill/card you see; it passes your finger
 *    to the island, and tells us when you tap anywhere else (→ close).
 * Runs as an app overlay, or above the status bar when the accessibility service is on.
 */
class IslandHost(private val ctx: Context, private val type: Int) {
    private val wm = ctx.getSystemService(WindowManager::class.java)
    private val aboveStatusBar = type == WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY
    private val model = IslandModel().apply {
        onOpen = { action -> openApp(ctx, action) }
    }
    private var drawView: androidx.compose.ui.platform.ComposeView? = null
    private var touchView: View? = null
    private var owner: OverlayOwner? = null
    private val scope = kotlinx.coroutines.MainScope()
    private var winX = 0; private var winY = 0          // draw window position on screen (px)
    private val d get() = ctx.resources.displayMetrics.density
    private fun dp(v: Float) = v * d

    /** Where this phone's camera hole is (any phone: centre, corner, waterdrop…). null = no notch. */
    private fun cutout(): Rect? {
        if (Build.VERSION.SDK_INT < 30) return null
        val c = wm.currentWindowMetrics.windowInsets.displayCutout ?: return null
        return c.boundingRects.filter { it.top < dp(80f) }.minByOrNull { it.top }
    }

    private fun statusBarHeight(): Int {
        if (Build.VERSION.SDK_INT >= 30) {
            val t = wm.currentWindowMetrics.windowInsets.getInsets(android.view.WindowInsets.Type.statusBars()).top
            if (t > 0) return t
        }
        val id = ctx.resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) ctx.resources.getDimensionPixelSize(id) else dp(32f).toInt()
    }

    private fun screenWidth(): Int = if (Build.VERSION.SDK_INT >= 30) wm.currentWindowMetrics.bounds.width() else ctx.resources.displayMetrics.widthPixels

    /** Fits the island to THIS phone's camera automatically, then sizes the draw window once. */
    private fun measure() {
        val sw = screenWidth()
        val k = IslandBus.scale(ctx)
        val hole = cutout()
        val sb = statusBarHeight().toFloat()
        // Find the round camera hole itself. Many phones (Samsung too) report the camera area from the
        // very top edge down to the bottom of the hole, so when the area is taller than it is wide the
        // hole is the circle at the BOTTOM of it.
        val holeD = hole?.let { minOf(it.width(), it.height()).toFloat() } ?: 0f
        val cx = (hole?.exactCenterX() ?: (sw / 2f)) + dp(IslandBus.nudge(ctx))
        val holeCy = when {
            hole == null -> sb / 2f
            // Samsung & others: a box from the top edge down to the bottom of the status bar, camera on
            // the status bar's centre line (level with the clock)
            hole.top <= 0 && kotlin.math.abs(hole.height() - sb) <= sb * 0.2f -> sb / 2f
            // a tall box from the top edge: the round hole is at its bottom
            hole.height() > hole.width() * 1.2f -> hole.bottom - hole.width() / 2f
            else -> hole.exactCenterY()
        }
        // pill: the hole plus an even gap above and below it, centred exactly on the hole
        val gap = (minOf(dp(8f), holeCy - holeD / 2 - dp(2f))).coerceAtLeast(dp(3f))
        val ih = minOf(((holeD + 2 * gap).coerceIn(dp(24f), dp(36f)) * k), 2 * holeCy)
        val iw = (if (hole != null) holeD + dp(56f) else dp(96f)).coerceIn(dp(84f), dp(124f)) * k
        val top = holeCy - ih / 2 + dp(IslandBus.lift(ctx))
        // text starts just under the pill (above the status bar), or under the status bar icons
        // (plain overlay — Android draws those on top). Some phones report a camera area much taller
        // than the real hole, so the pill's own height is the safer guide.
        val clearLine = if (aboveStatusBar) top + ih * 0.9f else sb
        val textTop = maxOf(0f, clearLine - top)
        val m = dp(8f)
        val expW = minOf(dp(340f) * k, sw - dp(16f))
        val winW = minOf(sw.toFloat(), expW + 2 * m)
        val maxH = textTop + dp(158f) * k
        winX = (cx - winW / 2).coerceIn(0f, sw - winW).toInt()
        winY = maxOf(0f, top - m).toInt()
        val pillTop = top - winY                      // where the pill starts inside the window (no extra push)
        model.geo = IslandGeo(
            pillCx = ((cx - winX) / d).dp, pillTop = (pillTop / d).dp, margin = (m / d).dp, winW = (winW / d).dp,
            idleW = (iw / d).dp, idleH = (ih / d).dp,
            holeW = if (hole != null && IslandBus.nudge(ctx) == 0f) ((hole.width() + dp(8f)) / d).dp else 0.dp,
            expW = (expW / d).dp, textTop = (textTop / d).dp, k = k, showIdle = IslandBus.showIdle(ctx),
        )
        drawView?.let { v ->
            val p = v.layoutParams as WindowManager.LayoutParams
            p.x = winX; p.y = winY; p.width = winW.toInt(); p.height = (pillTop + maxH + m).toInt()
            runCatching { wm.updateViewLayout(v, p) }
        }
    }

    private fun overlayParams(touchable: Boolean) = WindowManager.LayoutParams(1, 1, type,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
            (if (touchable) WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH else WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE),
        PixelFormat.TRANSLUCENT).apply {
        gravity = Gravity.TOP or Gravity.START
        layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
    }

    @android.annotation.SuppressLint("ClickableViewAccessibility")
    private fun addViews() {
        val o = OverlayOwner().also { it.start() }
        owner = o
        val draw = androidx.compose.ui.platform.ComposeView(ctx).apply {
            setViewTreeLifecycleOwner(o)
            setViewTreeSavedStateRegistryOwner(o)
            setViewTreeViewModelStoreOwner(o)
            setContent { IslandRoot() }
        }
        drawView = draw
        wm.addView(draw, overlayParams(touchable = false))
        // invisible touch layer: hands your finger to the island; a tap anywhere else closes it
        val touch = View(ctx)
        touch.setOnTouchListener { _, e ->
            val lp = touch.layoutParams as WindowManager.LayoutParams
            // while open, this layer covers the whole screen: a tap outside the card closes the island
            if (model.expanded && e.actionMasked == android.view.MotionEvent.ACTION_DOWN && !cardRect().contains(e.rawX, e.rawY)) {
                model.expanded = false; outsideTap = true
                return@setOnTouchListener true
            }
            if (outsideTap) { if (e.actionMasked == android.view.MotionEvent.ACTION_UP || e.actionMasked == android.view.MotionEvent.ACTION_CANCEL) outsideTap = false; return@setOnTouchListener true }
            val ev = android.view.MotionEvent.obtain(e)
            ev.offsetLocation((lp.x - winX).toFloat(), (lp.y - winY).toFloat())
            draw.dispatchTouchEvent(ev)
            ev.recycle()
            true
        }
        touchView = touch
        wm.addView(touch, overlayParams(touchable = true))
        // keep the touch area matched to what you see
        scope.launch {
            androidx.compose.runtime.snapshotFlow { targetSize(model) to model.geo }.collect { fitTouch() }
        }
    }

    private var outsideTap = false

    /** Where the pill / popup / card is on screen right now (target size), in pixels. */
    private fun cardRect(): android.graphics.RectF {
        val g = model.geo
        val (w, h) = targetSize(model)
        val split = shapeOf(model) == IslandShapeKind.COMPACT && hasSplit(liveList(model))
        val left = winX + leftFor(g, w).value * d
        val top = winY + g.pillTop.value * d
        return android.graphics.RectF(left, top, left + (w + if (split) g.idleH + 6.dp * g.k else 0.dp).value * d, top + h.value * d)
    }

    /** Moves the invisible touch window onto the pill / popup — or over the whole screen while open. */
    private fun fitTouch() {
        val t = touchView ?: return
        val g = model.geo
        val p = t.layoutParams as WindowManager.LayoutParams
        if (model.expanded) {
            p.x = 0; p.y = 0; p.width = WindowManager.LayoutParams.MATCH_PARENT; p.height = WindowManager.LayoutParams.MATCH_PARENT
        } else {
            val r = cardRect()
            p.x = r.left.toInt(); p.y = r.top.toInt(); p.width = r.width().toInt(); p.height = r.height().toInt()
        }
        // nothing to touch when the idle pill is hidden
        val hidden = shapeOf(model) == IslandShapeKind.COMPACT && liveList(model).isEmpty() && !g.showIdle
        p.flags = if (hidden) p.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else p.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        runCatching { wm.updateViewLayout(t, p) }
    }

    @androidx.compose.runtime.Composable
    private fun IslandRoot() {
        val rm = androidx.compose.runtime.remember { Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
        androidx.compose.runtime.CompositionLocalProvider(LocalReduceMotion provides rm) { IslandUi(model, ctx) }
    }

    fun remove() {
        scope.coroutineContext[kotlinx.coroutines.Job]?.cancelChildren()
        drawView?.let { runCatching { wm.removeView(it) } }; drawView = null
        touchView?.let { runCatching { wm.removeView(it) } }; touchView = null
        owner?.stop(); owner = null
    }

    private val portrait get() = ctx.resources.configuration.orientation != android.content.res.Configuration.ORIENTATION_LANDSCAPE

    fun refresh(wantViewSetting: Boolean) {
        val wantView = wantViewSetting && portrait
        if (wantView && drawView == null) addViews()
        if (!wantView && drawView != null) remove()
        if (drawView == null) return
        val before = model.transfer
        val now = IslandBus.state
        if ((now.active && !before.active) || (now.done && !before.done)) model.bump++
        model.transfer = now
        measure()
        fitTouch()
    }
}

class IslandService : Service() {
    private var host: IslandHost? = null
    private val listener: () -> Unit = { refresh() }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var finder: MacFinder

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        UsbLink.start()     // background check-ins use the USB cable when it is plugged in
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("island", "Connection", NotificationManager.IMPORTANCE_MIN))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, "island").setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Rokaconnect").setContentText("Ready to receive from your Mac").setContentIntent(open).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, n)
        host = IslandHost(this, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY)
        finder = MacFinder(this).also { it.start() }
        IslandBus.listen(listener)
        refresh()
        // background receiver: check in with the Mac and save anything it sent to this phone
        scope.launch {
            while (isActive) {
                var wait = 3_000L
                if (Link.autoReceive(this@IslandService)) {
                    val c = Link.client(this@IslandService, finder.macs.toList())
                    if (c != null) try { val (_, files) = c.list(); AutoReceiver.handle(this@IslandService, c, files) } catch (_: Exception) { wait = 6_000L }
                    else wait = 5_000L
                }
                delay(wait)
            }
        }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig); refresh()     // rotation: hide in landscape, re-place in portrait
    }

    override fun onDestroy() {
        scope.cancel()
        finder.stop()
        IslandBus.unlisten(listener)
        host?.remove()
        super.onDestroy()
    }

    private fun refresh() {
        val wantIsland = IslandBus.enabled(this) && IslandBus.canDraw(this)
        if (!wantIsland && !(Link.autoReceive(this) && Link.paired(this))) { stopSelf(); return }
        // the accessibility service draws the island instead when it's on
        host?.refresh(wantIsland && !IslandAccessibility.running)
    }
}

/**
 * Optional: lets the island draw above the status bar and respond to taps. It only draws the island —
 * it doesn't read the screen or other apps (no event types are requested).
 */
class IslandAccessibility : android.accessibilityservice.AccessibilityService() {
    companion object { @Volatile var running = false }
    private var host: IslandHost? = null
    private val listener: () -> Unit = { host?.refresh(IslandBus.enabled(this)) }

    override fun onServiceConnected() {
        running = true
        host = IslandHost(this, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
        IslandBus.listen(listener)
        IslandBus.notifyChanged()
    }

    /**
     * Automatic clipboard: when you tap "Copy" (or an app shows "Copied"), take focus for a split second
     * — Android only lets the focused app read the clipboard — read it, send it to the Mac, let go.
     * Only the event's short label is checked; screen content is never read.
     */
    override fun onAccessibilityEvent(event: android.view.accessibility.AccessibilityEvent?) {
        event ?: return
        if (!Link.autoClip(this) || event.packageName == packageName) return
        val words = (event.text.joinToString(" ") + " " + (event.contentDescription ?: "")).trim().lowercase()
        if (words.isEmpty() || words.length > 160) return      // short labels only (buttons, toasts)
        val copy = runCatching { android.content.res.Resources.getSystem().getString(android.R.string.copy) }.getOrDefault("Copy").lowercase()
        val isCopy = when (event.eventType) {
            android.view.accessibility.AccessibilityEvent.TYPE_VIEW_CLICKED -> words == copy || words == "copy" || words.startsWith("copy ")
            else -> words.contains("copied") || words.contains("clipboard")
        }
        if (isCopy) main.postDelayed({ readClipboardBriefly() }, 250)
    }

    private val main = Handler(Looper.getMainLooper())
    private var reader: View? = null

    /** Adds an invisible 1×1 focusable window, reads the clipboard once focused, then removes it. */
    private fun readClipboardBriefly() {
        if (reader != null) return
        val wm = getSystemService(WindowManager::class.java)
        val v = object : View(this) {
            override fun onWindowFocusChanged(hasFocus: Boolean) {
                super.onWindowFocusChanged(hasFocus)
                if (!hasFocus) return
                val text = getSystemService(android.content.ClipboardManager::class.java)
                    .primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
                text?.let { ClipSync.autoSend(applicationContext, it) }
                dropReader()
            }
        }
        reader = v
        runCatching {
            wm.addView(v, WindowManager.LayoutParams(1, 1, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE, PixelFormat.TRANSPARENT)
                .apply { gravity = Gravity.TOP or Gravity.START })
        }.onFailure { reader = null; return }
        main.postDelayed({ dropReader() }, 800)      // never hold focus for long
    }

    private fun dropReader() {
        val v = reader ?: return
        reader = null
        runCatching { getSystemService(WindowManager::class.java).removeView(v) }
    }
    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig); listener()
    }
    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean { shutdown(); return super.onUnbind(intent) }
    override fun onDestroy() { shutdown(); super.onDestroy() }
    private fun shutdown() {
        if (!running) return
        running = false
        IslandBus.unlisten(listener)
        host?.remove(); host = null
        IslandBus.notifyChanged()
    }
}

