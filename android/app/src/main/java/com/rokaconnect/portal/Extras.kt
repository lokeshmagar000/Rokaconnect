package com.rokaconnect.portal

import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.provider.Settings
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.foundation.Canvas
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext


/** One send/receive animation request. */
data class Fly(val id: Long, val uri: Uri?, val incoming: Boolean)

/** Opens Google's QR scanner (no camera permission needed) and pairs from the Mac's code. */
fun scanPairingQR(s: AppState, onLink: (String) -> Unit) {
    val opts = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).enableAutoZoom().build()
    GmsBarcodeScanning.getClient(s.ctx, opts).startScan()
        .addOnSuccessListener { b -> b.rawValue?.let(onLink) }
        .addOnFailureListener { e -> s.message = "Scanner unavailable: ${e.message ?: "try typing the code"}" }
}

@Composable
fun ScanButton(s: AppState, label: String = "Scan QR code on Mac", prominent: Boolean = true) {
    val scope = rememberCoroutineScope()
    val scan = { scanPairingQR(s) { link -> scope.launch { if (!s.pairFromLink(link)) s.message = "That QR code isn't a Rokaconnect pairing code" } } }
    if (prominent) PrimaryButton(label, Modifier.fillMaxWidth(), icon = RIcons.qr) { scan() }
    else SecondaryButton(label, Modifier.fillMaxWidth(), icon = RIcons.qr) { scan() }
}

/**
 * Send: the item lifts from the middle of the screen and shrinks into the island.
 * Receive: a portal spins open in the app, the file comes out of it towards you, and the portal closes.
 */
@Composable
fun FlyLayer() {
    val f = TransferLog.fly.value ?: return
    if (LocalReduceMotion.current) { LaunchedEffect(f.id) { TransferLog.fly.value = null }; return }   // "Remove animations" on
    if (f.incoming) PortalArrival(f) else SendFlight(f)
}

/** Loads a small preview of the file (photo / video frame), or null. */
@Composable
private fun rememberThumb(f: Fly): Bitmap? {
    val ctx = LocalContext.current
    var thumb by remember(f.id) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(f.id) {
        thumb = f.uri?.let { u -> withContext(Dispatchers.IO) { runCatching { ctx.contentResolver.loadThumbnail(u, Size(400, 400), null) }.getOrNull() } }
    }
    return thumb
}

