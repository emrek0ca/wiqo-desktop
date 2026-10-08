package com.wiqo.android.ui.widgets

import android.annotation.SuppressLint
import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.provider.ContactsContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import android.os.Handler
import android.os.Looper
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.JavascriptInterface
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream

@Composable
internal fun WiqoWidgetCard(widget: JsonObject, onOpenRelated: (String, String?) -> Unit, accountId: String?) {
    val type = widget.text("type") ?: return
    val colors = WiqoDesign.colors
    val context = LocalContext.current
    val title = widget.text("title") ?: type.replace('_', ' ').replaceFirstChar(Char::uppercase)
    Column(
        Modifier.fillMaxWidth().background(colors.inset, RoundedCornerShape(12.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(title.take(160), fontFamily = WiqoSans, fontWeight = FontWeight.SemiBold, color = colors.ink)
        (widget.text("summary") ?: widget.text("description") ?: widget.text("detail"))?.let {
            Text(it.take(600), fontFamily = WiqoSans, fontSize = 13.sp, color = colors.ink)
        }
        when (type) {
            "inline_app" -> InlineApp(widget, accountId, onOpenRelated)
            "act_handoff" -> {
                widget.text("request")?.let { Text(it.take(300), color = colors.ink, fontSize = 13.sp) }
                Link("Act'te aç") { onOpenRelated("act", widget.toString()) }
            }
            "code_change" -> {
                Rows(widget["items"] as? JsonArray)
                Link("Projeyi aç") { onOpenRelated("project-detail", widget.text("id")) }
            }
            "created_resource" -> {
                widget.text("scheduleLabel")?.let { Text(it, color = colors.ink, fontSize = 13.sp) }
                val route = if (widget.text("resourceType") == "agent") "agents" else "automation-detail"
                Link("Aç") { onOpenRelated(route, widget.text("id")) }
            }
            "task_plan" -> Rows(widget["planSteps"] as? JsonArray)
            "list" -> (widget["items"] as? JsonArray).orEmpty().take(12).forEach { item ->
                val row = item as? JsonObject ?: return@forEach
                val url = row.text("url")?.takeIf(::isSafeWebUrl)
                Text("• ${row.text("title").orEmpty()} ${row.text("subtitle").orEmpty()}".trim().take(250),
                    modifier = if (url == null) Modifier else Modifier.clickable { openLink(context, url) },
                    color = if (url == null) colors.ink else colors.blue, fontSize = 13.sp)
            }
            "table" -> {
                val columns = (widget["columns"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                if (columns.isNotEmpty()) Text(columns.joinToString("  |  ").take(250), fontSize = 12.sp, color = colors.ink)
                (widget["rows"] as? JsonArray).orEmpty().take(12).forEach { row ->
                    Text((row as? JsonArray).orEmpty().joinToString("  |  ") { (it as? JsonPrimitive)?.contentOrNull.orEmpty() }.take(250), fontSize = 12.sp, color = colors.ink)
                }
            }
            "card" -> {
                when (widget.text("kind")) {
                    "checklist" -> WidgetChecklist(widget["checklist"] as? JsonArray)
                    "calc" -> Text("${widget.text("expression").orEmpty()} = ${widget.text("result").orEmpty()}", color = colors.ink)
                    "translation" -> Text(widget.text("translated").orEmpty(), color = colors.ink)
                    "recipe" -> (widget["ingredients"] as? JsonArray).orEmpty().take(20).forEach { item ->
                        Text("• ${(item as? JsonPrimitive)?.contentOrNull.orEmpty()}", color = colors.ink, fontSize = 13.sp)
                    }
                    "quotes" -> (widget["quotes"] as? JsonArray).orEmpty().take(12).forEach { item ->
                        val quote = item as? JsonObject ?: return@forEach
                        Text("${quote.text("symbol").orEmpty()}  ${quote.text("price").orEmpty()} ${quote.text("unit").orEmpty()}  ${quote.text("changePercent").orEmpty()}%",
                            color = colors.ink, fontSize = 13.sp)
                    }
                    "score" -> (widget["matches"] as? JsonArray).orEmpty().take(12).forEach { item ->
                        val match = item as? JsonObject ?: return@forEach
                        Text("${match.text("home").orEmpty()} ${match.text("homeScore").orEmpty()}–${match.text("awayScore").orEmpty()} ${match.text("away").orEmpty()} · ${match.text("status").orEmpty()}",
                            color = colors.ink, fontSize = 13.sp)
                    }
                    "trip" -> (widget["tripDays"] as? JsonArray).orEmpty().take(10).forEach { day ->
                        val row = day as? JsonObject ?: return@forEach
                        Text(row.text("title").orEmpty(), color = colors.ink, fontWeight = FontWeight.SemiBold)
                        (row["items"] as? JsonArray).orEmpty().take(12).forEach { stop ->
                            val value = stop as? JsonObject ?: return@forEach
                            Text("• ${value.text("time").orEmpty()} ${value.text("title").orEmpty()} ${value.text("place").orEmpty()}".trim(),
                                color = colors.ink, fontSize = 13.sp)
                        }
                    }
                    "media" -> {
                        val query = widget.text("query") ?: title
                        val encoded = Uri.encode(query)
                        listOf("Apple Music" to "https://music.apple.com/tr/search?term=$encoded",
                            "Spotify" to "https://open.spotify.com/search/$encoded",
                            "YouTube" to "https://www.youtube.com/results?search_query=$encoded").forEach { (name, url) ->
                            Link(name) { openLink(context, url) }
                        }
                    }
                    "contact" -> ContactCard(widget.text("contactQuery") ?: title)
                    else -> widget.text("subtitle")?.let { Text(it, color = colors.ink, fontSize = 13.sp) }
                }
            }
            "weather" -> {
                val current = widget["current"] as? JsonObject
                Text("${widget.text("location").orEmpty()}  ${current?.text("temperatureC").orEmpty()}°  ${current?.text("condition").orEmpty()}", color = colors.ink)
                (widget["days"] as? JsonArray).orEmpty().take(7).forEach { day ->
                    val row = day as? JsonObject ?: return@forEach
                    Text("${row.text("date").orEmpty()}  ${row.text("condition").orEmpty()}  ${row.text("minC").orEmpty()}°–${row.text("maxC").orEmpty()}°", color = colors.ink, fontSize = 13.sp)
                }
            }
            "sources" -> (widget["sources"] as? JsonArray).orEmpty().take(10).forEach { source ->
                val row = source as? JsonObject ?: return@forEach
                val url = row.text("url")?.takeIf(::isSafeWebUrl)
                Text("• ${row.text("title") ?: row.text("url").orEmpty()}",
                    modifier = if (url == null) Modifier else Modifier.clickable { openLink(context, url) },
                    color = if (url == null) colors.ink else colors.blue, fontSize = 13.sp)
            }
            "task_result" -> Text("${widget.text("taskStatus").orEmpty()} · ${widget.text("completedSteps").orEmpty()}/${widget.text("totalSteps").orEmpty()}", color = colors.ink)
            "error" -> Text(widget.text("message").orEmpty().take(400), color = colors.ink)
            "map" -> {
                val place = widget.text("destination") ?: widget.text("query") ?: widget.text("near") ?: widget.text("origin")
                if (place != null) Link("${listOfNotNull(widget.text("origin"), place).distinct().joinToString(" → ")} · Haritada aç") {
                    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW,
                        Uri.parse("geo:0,0?q=${Uri.encode(place)}"))) }
                }
            }
        }
    }
}

@Composable
private fun ContactCard(query: String) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    if (!granted) {
        Link("Rehberde ara") { launcher.launch(Manifest.permission.READ_CONTACTS) }
        return
    }
    val contacts by produceState(initialValue = emptyList<Pair<String, String>>(), query, granted) {
        value = withContext(Dispatchers.IO) {
        val result = mutableListOf<Pair<String, String>>()
        runCatching {
            context.contentResolver.query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER),
                "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?", arrayOf("%${query.take(80)}%"),
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " ASC")?.use { cursor ->
                while (cursor.moveToNext() && result.size < 10) {
                    result += cursor.getString(0).orEmpty() to cursor.getString(1).orEmpty()
                }
            }
        }
        result
        }
    }
    if (contacts.isEmpty()) Text("Eşleşen kişi bulunamadı.", color = WiqoDesign.colors.ink, fontSize = 13.sp)
    contacts.forEach { (name, number) ->
        Link("$name · $number") {
            runCatching { context.startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(number)}"))) }
        }
    }
}

