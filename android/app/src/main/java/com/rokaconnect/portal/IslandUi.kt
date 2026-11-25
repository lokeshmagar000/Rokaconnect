package com.rokaconnect.portal

import android.content.Context
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

// ─────────────────────────────────────────────────────────────────────────────
// The Android Dynamic Island screen — kept simple on purpose:
//   compact → small black pill hugging the camera; shows a transfer or music if there is one
//   split   → pill + small circle when a transfer and music happen together
//   open    → tap: ONE card — transfer, or music controls, plus Send files / Send photos
// ─────────────────────────────────────────────────────────────────────────────

/** Sizes, worked out by the overlay host from where this phone's camera is. */
data class IslandGeo(
    val pillCx: Dp = 200.dp,       // centre of the camera, measured inside the drawing window
    val pillTop: Dp = 8.dp,        // top of the pill inside the drawing window (centres it on the camera)
    val margin: Dp = 8.dp,         // empty edge around everything (room for the spring)
    val winW: Dp = 400.dp,         // drawing window width
    val idleW: Dp = 96.dp, val idleH: Dp = 32.dp,   // pill hugging the camera
    val holeW: Dp = 0.dp,          // camera hole width (compact content stays out of it)
    val expW: Dp = 320.dp,         // open card width
    val textTop: Dp = 0.dp,        // extra room so text clears the status bar
    val k: Float = 1f,             // size slider
    val showIdle: Boolean = true,
)

/** Live state; the host owns one, the screen reads it. */
class IslandModel {
    var geo by mutableStateOf(IslandGeo())
    var expanded by mutableStateOf(false)
    var transfer by mutableStateOf(IslandState())
    /** Bumped when a transfer starts or finishes → the pill gives a little bounce. */
    var bump by mutableIntStateOf(0)
    /** Music or Devices, in the open card (Devices whenever nothing is playing). */
    var page by mutableStateOf(PhonePage.MUSIC)
    var onOpen: (String?) -> Unit = {}
}

/** What can be "live" in the closed island. */
sealed class Live {
    data class Transfer(val s: IslandState) : Live()
    data class Music(val t: PhoneTrack) : Live()
}

fun liveList(m: IslandModel): List<Live> = buildList {
    if (m.transfer.active || m.transfer.done) add(Live.Transfer(m.transfer))
    PhoneMedia.track.value?.takeIf { it.playing }?.let { add(Live.Music(it)) }
}

/** The island's three shapes. */
enum class IslandShapeKind { COMPACT, OPEN }

fun shapeOf(m: IslandModel): IslandShapeKind = when {
    m.expanded -> IslandShapeKind.OPEN
    else -> IslandShapeKind.COMPACT
}

// ── sizes (shared by the screen and the host, so the touch area always matches what you see) ──

fun compactWidth(g: IslandGeo, live: List<Live>): Dp = if (live.isEmpty()) g.idleW else maxOf(g.idleW, g.holeW + 54.dp * (2 * g.k))
fun hasSplit(live: List<Live>) = live.size >= 2

fun cardHeight(m: IslandModel): Dp {
    val g = m.geo
    return g.textTop + (pageHeight(m) + 20.dp) * g.k       // page content + top/bottom padding
}


/** Target width/height for the current shape. */
fun targetSize(m: IslandModel): Pair<Dp, Dp> {
    val g = m.geo
    return when (shapeOf(m)) {
        IslandShapeKind.OPEN -> g.expW to cardHeight(m)
        IslandShapeKind.COMPACT -> compactWidth(g, liveList(m)) to g.idleH
    }
}

/** Left edge of the island inside the window: centred on the camera, but kept on screen. */
fun leftFor(g: IslandGeo, w: Dp): Dp {
    val hi = g.winW - g.margin - w
    // during the opening bounce the card can be a few pixels wider than the window: just centre it
    if (hi < g.margin) return (g.winW - w) / 2
    return (g.pillCx - w / 2).coerceIn(g.margin, hi)
}

