package com.rokaconnect.portal

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Base64
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.PickVisualMediaRequest
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.TextRange
import androidx.activity.SystemBarStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private lateinit var state: AppState

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        UsbLink.start(this)     // watch for the USB cable link to the Mac
        AoaLink.startIfAttached(this)   // cable already plugged in as a Rokaconnect accessory (no USB debugging)
        BudsLink.start(this)            // Galaxy Buds battery + noise control (once "Nearby devices" is allowed)
        // light status/nav icons on the dark glass background
        enableEdgeToEdge(SystemBarStyle.dark(android.graphics.Color.TRANSPARENT), SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        state = AppState(applicationContext)
        state.addShared(intent)
        setContent { PortalScreen(state) }
    }

    override fun onResume() {
        super.onResume()
        PhoneRinger.stop(this)      // opening the app stops "Ring phone"
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        state.addShared(intent)
    }

    override fun onStart() { super.onStart(); state.finder.start(); IslandBus.sync(this) }
    override fun onStop() { super.onStop(); state.finder.stop() }
}

class AppState(val ctx: Context) {
    private val prefs = ctx.getSharedPreferences("portal", Context.MODE_PRIVATE)
    val finder = MacFinder(ctx)

    var key by mutableStateOf(prefs.getString("key", null)?.let { Base64.decode(it, Base64.NO_WRAP) })
    var code by mutableStateOf(prefs.getString("code", "") ?: "")
    var manualHost by mutableStateOf(prefs.getString("host", "") ?: "")
    /** Address from the pairing QR code, used when network discovery hasn't found the Mac. */
    var qrHost by mutableStateOf(prefs.getString("qrHost", "") ?: "")
    var qrPort by mutableStateOf(prefs.getInt("qrPort", Portal.PORT))
    var macName by mutableStateOf<String?>(null)
    var macFiles by mutableStateOf<List<MacFile>>(emptyList())
    var message by mutableStateOf("")
    var busyPairing by mutableStateOf(false)
    val transfers get() = TransferLog.items
    /** Set by the island's quick menu: open the file or photo picker as soon as the screen is up. */
    var pickRequest by mutableStateOf(false)
    var photoRequest by mutableStateOf(false)
    var autoReceive by mutableStateOf(Link.autoReceive(ctx))
    val pendingShares = mutableStateListOf<Uri>()
    var pendingText by mutableStateOf<String?>(null)

    /** USB cable first (fastest), then a manual address, then the first Mac found on the network. */
    val target: Pair<String, Int>?
        get() = (if (UsbLink.active) "127.0.0.1" to Portal.PORT else null) ?: manualHost.trim().takeIf { it.isNotEmpty() }?.let { h ->
            val parts = h.split(":"); parts[0] to (parts.getOrNull(1)?.toIntOrNull() ?: Portal.PORT)
        } ?: finder.macs.firstOrNull()?.let { it.host to it.port }
            ?: qrHost.takeIf { it.isNotEmpty() }?.let { it to qrPort }

    fun client(): PortalClient? {
        val k = key ?: return null
        val (h, p) = target ?: return null
        return PortalClient(ctx, h, p, k)
    }

    fun saveManualHost(h: String) { manualHost = h; prefs.edit().putString("host", h).apply() }

    /** Handles rokaconnect://pair?c=CODE&h=IP&p=PORT&n=NAME from the Mac's QR code. Returns true if it was a pairing link. */
    suspend fun pairFromLink(raw: String?): Boolean {
        val u = raw?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return false
        if (u.scheme != "rokaconnect" || u.host != "pair") return false
        val c = u.getQueryParameter("c") ?: return false
        // only remember a Mac address on the local network (a link from the internet can't point the phone elsewhere)
        qrHost = u.getQueryParameter("h")?.takeIf { isLocalAddress(it) } ?: ""
        qrPort = u.getQueryParameter("p")?.toIntOrNull() ?: Portal.PORT
        prefs.edit().putString("qrHost", qrHost).putInt("qrPort", qrPort).apply()
        pair(c)
        return true
    }

    var pendingLink by mutableStateOf<String?>(null)
    /** A pairing link opened from outside the app (browser, message): asks before replacing the pairing. */
    var pairAsk by mutableStateOf<String?>(null)