/** The flying card: the preview, or a file icon / "Aa" for text. */
@Composable
private fun FlyCard(f: Fly, thumb: Bitmap?, modifier: Modifier) {
    Box(modifier.size(150.dp).clip(RoundedCornerShape(30.dp)).background(Palette.raised), contentAlignment = Alignment.Center) {
        if (thumb != null) Image(thumb.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        else if (f.uri == null) Text("Aa", fontSize = 54.sp, color = Palette.ink)
        else androidx.compose.material3.Icon(RIcons.file, null, tint = Palette.cream, modifier = Modifier.size(64.dp))
    }
}

/** Sending: from the middle of the screen up into the island along a small arc. */
@Composable
private fun SendFlight(f: Fly) {
    val ctx = LocalContext.current
    val thumb = rememberThumb(f)
    val t = remember(f.id) { Animatable(0f) }
    var box by remember { mutableStateOf(IntSize.Zero) }
    LaunchedEffect(f.id) {
        t.animateTo(1f, tween(850, easing = CubicBezierEasing(0.55f, 0f, 0.75f, 0.35f)))
        if (TransferLog.fly.value?.id == f.id) TransferLog.fly.value = null
    }
    val (tx, ty) = IslandBus.target(ctx)
    val sizePx = with(LocalDensity.current) { 150.dp.toPx() }
    Box(Modifier.fillMaxSize().onSizeChanged { box = it }) {
        if (box == IntSize.Zero) return@Box
        val p = t.value
        val cx = 0.5f + (tx - 0.5f) * p
        val cy = 0.55f + (ty - 0.55f) * p - 0.08f * kotlin.math.sin(Math.PI * p).toFloat()
        val scale = 1f - 0.92f * p
        FlyCard(f, thumb, Modifier.graphicsLayer {
            translationX = cx * box.width - sizePx / 2; translationY = cy * box.height - sizePx / 2
            scaleX = scale; scaleY = scale; alpha = if (p > 0.85f) (1f - p) / 0.15f else 1f
        })
    }
}

/** 0…1 progress of `p` inside the window [a, b], eased. */
private fun seg(p: Float, a: Float, b: Float, ease: Easing = FastOutSlowInEasing) = ease.transform(((p - a) / (b - a)).coerceIn(0f, 1f))
private val Overshoot = CubicBezierEasing(0.34f, 1.56f, 0.64f, 1f)     // springs a little past 1, then settles

/**
 * Receiving: a portal opens (spinning gradient rings + orbiting sparks), the file grows out of
 * its centre and drops towards you, then the portal closes and the card fades.
 * Timeline (1.8 s): 0–20% open · 20–62% file comes out · 60–80% portal closes · 86–100% card fades.
 */
@Composable
private fun PortalArrival(f: Fly) {
    val thumb = rememberThumb(f)
    val view = androidx.compose.ui.platform.LocalView.current
    val t = remember(f.id) { Animatable(0f) }
    var box by remember { mutableStateOf(IntSize.Zero) }
    LaunchedEffect(f.id) {
        t.animateTo(0.62f, tween((1800 * 0.62f).toInt(), easing = LinearEasing))
        view.performHapticFeedback(android.view.HapticFeedbackConstants.CONFIRM)      // a soft tap as it lands
        t.animateTo(1f, tween((1800 * 0.38f).toInt(), easing = LinearEasing))
        if (TransferLog.fly.value?.id == f.id) TransferLog.fly.value = null
    }
    val density = LocalDensity.current
    val cardPx = with(density) { 150.dp.toPx() }
    val portalPx = with(density) { 230.dp.toPx() }
    Box(Modifier.fillMaxSize().onSizeChanged { box = it }) {
        if (box == IntSize.Zero) return@Box
        val p = t.value
        val open = seg(p, 0f, 0.2f, Overshoot) * (1f - seg(p, 0.6f, 0.8f))           // portal size 0 → 1 → 0
        val out = seg(p, 0.2f, 0.62f, Overshoot)                                    // file coming out 0 → 1
        val fade = 1f - seg(p, 0.86f, 1f)
        val pcx = box.width * 0.5f; val pcy = box.height * 0.34f                    // portal centre
        // dim the screen a little so the portal stands out
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f * (seg(p, 0f, 0.15f) * fade))))
        // the portal
        Canvas(Modifier.size(with(density) { portalPx.toDp() }).graphicsLayer {
            translationX = pcx - portalPx / 2; translationY = pcy - portalPx / 2
            scaleX = open; scaleY = open; alpha = open.coerceIn(0f, 1f)
        }) { drawPortal(spin = p * 540f) }
        // the file, growing out of the portal and dropping to the middle of the screen
        val cx = pcx; val cy = pcy + (box.height * 0.52f - pcy) * out
        val scale = 0.05f + 0.95f * out
        FlyCard(f, thumb, Modifier.graphicsLayer {
            translationX = cx - cardPx / 2; translationY = cy - cardPx / 2
            scaleX = scale; scaleY = scale; rotationZ = -25f * (1f - out)
            alpha = (if (p < 0.2f) 0f else 1f) * fade
        })
    }
}

