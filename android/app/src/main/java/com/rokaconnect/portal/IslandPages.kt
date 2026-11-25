package com.rokaconnect.portal

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.BatteryManager
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

// ─────────────────────────────────────────────────────────────────────────────
// The open phone island — the same design as the Mac's island:
//   Music page   : artwork across the top fading into black · title · seek bar with a knob · big play button · "Playing on …"
//   Devices page : battery rings (Mac · phone · earbuds) · earbuds noise control · Lock Mac / Keep Mac awake / Send files / Send photos
//   Music · Devices tabs at the top while something is playing.
// ─────────────────────────────────────────────────────────────────────────────

enum class PhonePage { MUSIC, DEVICES }

/** Height of the open card's content (without the camera clearance). */
fun pageHeight(m: IslandModel): Dp {
    val t = PhoneMedia.track.value
    val transfer = if (m.transfer.active) 52.dp else 0.dp
    val tabs = if (t != null) 38.dp else 0.dp
    val body = if (t != null && m.page == PhonePage.MUSIC) 222.dp
        else 222.dp + (if (BudsLink.name.value != null || BudsLink.problem.value == "permission") 46.dp else 0.dp)
    return transfer + tabs + body
}

private val Pink = Color(0xFFFF3B5F)

/** The whole open card: hero artwork behind, then tabs + the picked page. */
@Composable
fun OpenCard(m: IslandModel, ctx: Context, onTouch: () -> Unit) {
    val g = m.geo; val k = g.k
    val t = PhoneMedia.track.value
    val musicPage = t != null && m.page == PhonePage.MUSIC
    Box(Modifier.fillMaxSize()) {
        if (musicPage) Hero(t!!, Modifier.fillMaxWidth().height(g.textTop + 150.dp * k))
        Column(
            Modifier.fillMaxSize().padding(top = g.textTop + 8.dp * k, start = 16.dp * k, end = 16.dp * k, bottom = 12.dp * k),
            verticalArrangement = Arrangement.spacedBy(10.dp * k),
        ) {
            if (m.transfer.active) TransferStrip(m.transfer, k)
            if (t != null) Tabs(m.page, k) { m.page = it; onTouch() }
            if (musicPage) MusicPage(t!!, ctx, k, onTouch) else DevicesPage(m, ctx, k, onTouch)
        }
    }
}

// ── pieces ──────────────────────────────────────────────────────────────────

@Composable
private fun TransferStrip(s: IslandState, k: Float) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.height(42.dp * k)) {
        Box(Modifier.size(34.dp * k).clip(CircleShape).background(Color.White.copy(alpha = 0.1f)), contentAlignment = Alignment.Center) {
            Icon(if (s.incoming) RIcons.down else RIcons.up, null, tint = Palette.coral, modifier = Modifier.size(18.dp * k))
        }
        Column(Modifier.weight(1f).padding(start = 10.dp)) {
            Text(s.title, color = Color.White, fontSize = (13 * k).sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Box(Modifier.padding(top = 5.dp).fillMaxWidth().height(4.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.15f))) {
                Box(Modifier.fillMaxWidth(s.progress.coerceIn(0f, 1f)).fillMaxHeight().background(Palette.gradient))
            }
        }
        Text("${(s.progress * 100).toInt()}%", color = Palette.coral, fontSize = (13 * k).sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 10.dp))
    }
}

/** Two small tabs: Music · Devices (picked one in the brand gradient). */
@Composable
private fun Tabs(page: PhonePage, k: Float, pick: (PhonePage) -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Tab("Music", page == PhonePage.MUSIC, k) { pick(PhonePage.MUSIC) }
        Tab("Devices", page == PhonePage.DEVICES, k) { pick(PhonePage.DEVICES) }
    }
}