    /** Private (home / office) network addresses and .local names only. */
    fun isLocalAddress(h: String): Boolean {
        if (h.endsWith(".local", ignoreCase = true)) return true
        val p = h.split(".").mapNotNull { it.toIntOrNull() }
        if (p.size != 4 || p.any { it !in 0..255 }) return false
        return p[0] == 10 || (p[0] == 172 && p[1] in 16..31) || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254)
    }

    suspend fun pair(newCode: String) {
        busyPairing = true; message = ""
        val k = withContext(Dispatchers.Default) { Portal.deriveKey(newCode) }
        key = k; code = Portal.normalize(newCode)
        prefs.edit().putString("key", Base64.encodeToString(k, Base64.NO_WRAP)).putString("code", code).apply()
        refresh(report = true)
        busyPairing = false
        IslandBus.sync(ctx)        // start receiving in the background
    }

    fun unpair() {
        key = null; code = ""; macName = null; macFiles = emptyList()
        prefs.edit().remove("key").remove("code").apply()
        IslandBus.sync(ctx)
    }

    suspend fun refresh(report: Boolean = false) {
        val c = client() ?: run { if (report) message = if (key == null) "" else "Looking for your Mac…"; return }
        try {
            val (name, files) = withContext(Dispatchers.IO) { c.list() }
            macName = name; macFiles = files.filter { !it.direct }
            if (autoReceive) withContext(Dispatchers.IO) { AutoReceiver.handle(ctx, c, files) }
            if (report || message.isNotEmpty()) message = ""
        } catch (e: Exception) {
            macName = null
            message = e.message ?: "Can't reach the Mac"
        }
    }

    fun addShared(intent: Intent?) {
        intent ?: return
        when (intent.action) {
            Intent.ACTION_VIEW -> pendingLink = intent.dataString
            ACTION_PICK_FILES -> pickRequest = true
            ACTION_PICK_PHOTOS -> photoRequest = true
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val u = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (u != null) pendingShares.add(u)
                else intent.getStringExtra(Intent.EXTRA_TEXT)?.let { pendingText = it }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { pendingShares.addAll(it) }
            }
        }
    }

    /** Sends now if connected; otherwise queues and sends as soon as the Mac is found. */
    fun queueOrSend(uris: List<Uri>, scope: kotlinx.coroutines.CoroutineScope) {
        if (uris.isEmpty()) return
        if (macName != null) scope.launch { send(uris) }
        else { pendingShares.addAll(uris); message = "Will send as soon as your Mac is found" }
    }

    suspend fun send(uris: List<Uri>) {
        val c = client() ?: run { pendingShares.addAll(uris); message = "Will send as soon as your Mac is found"; return }
        for (u in uris) {
            val id = TransferLog.start(u.lastPathSegment ?: "File", incoming = false, status = "Sending…")
            TransferLog.flyNow(u, incoming = false)
            try {
                val name = withContext(Dispatchers.IO) { c.sendFile(u, onRate = { r -> TransferLog.rate(id, "Sending", r) }) { p -> TransferLog.progress(id, p) } }
                TransferLog.done(id, title = name, status = "Sent to Mac")
            } catch (e: Exception) { TransferLog.failed(id, e.message ?: "Failed") }
        }
    }

    suspend fun sendText(text: String) {
        val c = client() ?: run { pendingText = text; message = "Will send as soon as your Mac is found"; return }
        val id = TransferLog.start(text.take(60), incoming = false, status = "Sending…")
        TransferLog.flyNow(null, incoming = false)
        try {
            withContext(Dispatchers.IO) { c.sendText(text) }
            TransferLog.done(id, status = "Copied on Mac")
        } catch (e: Exception) { TransferLog.failed(id, e.message ?: "Failed") }
    }

    suspend fun download(f: MacFile) {
        val c = client() ?: return
        val id = TransferLog.start(f.name, incoming = true, status = "Saving…")
        try {
            val uri = withContext(Dispatchers.IO) { c.download(f, onRate = { r -> TransferLog.rate(id, "Saving", r) }) { p -> TransferLog.progress(id, p) } }
            TransferLog.done(id, status = "Saved to Downloads/Rokaconnect", uri = uri)
            TransferLog.flyNow(uri, incoming = true)
        } catch (e: Exception) { TransferLog.failed(id, e.message ?: "Failed") }
    }

    fun open(uri: Uri) {
        val type = ctx.contentResolver.getType(uri) ?: "*/*"
        val i = Intent(Intent.ACTION_VIEW).setDataAndType(uri, type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { ctx.startActivity(i) }
    }
}

// MARK: - UI
// Layout (top to bottom): header with the island status → Send (Photos / Files) → Activity →
// From your Mac → Sync switches → Setup (only while something is missing) → Island → Connection → About.