@Composable
private fun WidgetChecklist(items: JsonArray?) {
    val checked = remember(items) { mutableStateListOf<Int>() }
    items.orEmpty().take(20).forEachIndexed { index, item ->
        val title = (item as? JsonPrimitive)?.contentOrNull ?: return@forEachIndexed
        Text("${if (index in checked) "☑" else "□"} $title", Modifier.clickable {
            if (index in checked) checked.remove(index) else checked.add(index)
        }, color = WiqoDesign.colors.ink, fontSize = 13.sp)
    }
}

private fun isSafeWebUrl(raw: String): Boolean = runCatching {
    val uri = Uri.parse(raw)
    uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank()
}.getOrDefault(false)

private fun openLink(context: Context, raw: String) {
    if (!isSafeWebUrl(raw)) return
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(raw))) }
}

@Composable
private fun Rows(items: JsonArray?) {
    val color = WiqoDesign.colors.ink
    items.orEmpty().take(12).forEach { item ->
        val row = item as? JsonObject ?: return@forEach
        Text("• ${row.text("title").orEmpty()} ${row.text("subtitle").orEmpty()}".trim().take(250), color = color, fontSize = 13.sp)
    }
}

@Composable
private fun Link(label: String, onClick: () -> Unit) {
    Text(label, Modifier.clickable(onClick = onClick).padding(vertical = 4.dp), color = WiqoDesign.colors.blue, fontWeight = FontWeight.SemiBold)
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun InlineApp(widget: JsonObject, accountId: String?, onOpenRelated: (String, String?) -> Unit) {
    val html = widget.text("html")?.takeIf { it.length <= 60_000 } ?: return
    val data = widget.text("data")?.takeIf { it.length <= 20_000 } ?: "null"
    val context = LocalContext.current
    val stateKey = "${accountId.orEmpty()}:${widget.text("stateKey") ?: widget.text("widgetId") ?: widget.text("title").orEmpty()}".take(200)
    val bridge = remember(stateKey) { InlineBridge(context.applicationContext, stateKey, onOpenRelated) }
    val source = remember(html, data, stateKey) {
        val state = bridge.state()
        val parsedData = runCatching { kotlinx.serialization.json.Json.parseToJsonElement(data) }.getOrNull()?.toString() ?: "null"
        val requested = (widget["libs"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.toSet()
        val ordered = listOf("core") + listOf("chart", "confetti", "templates").filter { it in requested || (it == "chart" && "templates" in requested) }
        val scripts = ordered.joinToString("") { name ->
            val code = runCatching { context.assets.open("inline/$name.js").bufferedReader().use { it.readText() } }.getOrDefault("")
            "<script>$code</script>"
        }
        val header = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; form-action 'none'; frame-src 'none'; base-uri 'none'\"><script>window.__WIQO_STATE__=$state;window.__WIQO_DATA__=$parsedData;</script>$scripts"
        val head = Regex("<head[^>]*>", RegexOption.IGNORE_CASE).find(html)
        if (head != null) html.replaceRange(head.range, head.value + header)
        else "<!doctype html><html><head>$header</head><body>$html</body></html>"
    }
    AndroidView(
        modifier = Modifier.fillMaxWidth().height(((widget.text("height")?.toIntOrNull() ?: 260).coerceIn(120, 600)).dp),
        factory = {
            WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = false
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.javaScriptCanOpenWindowsAutomatically = false
                settings.setSupportMultipleWindows(false)
                addJavascriptInterface(bridge, "WiqoAndroid")
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = true
                    override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                        val scheme = request?.url?.scheme
                        return if (scheme == "data" || scheme == "blob") null
                        else WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
                    }
                }
                tag = source
                loadDataWithBaseURL(null, source, "text/html", "UTF-8", null)
            }
        },
        update = { view -> if (view.tag != source) { view.tag = source; view.loadDataWithBaseURL(null, source, "text/html", "UTF-8", null) } },
        onRelease = { it.removeJavascriptInterface("WiqoAndroid"); it.destroy() },
    )
}

