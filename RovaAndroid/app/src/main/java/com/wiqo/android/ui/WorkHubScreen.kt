package com.wiqo.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.wiqo.android.AppContainer
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

/** Ayarlar > Görevler: the same six backend-owned work lists shown in iOS. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun WorkHubScreen(container: AppContainer, onBack: () -> Unit, onOpenRelated: (String, String?) -> Unit) {
    val scope = rememberCoroutineScope()
    var refresh by remember { mutableStateOf(0) }
    var loaded by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var tasks by remember { mutableStateOf(emptyList<JsonObject>()) }
    var todos by remember { mutableStateOf(emptyList<JsonObject>()) }
    var automations by remember { mutableStateOf(emptyList<JsonObject>()) }
    var review by remember { mutableStateOf(emptyList<JsonObject>()) }
    var agents by remember { mutableStateOf(emptyList<JsonObject>()) }
    var budget by remember { mutableStateOf<JsonObject?>(null) }
    var pending by remember { mutableStateOf<HubAction?>(null) }

    LaunchedEffect(refresh, container.api.currentAccountId()) {
        coroutineScope {
            val taskFetch = async { runCatching { container.api.get("agent-tasks").objects("tasks") } }
            val todoFetch = async { runCatching { container.api.get("tasks").objects("tasks") } }
            val automationFetch = async { runCatching { container.api.get("automations").objects("automations") } }
            val reviewFetch = async { runCatching { container.api.get("automations/review").objects("items") } }
            val agentFetch = async { runCatching { container.api.get("agents").objects("agents") } }
            val budgetFetch = async { runCatching { container.api.get("agents/budget") as? JsonObject } }
            val results = listOf(taskFetch.await(), todoFetch.await(), automationFetch.await(), reviewFetch.await(), agentFetch.await())
            results[0].getOrNull()?.let { tasks = it }
            results[1].getOrNull()?.let { todos = it }
            results[2].getOrNull()?.let { automations = it.filter { row -> row.text("isActive") == "true" || row.text("lifecycleStatus") == "paused" } }
            results[3].getOrNull()?.let { review = it }
            results[4].getOrNull()?.let { agents = it }
            budgetFetch.await().getOrNull()?.let { budget = it }
            if (results[0].isFailure && results[2].isFailure && results[4].isFailure) error = "Görevler yüklenemedi. Bağlantıyı kontrol et."
            loaded = true
        }
    }

    fun execute(action: HubAction) {
        if (busy) return
        scope.launch {
            busy = true; error = null
            try {
                when (action.method) {
                    "DELETE" -> container.api.delete(action.path)
                    "PUT" -> container.api.put(action.path, action.body ?: JsonObject(emptyMap()))
                    else -> container.api.post(action.path, action.body ?: JsonObject(emptyMap()))
                }
                if (action.path.startsWith("automations/")) runCatching { container.reminders.reconcile() }
                refresh += 1
            } catch (cause: Exception) { error = cause.message ?: "İşlem tamamlanamadı." }
            finally { busy = false }
        }
    }

    Scaffold(topBar = { TopAppBar(title = { Text("Görevler") }, navigationIcon = {
        TextButton(onClick = onBack) { Text("Geri") }
    }, actions = { TextButton(onClick = { refresh += 1 }, enabled = !busy) { Text("Yenile") } }) }) { insets ->
        Column(Modifier.fillMaxSize().padding(insets).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (!loaded) CircularProgressIndicator()
            if (loaded && review.isEmpty() && tasks.none { it.text("status") in setOf("pending", "running", "waiting") } &&
                todos.none { it.text("status") == "pending" } && automations.isEmpty() && agents.isEmpty()) {
                Text("Şu an bir iş yok. Wiqo’dan bir iş iste veya zamanlı görev oluştur.")
            }
            if (review.isNotEmpty()) {
                HubHeading("Bakman gerekenler", review.size)
                review.forEach { item ->
                    val aid = item.text("automationId")?.takeIf(::numericId)
                    val rid = item.text("runId")?.takeIf(::numericId)
                    HubRow(item.text("title") ?: "Çalıştırma", item.text("error") ?: item.text("reply") ?: item.text("status")) {
                        if (aid != null && rid != null) onOpenRelated("automation-run", "$aid/runs/$rid/journal")
                    }
                    if (aid != null && rid != null) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (item.text("status") == "needs_attention") {
                            TextButton(enabled = !busy, onClick = { pending = HubAction("Tamamlandı olarak kaydet", "automations/$aid/runs/$rid/resolve-unknown", body = buildJsonObject { put("resolution", "completed") }, confirm = true) }) { Text("Tamamlandı") }
                            TextButton(enabled = !busy, onClick = { pending = HubAction("Başarısız olarak kaydet", "automations/$aid/runs/$rid/resolve-unknown", body = buildJsonObject { put("resolution", "failed") }, confirm = true) }) { Text("Başarısız") }
                        } else TextButton(enabled = !busy, onClick = { pending = HubAction("Tekrar dene", "automations/$aid/runs/$rid/retry", confirm = true) }) { Text("Tekrar dene") }
                    }
                }
            }
            val running = tasks.filter { it.text("status") in setOf("pending", "running", "waiting") }
            if (running.isNotEmpty()) {
                HubHeading("Çalışıyor", running.size)
                running.forEach { task ->
                    val id = task.text("id")?.takeIf(::numericId)
                    HubRow(task.text("title") ?: "Ajan görevi", task.text("progress") ?: task.text("status")) {
                        if (id != null) onOpenRelated("agent-task-detail", id)
                    }
                    if (id != null) TextButton(enabled = !busy, onClick = { pending = HubAction("Görevi durdur", "agent-tasks/$id/cancel", confirm = true) }) { Text("Durdur") }
                }
            }
            val openTodos = todos.filter { it.text("status") == "pending" }
            if (openTodos.isNotEmpty()) {
                HubHeading("Yapılacaklar", openTodos.size)
                openTodos.forEach { todo ->
                    val id = todo.text("id")?.takeIf(::numericId)
                    HubRow(todo.text("title") ?: "Görev", null) {}
                    if (id != null) TextButton(enabled = !busy, onClick = { execute(HubAction("Tamamla", "tasks/$id/complete")) }) { Text("Tamamla") }
                }
            }
            if (automations.isNotEmpty()) {
                HubHeading("Zamanlanmış", automations.size)
                automations.forEach { automation ->
                    val id = automation.text("id")?.takeIf(::numericId)
                    val active = automation.text("isActive") == "true"
                    HubRow(automation.text("prompt") ?: "Otomasyon", automation.text("scheduleLabel") ?: automation.text("cron")) {
                        if (id != null) onOpenRelated("automation-detail", id)
                    }
                    if (id != null) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(enabled = !busy, onClick = { execute(HubAction(if (active) "Duraklat" else "Sürdür", "automations/$id/${if (active) "pause" else "resume"}")) }) { Text(if (active) "Duraklat" else "Sürdür") }
                        TextButton(enabled = active && !busy, onClick = { execute(HubAction("Şimdi çalıştır", "automations/$id/run-now")) }) { Text("Şimdi çalıştır") }
                        TextButton(enabled = !busy, onClick = { pending = HubAction("Otomasyonu sil", "automations/$id", "DELETE", confirm = true) }) { Text("Sil") }
                    }
                }
            }
            if (agents.isNotEmpty()) {
                HubHeading("Ajanlarım", agents.size)
                agents.forEach { agent ->
                    val id = agent.text("id")?.takeIf(::numericId)
                    HubRow(agent.text("name") ?: "Ajan", agent.text("role")) { onOpenRelated("agents", id) }
                    if (id != null && agent.text("isPrimary") != "true") TextButton(enabled = !busy,
                        onClick = { pending = HubAction("Ajanı sil", "agents/$id", "DELETE", confirm = true) }) { Text("Sil") }
                }
            }
            budget?.let { row ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column { Text("Kendi başına çalış", style = MaterialTheme.typography.titleMedium)
                        Text(if (row.text("paused") == "true") "Duraklatıldı" else "İzleme ve rutinler açık") }
                    Switch(checked = row.text("paused") != "true", enabled = !busy, onCheckedChange = { value ->
                        execute(HubAction("Çalışmayı değiştir", "agents/pause", "PUT", buildJsonObject { put("paused", !value) }))
                    })
                }
            }
        }
    }
    pending?.let { action ->
        AlertDialog(onDismissRequest = { pending = null }, title = { Text(action.title) },
            text = { Text("Bu işlemi onaylıyor musun?") },
            confirmButton = { Button(onClick = { pending = null; execute(action) }) { Text("Onayla") } },
            dismissButton = { OutlinedButton(onClick = { pending = null }) { Text("Vazgeç") } })
    }
}

private data class HubAction(val title: String, val path: String, val method: String = "POST",
    val body: JsonObject? = null, val confirm: Boolean = false)

@Composable private fun HubHeading(title: String, count: Int) {
    Text("$title · $count", style = MaterialTheme.typography.titleMedium)
}

@Composable private fun HubRow(title: String, subtitle: String?, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 8.dp)) {
        Text(title, style = MaterialTheme.typography.bodyLarge)
        subtitle?.takeIf(String::isNotBlank)?.let { Text(it.take(220), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

private fun kotlinx.serialization.json.JsonElement?.objects(key: String): List<JsonObject> =
    (((this as? JsonObject)?.get(key)) as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
private fun numericId(value: String): Boolean = value.matches(Regex("[0-9]{1,18}"))