@Composable
fun PortalScreen(s: AppState) {
    val scope = rememberCoroutineScope()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris -> s.queueOrSend(uris, scope) }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(50)) { uris -> s.queueOrSend(uris, scope) }
    fun pickPhotos() = photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
    // the island's quick menu asked for these
    LaunchedEffect(s.pickRequest) { if (s.pickRequest) { s.pickRequest = false; picker.launch(arrayOf("*/*")) } }
    LaunchedEffect(s.photoRequest) { if (s.photoRequest) { s.photoRequest = false; pickPhotos() } }
    val connected = s.macName != null

    // keep the Mac's list fresh while the app is open
    LaunchedEffect(s.key, s.finder.macs.size, s.manualHost, UsbLink.state.value) {
        while (true) { s.refresh(); delay(5_000) }
    }
    // pairing link opened from the phone camera
    // a pairing link opened from a browser or message: never pair silently — ask first (see the dialog below)
    LaunchedEffect(s.pendingLink) { s.pendingLink?.let { l -> s.pendingLink = null; s.pairAsk = l } }
    s.pairAsk?.let { link ->
        val name = runCatching { Uri.parse(link).getQueryParameter("n") }.getOrNull()?.takeIf { it.isNotBlank() } ?: "a Mac"
        // "Pair" only works after a short moment (like Android's own install/permission prompts), so an app that
        // presses buttons automatically — or a quick accidental tap — can't confirm it
        var ready by remember(link) { mutableStateOf(false) }
        LaunchedEffect(link) { delay(1_500); ready = true }
        val view = androidx.compose.ui.platform.LocalView.current
        AlertDialog(
            onDismissRequest = { s.pairAsk = null },
            title = { Text("Pair with $name?") },
            text = {
                // ignore taps while another app's window covers this prompt (overlay tricks)
                DisposableEffect(Unit) { view.rootView.filterTouchesWhenObscured = true; onDispose { } }
                Text((if (s.key != null) "This replaces your current pairing. " else "") +
                    "Only continue if you just scanned the code shown in Rokaconnect on your own Mac.")
            },
            confirmButton = {
                TextButton(enabled = ready, onClick = {
                    if (!ready) return@TextButton
                    s.pairAsk = null
                    scope.launch { if (!s.pairFromLink(link)) s.message = "That isn't a Rokaconnect pairing code" }
                }) { Text("Pair") }
            },
            dismissButton = { TextButton(onClick = { s.pairAsk = null }) { Text("Cancel") } },
        )
    }    // things shared into the app from other apps go out as soon as a Mac is reachable
    LaunchedEffect(connected, s.pendingShares.size, s.pendingText) {
        if (connected && s.pendingShares.isNotEmpty()) { val list = s.pendingShares.toList(); s.pendingShares.clear(); s.send(list) }
        if (connected) s.pendingText?.let { t -> s.pendingText = null; s.sendText(t) }
    }

    AppScreen {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(DS.gap),
        ) {
            Header(s)
            if (s.key == null) PairCard(s) else {
                // main actions
                Row(horizontalArrangement = Arrangement.spacedBy(DS.gap)) {
                    ActionTile(RIcons.photo, "Photos", "Send to Mac", Modifier.weight(1f)) { pickPhotos() }
                    ActionTile(RIcons.folder, "Files", "Send to Mac", Modifier.weight(1f)) { picker.launch(arrayOf("*/*")) }
                }
                Text(
                    if (connected) "Tip: Share → Rokaconnect from any app also works." else "Not connected — what you pick is sent once your Mac is found.",
                    color = if (connected) Palette.muted else Palette.warn, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 6.dp),
                )
                ActivitySection(s)
                UsbSection()
                if (s.macFiles.isNotEmpty()) MacFilesSection(s)
                SyncSection(s)
                SetupCard()
                IslandCard(s)
                ConnectionCard(s)
            }
            AboutCard()
            Spacer(Modifier.height(12.dp))
        }
        FlyLayer()
    }
}