private class InlineBridge(
    private val context: Context,
    private val stateKey: String,
    private val onOpenRelated: (String, String?) -> Unit,
) {
    private val preferences = context.getSharedPreferences("wiqo_inline_state", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private var lastAction = 0L

    @Synchronized fun state(): String {
        val prefix = "$stateKey:"
        val entries = preferences.all.filterKeys { it.startsWith(prefix) }.entries.take(32)
        return buildJsonObject { entries.forEach { (key, value) ->
            (value as? String)?.let { put(key.removePrefix(prefix), it) }
        } }.toString()
    }

    @JavascriptInterface fun post(raw: String) {
        if (raw.length > 22_000) return
        val value = runCatching { kotlinx.serialization.json.Json.parseToJsonElement(raw) as? JsonObject }.getOrNull() ?: return
        val save = value["save"] as? JsonObject
        if (save != null) {
            val key = save.text("k")?.takeIf { it.length in 1..40 && ':' !in it } ?: return
            val text = save.text("v")?.takeIf { it.length <= 2_000 } ?: return
            synchronized(this) {
                val existing = preferences.all.filterKeys { it.startsWith("$stateKey:") }
                if (key !in existing.keys.map { it.removePrefix("$stateKey:") } && existing.size >= 32) return
                val priorLength = (existing["$stateKey:$key"] as? String)?.length ?: 0
                if (existing.values.sumOf { (it as? String)?.length ?: 0 } - priorLength + text.length > 8_000) return
                preferences.edit().putString("$stateKey:$key", text).apply()
            }
            return
        }
        if (value.text("copy") == null && value.text("share") == null && value.text("ask") == null) return
        val now = System.currentTimeMillis()
        synchronized(this) { if (now - lastAction < 1_000) return else lastAction = now }
        value.text("copy")?.take(20_000)?.let { text ->
            main.post { (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                .setPrimaryClip(ClipData.newPlainText("Wiqo", text)) }; return
        }
        value.text("share")?.take(20_000)?.let { text ->
            main.post { runCatching { context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND)
                .setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), "Paylaş").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }; return
        }
        value.text("ask")?.trim()?.take(500)?.takeIf(String::isNotEmpty)?.let { text ->
            main.post { onOpenRelated("inline-ask", text) }; return
        }
    }
}

private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