/** Draws the portal: soft glow, a spinning orange→pink ring, two inner rings turning the other way, orbiting sparks. */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawPortal(spin: Float) {
    val c = center; val r = size.minDimension / 2
    val sweep = Brush.sweepGradient(listOf(Palette.orange, Palette.coral, Palette.pink, Palette.coral, Palette.orange), center = c)
    drawCircle(Brush.radialGradient(listOf(Palette.coral.copy(alpha = 0.45f), Color.Transparent), center = c, radius = r), radius = r, center = c)   // glow
    drawCircle(Color(0xFF0B0706), radius = r * 0.62f, center = c)                                                                                // the dark inside
    drawCircle(Brush.radialGradient(listOf(Palette.pink.copy(alpha = 0.35f), Color.Transparent), center = c, radius = r * 0.6f), radius = r * 0.6f, center = c)
    rotate(spin, c) { drawCircle(sweep, radius = r * 0.66f, center = c, style = Stroke(width = r * 0.09f)) }                                    // main ring
    rotate(-spin * 1.4f, c) {
        drawArc(sweep, 20f, 250f, false, topLeft = Offset(c.x - r * 0.5f, c.y - r * 0.5f), size = androidx.compose.ui.geometry.Size(r, r), style = Stroke(width = r * 0.035f, cap = StrokeCap.Round), alpha = 0.8f)
    }
    rotate(spin * 2f, c) {
        drawArc(sweep, 200f, 200f, false, topLeft = Offset(c.x - r * 0.34f, c.y - r * 0.34f), size = androidx.compose.ui.geometry.Size(r * 0.68f, r * 0.68f), style = Stroke(width = r * 0.025f, cap = StrokeCap.Round), alpha = 0.55f)
    }
    for (i in 0 until 12) {                                                                                                                       // sparks
        val a = Math.toRadians((spin * 1.2f + i * 30f).toDouble())
        val rr = r * (0.78f + 0.08f * kotlin.math.sin(i * 1.7f + spin / 40f))
        val dot = if (i % 3 == 0) Palette.cream else if (i % 2 == 0) Palette.orange else Palette.pink
        drawCircle(dot.copy(alpha = 0.5f + 0.5f * kotlin.math.abs(kotlin.math.sin(i + spin / 60f))), radius = r * (0.018f + 0.012f * (i % 3)),
            center = Offset(c.x + rr * kotlin.math.cos(a).toFloat(), c.y + rr * kotlin.math.sin(a).toFloat()))
    }
}

@Composable
fun IslandCard(s: AppState) {
    val ctx = LocalContext.current
    var on by remember { mutableStateOf(IslandBus.enabled(ctx) && IslandBus.canDraw(ctx)) }
    var idle by remember { mutableStateOf(IslandBus.showIdle(ctx)) }
    var nudge by remember { mutableFloatStateOf(IslandBus.nudge(ctx)) }
    var lift by remember { mutableFloatStateOf(IslandBus.lift(ctx)) }
    var scale by remember { mutableFloatStateOf(IslandBus.scale(ctx)) }
    val notify = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    val overlay = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        on = IslandBus.canDraw(ctx); IslandBus.set(ctx, on = on); IslandBus.sync(ctx)
    }
    // coming back from the "Display over other apps" screen
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val o = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_RESUME && IslandBus.enabled(ctx)) { on = IslandBus.canDraw(ctx); IslandBus.sync(ctx) } }
        owner.lifecycle.addObserver(o); onDispose { owner.lifecycle.removeObserver(o) }
    }
    Section(label = "Island") {
        SwitchRow(RIcons.island, "Dynamic island", "Music and transfers around your camera", on) { want ->
            if (want && !IslandBus.canDraw(ctx)) {
                IslandBus.set(ctx, on = true)
                overlay.launch(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + ctx.packageName)))
            } else {
                on = want; IslandBus.set(ctx, on = want); IslandBus.sync(ctx)
                if (want && android.os.Build.VERSION.SDK_INT >= 33) notify.launch(android.Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (on) {
            Hairline()
            SwitchRow(RIcons.eye, "Show when idle", "Keep a small pill even with nothing playing", idle) { idle = it; IslandBus.set(ctx, idle = it) }
            Hairline()
            // optional fine-tuning on top of the automatic camera fit
            val custom = nudge != 0f || lift != 0f || scale != 1f
            Expandable(RIcons.sliders, "Position and size", if (custom) "Adjusted by you" else "Fits your camera automatically") {
                val sliderColors = SliderDefaults.colors(thumbColor = Palette.cream, activeTrackColor = Palette.coral, inactiveTrackColor = Palette.raised)
                fun preview() { IslandBus.update(IslandState("Preview", 0.6f, false, active = true)); IslandBus.update(IslandState("Preview", 1f, false, done = true)) }
                SliderLabel("Left / right", if (nudge == 0f) "Auto" else "${nudge.toInt()} dp")
                Slider(value = nudge, valueRange = -60f..60f, onValueChange = { nudge = it; IslandBus.set(ctx, nudge = it) },
                    onValueChangeFinished = { if (kotlin.math.abs(nudge) < 2f) { nudge = 0f; IslandBus.set(ctx, nudge = 0f) } }, colors = sliderColors)
                SliderLabel("Up / down", if (lift == 0f) "Auto" else "${lift.toInt()} dp")
                Slider(value = lift, valueRange = -20f..40f, onValueChange = { lift = it; IslandBus.set(ctx, lift = it) },
                    onValueChangeFinished = { if (kotlin.math.abs(lift) < 1f) { lift = 0f; IslandBus.set(ctx, lift = 0f) } }, colors = sliderColors)
                SliderLabel("Size", if (scale == 1f) "Auto" else "${(scale * 100).toInt()}%")
                Slider(value = scale, valueRange = 0.8f..1.4f, onValueChange = { scale = it; IslandBus.set(ctx, scale = it) },
                    onValueChangeFinished = { if (kotlin.math.abs(scale - 1f) < 0.02f) { scale = 1f; IslandBus.set(ctx, scale = 1f) }; preview() }, colors = sliderColors)
                if (custom) SecondaryButton("Reset to automatic", Modifier.fillMaxWidth(), icon = RIcons.refresh) {
                    nudge = 0f; lift = 0f; scale = 1f; IslandBus.set(ctx, nudge = 0f, lift = 0f, scale = 1f)
                }
            }
            Text("Tap the island for music and sending. Long-press opens the app.", color = Palette.faint, fontSize = 12.sp)
        }
    }
}