/** App name, then a black island (like the icon) that says whether the Mac is connected. */
@Composable
fun Header(s: AppState) {
    val connected = s.macName != null
    val (dot, text) = when {
        s.key == null -> Palette.faint to "Not paired yet"
        connected -> Palette.good to (s.macName ?: "Mac")
        s.message.isNotEmpty() -> Palette.warn to s.message
        else -> Palette.warn to "Looking for your Mac…"
    }
    Column {
        Text("Rokaconnect", color = Palette.ink, fontSize = 30.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 6.dp, top = 12.dp))
        Box(Modifier.fillMaxWidth().height(150.dp), contentAlignment = Alignment.Center) {
            Rings(Modifier.fillMaxSize())
            // the island pill: status dot, text, gradient level bars
            Row(
                Modifier.widthIn(max = 330.dp).fillMaxWidth(0.86f).height(64.dp).clip(CircleShape).background(Color.Black)
                    .border(1.5.dp, Palette.gradient, CircleShape).padding(horizontal = 18.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(30.dp).clip(CircleShape).background(Color(0xFF1C1614)), contentAlignment = Alignment.Center) {
                    Box(Modifier.size(12.dp).clip(CircleShape).background(dot))
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(if (connected && UsbLink.state.value) "Connected by cable · fastest" else if (connected) "Connected" else if (s.key == null) "Rokaconnect" else "Waiting", color = Palette.muted, fontSize = 12.sp)
                    Text(text, color = Palette.ink, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                LevelBars(active = connected)
            }
        }
    }
}

/** Five small bars in the brand colours; they move gently while connected. */
@Composable
fun LevelBars(active: Boolean) {
    val reduce = LocalReduceMotion.current
    val t = rememberInfiniteTransition(label = "bars")
    val phase by t.animateFloat(0f, (2 * Math.PI).toFloat(), infiniteRepeatable(tween(1600, easing = LinearEasing)), label = "phase")
    val cols = listOf(Palette.orange, Palette.orange, Palette.coral, Palette.coral, Palette.pink)
    val base = listOf(0.35f, 0.65f, 1f, 0.55f, 0.8f)
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically, modifier = Modifier.height(28.dp)) {
        cols.forEachIndexed { i, c ->
            val wave = if (active && !reduce) 0.6f + 0.4f * kotlin.math.sin(phase + i * 1.1f).let { (it + 1f) / 2f } else 1f
            Box(Modifier.width(4.dp).fillMaxHeight(base[i] * wave * (if (active) 1f else 0.5f)).clip(CircleShape).background(if (active) c else Palette.faint))
        }
    }
}

/** Sent and received items, newest first, with a gradient progress bar while moving. */
@Composable
fun ActivitySection(s: AppState) {
    Section(label = "Activity") {
        if (s.transfers.isEmpty()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Badge(RIcons.up, tint = Palette.muted)
                Spacer(Modifier.width(14.dp))
                Text("Files you send or receive show up here.", color = Palette.muted, fontSize = 14.sp)
            }
        }
        s.transfers.take(12).forEachIndexed { i, t ->
            if (i > 0) Hairline()
            val moving = t.progress in 0.001f..0.999f
            val done = t.progress >= 1f && !t.status.endsWith("…")
            Row(
                Modifier.fillMaxWidth().animateContentSize().heightIn(min = DS.touch)
                    .pressable(enabled = t.uri != null) { t.uri?.let(s::open) },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Badge(if (done) RIcons.check else if (t.incoming) RIcons.down else RIcons.up, tint = if (done) Palette.good else Palette.coral)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(t.title, color = Palette.ink, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (moving) GradientProgress(t.progress, Modifier.padding(vertical = 6.dp))
                    Text(t.status, color = Palette.muted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/** Files the Mac offered to any phone, each with a Save button. */
@Composable
fun MacFilesSection(s: AppState) {
    val scope = rememberCoroutineScope()
    Section(label = "From your Mac") {
        s.macFiles.forEachIndexed { i, f ->
            if (i > 0) Hairline()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Badge(RIcons.file)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(f.name, color = Palette.ink, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(size(f.size), color = Palette.muted, fontSize = 13.sp)
                }
                SecondaryButton("Save", icon = RIcons.down) { scope.launch { s.download(f) } }
            }
        }
        SecondaryButton("Refresh", Modifier.fillMaxWidth(), icon = RIcons.refresh) { scope.launch { s.refresh(report = true) } }
    }
}

/** Automatic receive + automatic clipboard. */
@Composable
fun SyncSection(s: AppState) {
    var autoClip by remember { mutableStateOf(Link.autoClip(s.ctx)) }
    Section(label = "Sync") {
        SwitchRow(RIcons.down, "Receive automatically", "Files from the Mac save to Downloads/Rokaconnect", s.autoReceive) {
            s.autoReceive = it; Link.setAutoReceive(s.ctx, it)
        }
        Hairline()
        SwitchRow(RIcons.clipboard, "Clipboard sync", "Copy on one device, paste on the other", autoClip) {
            autoClip = it; Link.setAutoClip(s.ctx, it)
        }
    }
}

/** First run: scan the Mac's QR code (or type its code). */
@Composable
fun PairCard(s: AppState) {
    val scope = rememberCoroutineScope()
    var draft by remember { mutableStateOf(TextFieldValue("")) }
    Section(label = "Get started") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Badge(RIcons.laptop, 48.dp, cream = true)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text("Pair with your Mac", color = Palette.ink, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                Text("On the Mac: Rokaconnect → Settings → Portal", color = Palette.muted, fontSize = 13.sp)
            }
        }
        ScanButton(s)
        Text("or type the code", color = Palette.faint, fontSize = 13.sp, modifier = Modifier.align(Alignment.CenterHorizontally))
        OutlinedTextField(
            // keep the cursor at the end after inserting dashes, so typed characters stay in order
            value = draft, onValueChange = { v -> val p = Portal.pretty(v.text).take(14); draft = TextFieldValue(p, TextRange(p.length)) },
            placeholder = { Text("XXXX-XXXX-XXXX", color = Palette.faint) }, singleLine = true, shape = RoundedCornerShape(16.dp),
            textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace, fontSize = 20.sp, color = Palette.ink),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false),
            colors = fieldColors(), modifier = Modifier.fillMaxWidth(),
        )
        SecondaryButton(if (s.busyPairing) "Pairing…" else "Pair", Modifier.fillMaxWidth(),
            enabled = !s.busyPairing && Portal.normalize(draft.text).length == 12) { scope.launch { s.pair(draft.text) } }
        if (s.message.isNotEmpty()) Text(s.message, color = Palette.warn, fontSize = 13.sp)
    }
}

