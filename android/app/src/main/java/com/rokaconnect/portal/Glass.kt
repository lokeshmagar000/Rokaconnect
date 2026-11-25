package com.rokaconnect.portal

import android.content.Context
import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// ─────────────────────────────────────────────────────────────────────────────
// Design system — colours come straight from the app icon:
// warm near-black background, orange → coral → pink gradient, cream badges.
// One place for every colour, size and spring so all screens match.
// ─────────────────────────────────────────────────────────────────────────────

/** Sizes and spring timing (same spring as the Mac app's Design.swift). */
object DS {
    val cardRadius: Dp = 24.dp          // section cards
    val tileRadius: Dp = 22.dp          // big action tiles
    val gap: Dp = 12.dp                 // space between sections
    val pad: Dp = 18.dp                 // padding inside a card
    val touch: Dp = 48.dp               // smallest tap target (Android guideline)
    const val springDamping = 0.85f
    const val springStiffness = 250f
}

/** All colours. The app is always dark, like its icon and the island. */
object Palette {
    val bg = Color(0xFF15100E)          // page background
    val surface = Color(0xFF211916)     // cards
    val raised = Color(0xFF2E2420)      // buttons / badges on cards
    val line = Color(0x14FFF4EA)        // hairline borders and dividers
    val ink = Color(0xFFFFF4EA)         // main text (warm white)
    val muted = Color(0xA8FFF4EA)       // secondary text (≥ 4.5:1 on surface)
    val faint = Color(0x5CFFF4EA)       // hints, disabled
    val cream = Color(0xFFFFF1DE)       // icon badges, like the icon's circles
    val orange = Color(0xFFFFC27A)
    val coral = Color(0xFFF0805A)
    val pink = Color(0xFFE85A78)
    val onAccent = Color(0xFF2A140F)    // dark text on the gradient
    val good = Color(0xFF7BD88F)        // connected / done
    val warn = Color(0xFFFFC27A)        // waiting
    val gradient = Brush.horizontalGradient(listOf(orange, coral, pink))
}

/** Main text colour (kept as a name the rest of the app already uses). */
val Ink: Color get() = Palette.ink

// Read by the island and the screens.
val LocalReduceMotion = staticCompositionLocalOf { false }

/** One spring for every animation; instant when "Remove animations" is on. */
@Composable
fun <T> appSpring(): AnimationSpec<T> =
    if (LocalReduceMotion.current) snap() else spring(DS.springDamping, DS.springStiffness)

/** "Remove animations" in Android's accessibility settings. */
private fun reduceMotion(c: Context) =
    Settings.Global.getFloat(c.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f

/** The whole screen: theme, background and a soft warm glow at the top. */
@Composable
fun AppScreen(content: @Composable BoxScope.() -> Unit) {
    val ctx = LocalContext.current
    val rm = remember { reduceMotion(ctx) }
    val scheme = darkColorScheme(
        primary = Palette.coral, onPrimary = Palette.onAccent, background = Palette.bg, surface = Palette.surface,
        onSurface = Palette.ink, onBackground = Palette.ink, surfaceVariant = Palette.raised, outline = Palette.line,
    )
    MaterialTheme(colorScheme = scheme) {
        CompositionLocalProvider(LocalReduceMotion provides rm) {
            Box(
                Modifier.fillMaxSize().background(Palette.bg)
                    .background(Brush.radialGradient(listOf(Palette.coral.copy(alpha = 0.16f), Color.Transparent), center = Offset(540f, 120f), radius = 1100f)),
                content = content,
            )
        }
    }
}

/** Shrinks a little while pressed and springs back — the touch reaction. */
@Composable
fun Modifier.pressable(enabled: Boolean = true, role: Role = Role.Button, onClick: () -> Unit): Modifier {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.96f else 1f, appSpring(), label = "press")
    return this.graphicsLayer { scaleX = scale; scaleY = scale }
        .clickable(interactionSource = source, indication = null, enabled = enabled, role = role, onClick = onClick)
}

/** Small grey label above a section ("SYNC", "ISLAND"…). */
@Composable
fun SectionLabel(text: String) =
    Text(text.uppercase(), color = Palette.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp,
        modifier = Modifier.padding(start = 6.dp, top = 10.dp, bottom = 2.dp))

/** A rounded card that holds one section. */
@Composable
fun Section(modifier: Modifier = Modifier, label: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth()) {
        if (label != null) SectionLabel(label)
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(DS.cardRadius)).background(Palette.surface)
                .border(1.dp, Palette.line, RoundedCornerShape(DS.cardRadius)).padding(DS.pad),
            verticalArrangement = Arrangement.spacedBy(14.dp),
            content = content,
        )
    }
}