@Composable
private fun Tab(title: String, on: Boolean, k: Float, onClick: () -> Unit) {
    Box(
        Modifier.height(28.dp * k).clip(CircleShape)
            .background(if (on) Palette.gradient else Brush.linearGradient(listOf(Color.Black.copy(alpha = 0.45f), Color.Black.copy(alpha = 0.45f))))
            .border(1.dp, Color.White.copy(alpha = if (on) 0f else 0.14f), CircleShape)
            .press(onClick).padding(horizontal = 14.dp * k),
        contentAlignment = Alignment.Center,
    ) { Text(title, color = if (on) Palette.onAccent else Color.White.copy(alpha = 0.85f), fontSize = (12 * k).sp, fontWeight = FontWeight.SemiBold) }
}

/** The song's artwork across the top, fading into black (pink + a faint note when there's no artwork). */
@Composable
private fun Hero(t: PhoneTrack, modifier: Modifier) {
    val accent = remember(t.art) { t.art?.let { avgColor(it) } ?: Pink }
    Box(modifier.background(accent)) {
        val art = t.art
        if (art != null) Image(art.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        else Text("♪", color = Color.White.copy(alpha = 0.25f), fontSize = 72.sp, modifier = Modifier.align(Alignment.Center))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(
            0f to Color.Black.copy(alpha = 0.2f), 0.35f to Color.Transparent, 0.7f to Color.Black.copy(alpha = 0.6f), 1f to Color.Black)))
    }
}

private fun avgColor(b: Bitmap): Color = runCatching {
    val px = Bitmap.createScaledBitmap(b, 1, 1, true).getPixel(0, 0)
    Color(px).copy(alpha = 1f)
}.getOrDefault(Pink)

@Composable
private fun MusicPage(t: PhoneTrack, ctx: Context, k: Float, onTouch: () -> Unit) {
    var pos by remember { mutableLongStateOf(t.now()) }
    LaunchedEffect(t) { while (true) { pos = t.now(); delay(500) } }
    var scrub by remember { mutableStateOf<Float?>(null) }
    Spacer(Modifier.height(30.dp * k))
    // title + artist + the playing app's button
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(t.title, color = Color.White, fontSize = (18 * k).sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(t.artist.ifEmpty { appName(ctx, t.app) }, color = Color.White.copy(alpha = 0.65f), fontSize = (13 * k).sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        AppIconButton(ctx, t.app, 38.dp * k) { onTouch() }
    }
    // seek bar with a knob; drag or tap to jump
    if (t.duration > 0) {
        val frac = scrub ?: (pos.toFloat() / t.duration).coerceIn(0f, 1f)
        var width by remember { mutableIntStateOf(1) }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Box(
                Modifier.fillMaxWidth().height(18.dp).onSizeChanged { width = it.width }
                    .pointerInput(t.duration) {
                        detectTapGestures { o -> onTouch(); PhoneMedia.seek((o.x / width * t.duration).toLong()) }
                    }
                    .pointerInput(t.duration) {
                        detectHorizontalDragGestures(
                            onDragStart = { o -> onTouch(); scrub = (o.x / width).coerceIn(0f, 1f) },
                            onHorizontalDrag = { c, _ -> scrub = (c.position.x / width).coerceIn(0f, 1f) },
                            onDragEnd = { scrub?.let { PhoneMedia.seek((it * t.duration).toLong()) }; scrub = null },
                        )
                    },
                contentAlignment = Alignment.CenterStart,
            ) {
                Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.2f)))
                Box(Modifier.fillMaxWidth(frac).height(4.dp).clip(CircleShape).background(Color.White))
                val knob by animateDpAsState(if (scrub != null) 16.dp else 12.dp, label = "knob")
                Box(Modifier.offset { androidx.compose.ui.unit.IntOffset((frac * width - knob.toPx() / 2).toInt(), 0) }.size(knob).clip(CircleShape).background(Color.White))
            }
            Row {
                Text(fmt(scrub?.let { (it * t.duration).toLong() } ?: pos), color = Color.White.copy(alpha = 0.55f), fontSize = (11 * k).sp)
                Spacer(Modifier.weight(1f))
                Text("-" + fmt(t.duration - (scrub?.let { (it * t.duration).toLong() } ?: pos)), color = Color.White.copy(alpha = 0.55f), fontSize = (11 * k).sp)
            }
        }
    }
    // back · big white play/pause · forward
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
        GlyphButton(MediaGlyph.PREV, 40.dp * k) { onTouch(); PhoneMedia.previous() }
        Box(Modifier.size(52.dp * k).clip(CircleShape).background(Color.White).press { onTouch(); PhoneMedia.playPause() }, contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(20.dp * k)) { drawGlyph(if (t.playing) MediaGlyph.PAUSE else MediaGlyph.PLAY, Color.Black) }
        }
        GlyphButton(MediaGlyph.NEXT, 40.dp * k) { onTouch(); PhoneMedia.next() }
    }
    // where the sound is playing
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Text("Playing on ${outputName(ctx)}", color = Color.White.copy(alpha = 0.8f), fontSize = (12 * k).sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.1f)).padding(horizontal = 14.dp, vertical = 6.dp))
    }
}