@Composable
fun IslandUi(m: IslandModel, ctx: Context) {
    val g = m.geo
    val live = liveList(m)
    val shape = shapeOf(m)
    val haptic = LocalHapticFeedback.current
    val reduce = LocalReduceMotion.current
    // opening has a gentle bounce; closing has none (no wobble when it shrinks)
    val opening = shape != IslandShapeKind.COMPACT
    fun <T> spec(): FiniteAnimationSpec<T> = when {
        reduce -> snap()
        opening -> spring(dampingRatio = 0.66f, stiffness = 380f)   // opens with a little bounce
        else -> spring(dampingRatio = 0.82f, stiffness = 460f)      // closes with a softer one
    }
    val (tw, th) = targetSize(m)
    val w by animateDpAsState(tw, spec(), label = "w")
    val h by animateDpAsState(th, spec(), label = "h")
    val corner by animateDpAsState(if (shape == IslandShapeKind.COMPACT) g.idleH / 2 else 28.dp * g.k, spec(), label = "r")
    val visible = shape != IslandShapeKind.COMPACT || live.isNotEmpty() || g.showIdle

    // the open card closes by itself after 8 s untouched
    var touched by remember { mutableLongStateOf(0L) }
    LaunchedEffect(m.expanded, touched) { if (m.expanded) { delay(8_000); m.expanded = false } }

    // stretchy bounce when a transfer starts or finishes
    val hop = remember { androidx.compose.animation.core.Animatable(1f) }
    LaunchedEffect(m.bump) {
        if (m.bump == 0 || reduce) return@LaunchedEffect
        hop.animateTo(1.12f, spring(dampingRatio = 1f, stiffness = 1400f))
        hop.animateTo(1f, spring(dampingRatio = 0.35f, stiffness = 500f))
    }

    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier
                .offset(x = leftFor(g, w), y = g.pillTop)
                .graphicsLayer { scaleX = hop.value; scaleY = 1f + (hop.value - 1f) * 1.4f; transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0.5f, 0f) }
                .size(w, h)
                .clip(RoundedCornerShape(corner))
                .background(if (visible) Color.Black else Color.Transparent)
                // tap = open · long-press = open the app · swipe up = close
                .pointerInput(shape) {
                    detectTapGestures(
                        onTap = {
                            touched = System.currentTimeMillis()
                            // ringing from the Mac ("Ring phone")? a tap on the island stops it
                            if (PhoneRinger.ringing) { PhoneRinger.stop(ctx); return@detectTapGestures }
                            when (shape) {
                                IslandShapeKind.COMPACT -> { haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove); m.expanded = true }
                                IslandShapeKind.OPEN -> Unit
                            }
                        },
                        onLongPress = { haptic.performHapticFeedback(HapticFeedbackType.LongPress); m.expanded = false; m.onOpen(null) },
                    )
                }
                .pointerInput(Unit) {
                    var total = 0f
                    detectVerticalDragGestures(onDragStart = { total = 0f }, onVerticalDrag = { _, dy -> total += dy }, onDragEnd = {
                        if (total < -20.dp.toPx()) { haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove); m.expanded = false }
                    })
                },
        ) {
            AnimatedContent(shape, transitionSpec = {
                fadeIn(tween(if (reduce) 0 else 150, delayMillis = if (targetState != IslandShapeKind.COMPACT && !reduce) 80 else 0)) togetherWith fadeOut(tween(80))
            }, label = "content") { s ->
                when (s) {
                    IslandShapeKind.COMPACT -> Compact(live.firstOrNull(), g)
                    IslandShapeKind.OPEN -> OpenCard(m, ctx, onTouch = { touched = System.currentTimeMillis() })
                }
            }
        }
        // the small circle beside the pill when two things are live
        if (shape == IslandShapeKind.COMPACT && hasSplit(live)) {
            Box(Modifier.offset(x = leftFor(g, w) + w + 6.dp * g.k, y = g.pillTop).size(g.idleH).clip(CircleShape).background(Color.Black),
                contentAlignment = Alignment.Center) { LiveIcon(live[1], g.idleH - 10.dp * g.k) }
        }
    }
}

// ── closed island ────────────────────────────────────────────────────────────

@Composable
private fun Compact(primary: Live?, g: IslandGeo) {
    if (primary == null) return
    Row(Modifier.fillMaxSize().padding(horizontal = 8.dp * g.k), verticalAlignment = Alignment.CenterVertically) {
        // left: picture or progress ring · middle: the camera · right: percent or waveform
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) { LiveIcon(primary, g.idleH - 8.dp * g.k) }
        Spacer(Modifier.width(g.holeW))
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
            when (primary) {
                is Live.Transfer -> Text(if (primary.s.done) (if (primary.s.incoming) "Saved" else "Sent") else "${(primary.s.progress * 100).toInt()}%",
                    color = if (primary.s.done) Color(0xFF7CF29C) else Color(0xFF66DCFF), fontSize = (12 * g.k).sp, fontWeight = FontWeight.Bold)
                is Live.Music -> Waveform(true, Modifier.size(22.dp * g.k, 14.dp * g.k))
            }
        }
    }
}

@Composable
private fun LiveIcon(l: Live, size: Dp) {
    when (l) {
        is Live.Transfer -> ProgressRing(l.s, size)
        is Live.Music -> l.t.art?.let { Image(it.asImageBitmap(), null, Modifier.size(size).clip(RoundedCornerShape(size / 4)), contentScale = ContentScale.Crop) }
            ?: Waveform(true, Modifier.size(size * 0.8f, size * 0.55f))   // no artwork: just the moving bars
    }
}

@Composable
private fun ProgressRing(s: IslandState, size: Dp) {
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize().padding(2.dp)) {
            val st = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round)
            drawArc(Color.White.copy(alpha = 0.22f), 0f, 360f, false, style = st)
            drawArc(if (s.done) Color(0xFF7CF29C) else Color(0xFF66DCFF), -90f, 360f * (if (s.done) 1f else s.progress.coerceIn(0.02f, 1f)), false, style = st)
        }
        Text(if (s.done) "✓" else if (s.incoming) "↓" else "↑", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold)
    }
}

/** Little bouncing bars, like the Mac's notch waveform. */
@Composable
fun Waveform(playing: Boolean, modifier: Modifier) {
    val t = rememberInfiniteTransition(label = "wave")
    val phase by t.animateFloat(0f, 6.283f, infiniteRepeatable(tween(1100), RepeatMode.Restart), label = "phase")
    Canvas(modifier) {
        val n = 5; val gap = size.width / (n * 2f)
        for (i in 0 until n) {
            val amp = if (playing) 0.35f + 0.65f * kotlin.math.abs(kotlin.math.sin(phase * (1f + i * 0.37f) + i)) else 0.25f
            val bh = size.height * amp; val x = gap / 2 + i * gap * 2 + gap / 2
            drawLine(Color(0xFFFF9FCB), Offset(x, (size.height - bh) / 2), Offset(x, (size.height + bh) / 2), strokeWidth = gap, cap = StrokeCap.Round)
        }
    }
}

// ── the open card ────────────────────────────────────────────────────────────

enum class MediaGlyph { PLAY, PAUSE, NEXT, PREV }