/** The main button: orange → pink gradient, dark text. */
@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, enabled: Boolean = true, onClick: () -> Unit) {
    Row(
        modifier.heightIn(min = 52.dp).clip(CircleShape)
            .background(if (enabled) Palette.gradient else SolidColor(Palette.raised))
            .pressable(enabled, onClick = onClick).padding(horizontal = 22.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        val c = if (enabled) Palette.onAccent else Palette.faint
        if (icon != null) { Icon(icon, null, tint = c, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)) }
        Text(text, color = c, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, maxLines = 1)
    }
}

/** A quieter button on a raised surface. */
@Composable
fun SecondaryButton(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, danger: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    Row(
        modifier.heightIn(min = DS.touch).clip(CircleShape).background(Palette.raised)
            .pressable(enabled, onClick = onClick).padding(horizontal = 18.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        val c = when { !enabled -> Palette.faint; danger -> Palette.pink; else -> Palette.ink }
        if (icon != null) { Icon(icon, null, tint = c, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)) }
        Text(text, color = c, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, maxLines = 1)
    }
}

/** Round icon badge — cream with a coral icon, like the circles in the app icon. */
@Composable
fun Badge(icon: ImageVector, size: Dp = 40.dp, cream: Boolean = false, tint: Color = Palette.coral) {
    Box(Modifier.size(size).clip(CircleShape).background(if (cream) Palette.cream else Palette.raised), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(size * 0.5f))
    }
}

/** Big square button for the main actions (Photos / Files). */
@Composable
fun ActionTile(icon: ImageVector, label: String, hint: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Column(
        modifier.clip(RoundedCornerShape(DS.tileRadius)).background(Palette.surface)
            .border(1.dp, Palette.line, RoundedCornerShape(DS.tileRadius))
            .pressable(onClick = onClick).padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Badge(icon, 52.dp, cream = true)
        Column {
            Text(label, color = Palette.ink, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
            Text(hint, color = Palette.muted, fontSize = 13.sp)
        }
    }
}

/** App-coloured switch. */
@Composable
fun AppSwitch(checked: Boolean, onChange: (Boolean) -> Unit) = Switch(
    checked = checked, onCheckedChange = onChange,
    colors = SwitchDefaults.colors(
        checkedThumbColor = Palette.cream, checkedTrackColor = Palette.coral, checkedBorderColor = Palette.coral,
        uncheckedThumbColor = Palette.muted, uncheckedTrackColor = Palette.raised, uncheckedBorderColor = Palette.line,
    ),
)

/** One row: icon, title, one short line of explanation, and a switch. The whole row is tappable. */
@Composable
fun SwitchRow(icon: ImageVector, title: String, sub: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = DS.touch).pressable(role = Role.Switch) { onChange(!checked) }, verticalAlignment = Alignment.CenterVertically) {
        Badge(icon)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = Palette.ink, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            if (sub != null) Text(sub, color = Palette.muted, fontSize = 13.sp)
        }
        Spacer(Modifier.width(10.dp))
        AppSwitch(checked, onChange)
    }
}

/** A row that opens to show more (used for advanced settings, so the screen stays simple). */
@Composable
fun Expandable(icon: ImageVector, title: String, sub: String? = null, startOpen: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
    var open by rememberSaveable(title) { mutableStateOf(startOpen) }
    val turn by animateFloatAsState(if (open) 180f else 0f, appSpring(), label = "chevron")
    Row(Modifier.fillMaxWidth().heightIn(min = DS.touch).pressable { open = !open }, verticalAlignment = Alignment.CenterVertically) {
        Badge(icon)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = Palette.ink, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            if (sub != null) Text(sub, color = Palette.muted, fontSize = 13.sp)
        }
        Icon(RIcons.chevronDown, if (open) "Hide" else "Show", tint = Palette.muted, modifier = Modifier.size(22.dp).rotate(turn))
    }
    AnimatedVisibility(open, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
        Column(Modifier.fillMaxWidth().padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
    }
}

/** Thin divider between rows inside a card. */
@Composable
fun Hairline() = Box(Modifier.fillMaxWidth().height(1.dp).background(Palette.line))