@Composable
private fun DevicesPage(m: IslandModel, ctx: Context, k: Float, onTouch: () -> Unit) {
    val (phoneLevel, phoneCharging) = rememberPhoneBattery(ctx)
    val macLevel = MacState.battery.value
    val buds = BudsLink.name.value
    val budsLevel = listOfNotNull(BudsLink.left.value, BudsLink.right.value).minOrNull()
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Your devices", color = Color.White, fontSize = (14 * k).sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Box(Modifier.size(7.dp).clip(CircleShape).background(if (macLevel >= 0) Palette.good else Color.White.copy(alpha = 0.3f)))
        Text(if (macLevel >= 0 && buds != null) "  All linked" else if (macLevel >= 0) "  Mac linked" else "  Not linked",
            color = Color.White.copy(alpha = 0.6f), fontSize = (11 * k).sp)
    }
    Row(Modifier.fillMaxWidth()) {
        Ring(macLevel.takeIf { it >= 0 }, MacState.charging.value, RIcons.laptop, "Mac", 0, k, Modifier.weight(1f))
        Ring(phoneLevel, phoneCharging, RIcons.phone, "This phone", 1, k, Modifier.weight(1f))
        Ring(budsLevel, false, RIcons.buds, if (buds != null) shortBuds(buds) else "Earbuds", 2, k, Modifier.weight(1f))
    }
    when {
        buds != null && BudsLink.problem.value == null -> NoiseSwitch(BudsLink.noise.value, k) { onTouch(); BudsLink.setNoise(it) }
        BudsLink.problem.value == "permission" -> ActionPill(RIcons.buds, "Allow earbuds controls", false, k, Modifier.fillMaxWidth()) { m.expanded = false; m.onOpen(null) }
    }
    // quick actions
    var awake by remember { mutableStateOf(MacState.awake.value) }
    LaunchedEffect(MacState.awake.value) { awake = MacState.awake.value }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ActionPill(RIcons.lock, "Lock Mac", false, k, Modifier.weight(1f)) { onTouch(); MacState.command(ctx, "lock") }
        ActionPill(RIcons.sun, if (awake) "Mac awake" else "Keep awake", awake, k, Modifier.weight(1f)) {
            onTouch(); val want = !awake; awake = want
            MacState.command(ctx, if (want) "awake-on" else "awake-off") { ok -> if (!ok) awake = !want }
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ActionPill(RIcons.folder, "Send files", false, k, Modifier.weight(1f)) { m.expanded = false; m.onOpen(ACTION_PICK_FILES) }
        ActionPill(RIcons.photo, "Send photos", false, k, Modifier.weight(1f)) { m.expanded = false; m.onOpen(ACTION_PICK_PHOTOS) }
    }
}