/** Text field colours that match the cards. */
@Composable
fun fieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = Palette.coral, unfocusedBorderColor = Palette.line, cursorColor = Palette.coral,
    focusedLabelColor = Palette.coral, unfocusedLabelColor = Palette.muted, focusedContainerColor = Palette.bg, unfocusedContainerColor = Palette.bg,
)

/** Pairing details, manual address, re-pair and unpair — folded away. */
@Composable
fun ConnectionCard(s: AppState) {
    var host by remember { mutableStateOf(s.manualHost) }
    Section(label = "Connection") {
        Expandable(RIcons.link, "Paired Mac", "Code ${Portal.pretty(s.code)}") {
            if (s.finder.macs.isNotEmpty()) Text("Found on Wi-Fi: " + s.finder.macs.joinToString { it.name }, color = Palette.muted, fontSize = 13.sp)
            OutlinedTextField(value = host, onValueChange = { host = it; s.saveManualHost(it) }, singleLine = true, shape = RoundedCornerShape(16.dp),
                label = { Text("Mac address (only if not found)") }, placeholder = { Text("192.168.1.20", color = Palette.faint) },
                textStyle = LocalTextStyle.current.copy(color = Palette.ink), colors = fieldColors(), modifier = Modifier.fillMaxWidth())
            ScanButton(s, "Pair again with QR", prominent = false)
            SecondaryButton("Unpair", Modifier.fillMaxWidth(), danger = true) { s.unpair() }
        }
    }
}

/** Who made the app — shown at the bottom of the screen. */
@Composable
fun AboutCard() {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    fun open(url: String) = runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    Section(label = "About") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Badge(RIcons.heart, 48.dp, cream = true, tint = Palette.pink)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text("Rokaconnect ${ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName}", color = Palette.ink, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                Text("Lok Bahadur Roka Magar — Creator, from Nepal", color = Palette.muted, fontSize = 13.sp)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SecondaryButton("Facebook", Modifier.weight(1f)) { open("https://facebook.com/iamlokeshmagar") }
            SecondaryButton("Instagram", Modifier.weight(1f)) { open("https://instagram.com/iamlokeshmagar") }
            SecondaryButton("TikTok", Modifier.weight(1f)) { open("https://www.tiktok.com/@lokeshmagar000") }
        }
        Text("Facebook iamlokeshmagar · Instagram @iamlokeshmagar · TikTok @lokeshmagar000", color = Palette.faint, fontSize = 12.sp)
    }
}

fun size(n: Long): String = when {
    n < 1024 -> "$n B"
    n < 1 shl 20 -> "${n / 1024} KB"
    n < 1 shl 30 -> String.format("%.1f MB", n / 1048576.0)
    else -> String.format("%.2f GB", n / 1073741824.0)
}