/** Progress bar in the brand gradient. */
@Composable
fun GradientProgress(progress: Float, modifier: Modifier = Modifier) {
    val p by animateFloatAsState(progress.coerceIn(0f, 1f), appSpring(), label = "progress")
    Box(modifier.fillMaxWidth().height(6.dp).clip(CircleShape).background(Palette.raised)) {
        Box(Modifier.fillMaxWidth(p).fillMaxHeight().clip(CircleShape).background(Palette.gradient))
    }
}

/** Concentric rings, like the app icon (decoration behind the header). */
@Composable
fun Rings(modifier: Modifier = Modifier) = Canvas(modifier) {
    val c = Offset(size.width / 2, size.height / 2)
    for (i in 1..4) drawCircle(Palette.coral.copy(alpha = 0.16f - i * 0.03f), radius = size.minDimension * 0.18f * i, center = c,
        style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.5f))
}

// ─────────────────────────────────────────────────────────────────────────────
// Line icons, drawn here (no emoji, no extra library). 24×24 grid, 2px rounded strokes.
// ─────────────────────────────────────────────────────────────────────────────
object RIcons {
    private fun icon(name: String, vararg paths: String): ImageVector {
        val b = ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f)
        for (d in paths) b.addPath(
            pathData = PathParser().parsePathString(d).toNodes(), stroke = SolidColor(Color.White), strokeLineWidth = 2f,
            strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
        )
        return b.build()
    }
    val photo = icon("photo", "M6 3h12a3 3 0 0 1 3 3v12a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3z", "M7 9a2 2 0 1 0 4 0a2 2 0 1 0-4 0", "M21 15l-5-5L5 21")
    val folder = icon("folder", "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z")
    val file = icon("file", "M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z", "M14 3v5h5")
    val up = icon("up", "M12 19V5", "M6 11l6-6 6 6")
    val down = icon("down", "M12 5v14", "M18 13l-6 6-6-6")
    val check = icon("check", "M5 12.5l4.5 4.5L19 7")
    val clipboard = icon("clipboard", "M9 3h6a1 1 0 0 1 1 1v2H8V4a1 1 0 0 1 1-1z", "M16 5h2a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2", "M9 12h6", "M9 16h4")
    val laptop = icon("laptop", "M5 5h14a1 1 0 0 1 1 1v10H4V6a1 1 0 0 1 1-1z", "M2 19h20")
    val island = icon("island", "M7 9h10a3 3 0 0 1 0 6H7a3 3 0 0 1 0-6z", "M8 12h.01")
    val link = icon("link", "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1", "M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1")
    val qr = icon("qr", "M4 4h6v6H4z", "M14 4h6v6h-6z", "M4 14h6v6H4z", "M14 14h2v2h-2z", "M20 14v6h-4", "M17 17h.01")
    val refresh = icon("refresh", "M20 12a8 8 0 1 1-2.3-5.6", "M20 4v5h-5")
    val chevronDown = icon("chevron", "M6 9l6 6 6-6")
    val sliders = icon("sliders", "M4 7h10", "M18 7h2", "M16 5v4", "M4 17h4", "M12 17h8", "M10 15v4")
    val shield = icon("shield", "M12 3l8 3v6c0 4.5-3.4 8-8 9c-4.6-1-8-4.5-8-9V6z", "M8.5 12l2.5 2.5L15.5 10")
    val heart = icon("heart", "M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z")
    val cable = icon("cable", "M9 2v4", "M15 2v4", "M7 6h10v4a5 5 0 0 1-10 0z", "M12 15v7")
    val phone = icon("phone", "M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z", "M11 18h2")
    val buds = icon("buds", "M7 4a3 3 0 0 0-3 3v3a3 3 0 0 0 6 0V7a3 3 0 0 0-3-3z", "M7 13v6", "M17 4a3 3 0 0 1 3 3v3a3 3 0 0 1-6 0V7a3 3 0 0 1 3-3z", "M17 13v6")
    val lock = icon("lock", "M7 11V8a5 5 0 0 1 10 0v3", "M6 11h12v10H6z")
    val sun = icon("sun", "M8 12a4 4 0 1 0 8 0a4 4 0 1 0-8 0", "M12 2v2", "M12 20v2", "M2 12h2", "M20 12h2", "M4.9 4.9l1.4 1.4", "M17.7 17.7l1.4 1.4", "M4.9 19.1l1.4-1.4", "M17.7 6.3l1.4-1.4")
    val eye = icon("eye", "M2 12s3.6-7 10-7s10 7 10 7s-3.6 7-10 7S2 12 2 12z", "M9 12a3 3 0 1 0 6 0a3 3 0 1 0-6 0")
}