/** A battery ring that fills up with a spring; green / orange / red; a dot while charging. */
@Composable
private fun Ring(level: Int?, charging: Boolean, icon: ImageVector, name: String, order: Int, k: Float, modifier: Modifier) {
    val fill = remember { Animatable(0f) }
    LaunchedEffect(level) { delay(60L + order * 70L); fill.animateTo((level ?: 0) / 100f, spring(dampingRatio = 0.78f, stiffness = 120f)) }
    val color = when { level == null -> Color.White.copy(alpha = 0.3f); level <= 20 -> Color(0xFFFF5454); level <= 40 -> Color(0xFFFF9F1A); else -> Color(0xFF34D667) }
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(56.dp * k), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize()) {
                val sw = 5.dp.toPx(); val inset = sw / 2
                val arc = Size(size.width - sw, size.height - sw)
                drawArc(Color.White.copy(alpha = 0.1f), 0f, 360f, false, Offset(inset, inset), arc, style = Stroke(sw))
                if (level != null) drawArc(color, -90f, 360f * fill.value, false, Offset(inset, inset), arc, style = Stroke(sw, cap = StrokeCap.Round))
            }
            Icon(icon, null, tint = Color.White.copy(alpha = if (level == null) 0.45f else 1f), modifier = Modifier.size(20.dp * k))
            if (charging) Box(Modifier.align(Alignment.TopEnd).size(14.dp * k).clip(CircleShape).background(color), contentAlignment = Alignment.Center) {
                Text("⚡", fontSize = (8 * k).sp, color = Color.Black)
            }
        }
        Text(level?.let { "$it%" } ?: "—", color = Color.White, fontSize = (13 * k).sp, fontWeight = FontWeight.Bold)
        Text(name, color = Color.White.copy(alpha = 0.55f), fontSize = (10 * k).sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Off · Noise cancelling · Ambient, with the highlight sliding to the picked one. */
@Composable
private fun NoiseSwitch(mode: Int?, k: Float, set: (Int) -> Unit) {
    val labels = listOf("Off", "Noise cancel", "Ambient")
    var width by remember { mutableIntStateOf(0) }
    val target = (mode ?: -1)
    val x by androidx.compose.animation.core.animateFloatAsState(if (target < 0) 0f else target.toFloat(), spring(dampingRatio = 0.8f, stiffness = 500f), label = "noise")
    Box(Modifier.fillMaxWidth().height(36.dp * k).clip(CircleShape).background(Color.White.copy(alpha = 0.08f)).padding(3.dp).onSizeChanged { width = it.width }) {
        if (target >= 0 && width > 0) {
            Box(Modifier.offset { androidx.compose.ui.unit.IntOffset((x * width / 3f).toInt(), 0) }
                .fillMaxHeight().fillMaxWidth(1f / 3f).clip(CircleShape).background(Palette.gradient))
        }
        Row(Modifier.fillMaxSize()) {
            labels.forEachIndexed { i, l ->
                Box(Modifier.weight(1f).fillMaxHeight().clip(CircleShape).press { set(i) }, contentAlignment = Alignment.Center) {
                    Text(l, color = if (mode == i) Palette.onAccent else Color.White.copy(alpha = 0.8f), fontSize = (11.5 * k).sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun ActionPill(icon: ImageVector, title: String, active: Boolean, k: Float, modifier: Modifier, onClick: () -> Unit) {
    Row(
        modifier.height(36.dp * k).clip(RoundedCornerShape(12.dp))
            .background(if (active) Palette.coral.copy(alpha = 0.32f) else Color.White.copy(alpha = 0.08f))
            .border(1.dp, if (active) Palette.coral.copy(alpha = 0.7f) else Color.White.copy(alpha = 0.06f), RoundedCornerShape(12.dp))
            .press(onClick),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = if (active) Palette.cream else Color.White, modifier = Modifier.size(15.dp * k))
        Spacer(Modifier.width(6.dp))
        Text(title, color = if (active) Palette.cream else Color.White, fontSize = (12 * k).sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
private fun GlyphButton(glyph: MediaGlyph, size: Dp, onClick: () -> Unit) {
    Box(Modifier.size(size).clip(CircleShape).press(onClick), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size * 0.5f)) { drawGlyph(glyph, Color.White) }
    }
}

/** The playing app's own icon; tap opens that app. */
@Composable
private fun AppIconButton(ctx: Context, pkg: String, size: Dp, onTouch: () -> Unit) {
    val icon = remember(pkg) { runCatching { ctx.packageManager.getApplicationIcon(pkg) }.getOrNull() }
    val bmp = remember(icon) {
        icon?.let { d -> runCatching {
            Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888).also { b -> val c = android.graphics.Canvas(b); d.setBounds(0, 0, 96, 96); d.draw(c) }
        }.getOrNull() }
    }
    Box(Modifier.size(size).clip(CircleShape).background(Color.White.copy(alpha = 0.16f)).press {
        onTouch()
        ctx.packageManager.getLaunchIntentForPackage(pkg)?.let { runCatching { ctx.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }
    }, contentAlignment = Alignment.Center) {
        if (bmp != null) Image(bmp.asImageBitmap(), null, Modifier.size(size * 0.6f))
    }
}

/** Squeezes a little while pressed. */
@Composable
private fun Modifier.press(onClick: () -> Unit): Modifier {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    val s by androidx.compose.animation.core.animateFloatAsState(if (pressed) 0.92f else 1f, spring(dampingRatio = 0.6f, stiffness = 600f), label = "press")
    return this.graphicsLayer { scaleX = s; scaleY = s }.clickable(interactionSource = src, indication = null, onClick = onClick)
}

// ── small helpers ───────────────────────────────────────────────────────────

@Composable
private fun rememberPhoneBattery(ctx: Context): Pair<Int?, Boolean> {
    fun read(): Pair<Int?, Boolean> {
        val i = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null to false
        val lvl = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1); val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val st = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return (if (lvl >= 0) lvl * 100 / scale else null) to (st == BatteryManager.BATTERY_STATUS_CHARGING || st == BatteryManager.BATTERY_STATUS_FULL)
    }
    var v by remember { mutableStateOf(read()) }
    LaunchedEffect(Unit) { while (true) { delay(10_000); v = read() } }
    return v
}

/** "Lok Bahadur's Buds2 Pro" → "Buds2 Pro". */
private fun shortBuds(n: String) = n.substringAfter("'s ").substringAfter("’s ")

private fun appName(ctx: Context, pkg: String) = runCatching {
    ctx.packageManager.getApplicationLabel(ctx.packageManager.getApplicationInfo(pkg, 0)).toString()
}.getOrDefault("")

/** Where sound is going right now: the Bluetooth earbuds' name, or the phone speaker. */
private fun outputName(ctx: Context): String {
    val am = ctx.getSystemService(AudioManager::class.java) ?: return "this phone"
    val bt = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull {
        it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || it.type == AudioDeviceInfo.TYPE_BLE_HEADSET || it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
    }
    return bt?.productName?.toString()?.let { shortBuds(it) } ?: "this phone"
}

private fun fmt(ms: Long): String { val s = (ms.coerceAtLeast(0) / 1000).toInt(); return "%d:%02d".format(s / 60, s % 60) }

/** Draws play / pause / next / previous as simple white shapes (no emoji). */
fun androidx.compose.ui.graphics.drawscope.DrawScope.drawGlyph(glyph: MediaGlyph, color: Color) {
    val w = size.width; val h = size.height
    fun tri(x0: Float, x1: Float) {
        val p = androidx.compose.ui.graphics.Path().apply { moveTo(x0, 0f); lineTo(x1, h / 2); lineTo(x0, h); close() }
        drawPath(p, color)
    }
    fun triBack(x0: Float, x1: Float) {
        val p = androidx.compose.ui.graphics.Path().apply { moveTo(x1, 0f); lineTo(x0, h / 2); lineTo(x1, h); close() }
        drawPath(p, color)
    }
    when (glyph) {
        MediaGlyph.PLAY -> tri(w * 0.18f, w * 0.95f)
        MediaGlyph.PAUSE -> { drawRect(color, Offset(w * 0.18f, 0f), Size(w * 0.22f, h)); drawRect(color, Offset(w * 0.6f, 0f), Size(w * 0.22f, h)) }
        MediaGlyph.NEXT -> { tri(0f, w * 0.5f); tri(w * 0.5f, w) }
        MediaGlyph.PREV -> { triBack(0f, w * 0.5f); triBack(w * 0.5f, w) }
    }
}