/** Slider name on the left, its value on the right. */
@Composable
private fun SliderLabel(name: String, value: String) = Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
    Text(name, color = Palette.ink, fontSize = 14.sp, modifier = Modifier.weight(1f))
    Text(value, color = Palette.muted, fontSize = 14.sp)
}


/**
 * Setup guide: each permission the app needs, why (one line), a button that opens the right
 * Android screen, and a check once it's on. Re-checks every time you come back to the app.
 * Hidden completely once everything is on, so the screen stays clean.
 */
@Composable
fun SetupCard() {
    val ctx = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var tick by remember { mutableIntStateOf(0) }
    DisposableEffect(owner) {
        val o = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_RESUME) tick++ }
        owner.lifecycle.addObserver(o); onDispose { owner.lifecycle.removeObserver(o) }
    }
    @Suppress("UNUSED_EXPRESSION") tick
    val pm = ctx.getSystemService(android.os.PowerManager::class.java)
    fun go(i: Intent) = runCatching { ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    data class Step(val title: String, val why: String, val done: Boolean, val open: () -> Unit)
    val steps = listOf(
        Step("Music on the island", "Notification access — only to read what's playing", PhoneMedia.allowed(ctx)) {
            go(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        },
        Step("Show over other apps", "Draws the island on top of any app", Settings.canDrawOverlays(ctx)) {
            go(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + ctx.packageName)))
        },
        Step("Accessibility", "Tap the island, send what you Copy", IslandAccessibility.running) {
            go(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        },
        Step("No battery limits", "Keeps Rokaconnect running in the background", pm.isIgnoringBatteryOptimizations(ctx.packageName)) {
            @android.annotation.SuppressLint("BatteryLife")
            val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.packageName))
            go(i)
        },
    )
    val left = steps.count { !it.done }
    if (left == 0) return
    Section(label = "Finish setup · $left left") {
        steps.forEachIndexed { i, st ->
            if (i > 0) Hairline()
            Row(Modifier.fillMaxWidth().heightIn(min = DS.touch), verticalAlignment = Alignment.CenterVertically) {
                Badge(if (st.done) RIcons.check else RIcons.shield, tint = if (st.done) Palette.good else Palette.coral)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(st.title, color = if (st.done) Palette.muted else Palette.ink, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                    if (!st.done) Text(st.why, color = Palette.muted, fontSize = 13.sp)
                }
                if (!st.done) { Spacer(Modifier.width(8.dp)); SecondaryButton("Turn on", onClick = st.open) }
            }
        }
        Text("Switch greyed out? Settings → Apps → Rokaconnect → ⋮ → Allow restricted settings.", color = Palette.faint, fontSize = 12.sp)
    }
}
