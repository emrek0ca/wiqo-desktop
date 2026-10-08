package com.wiqo.android.data.act

import android.content.Context
import com.wiqo.android.data.network.ApiException
import com.wiqo.android.data.network.WiqoApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import java.util.UUID

class ActRepository(context: Context, private val api: WiqoApi) {
    val local = ActProjectStore(context, api)
    val vaults = ActVaultStore(context, api)
    val packages = ActPackages(context, api)
    private val verifier = ActWebVerifier(context.applicationContext)
    var inaccessibleProjects: Int = 0
        private set
    var lastVerificationNote: String? = null
        private set

    private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
    private fun JsonObject.number(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
    private fun objectAt(value: JsonElement?): JsonObject? = value as? JsonObject
    private fun arrayAt(value: JsonElement?): JsonArray = value as? JsonArray ?: JsonArray(emptyList())

    suspend fun createLocal(name: String, kind: String, mode: String, files: Map<String, String>): ActProject {
        require(name.trim().isNotEmpty() && name.length <= 60) { "Proje adı 1–60 karakter olmalı." }
        require(mode in listOf("deviceOnly", "devices"))
        require(kind in listOf("web", "python"))
        val project = ActProject(name = name.trim(), kind = kind, mode = mode, files = files)
        return local.save(ActProjectStore.edited(project.copy(files = emptyMap()), files, "Proje oluşturuldu", "Oluşturma"))
    }

    suspend fun saveFiles(id: String, files: Map<String, String>, summary: String): ActProject {
        val project = local.get(id) ?: throw IllegalStateException("Proje bulunamadı.")
        return local.save(ActProjectStore.edited(project, files, summary))
    }

    suspend fun undo(id: String): ActProject {
        val project = local.get(id) ?: throw IllegalStateException("Proje bulunamadı.")
        require(project.history.size >= 2) { "Geri alınacak değişiklik yok." }
        val last = project.history.firstOrNull() ?: return project
        val files = project.files.toMutableMap()
        last.changes.forEach { change -> if (change.before == null) files.remove(change.path) else files[change.path] = change.before }
        return local.save(ActProjectStore.edited(project, files, "Geri alındı: ${last.summary}", "Geri alma"))
    }

    suspend fun restore(id: String, historyId: String): ActProject {
        val project = local.get(id) ?: throw IllegalStateException("Proje bulunamadı.")
        val index = project.history.indexOfFirst { it.id == historyId }
        require(index > 0) { "Bu sürüme dönülemiyor." }
        val files = project.files.toMutableMap()
        project.history.take(index).forEach { entry ->
            entry.changes.forEach { change ->
                if (change.before == null) files.remove(change.path) else files[change.path] = change.before
            }
        }
        return local.save(ActProjectStore.edited(project, files, "Sürüme dönüldü: ${project.history[index].summary}", "Geri yükleme"))
    }

    suspend fun resolveConflict(id: String, copyPath: String, useCopy: Boolean): ActProject {
        val project = local.get(id) ?: throw IllegalStateException("Proje bulunamadı.")
        val pattern = Regex(" - Android kopyası(?: [0-9]+)?(?=\\.[^./]+$|$)")
        require(pattern.containsMatchIn(copyPath)) { "Çakışma kopyası bulunamadı." }
        val original = copyPath.replace(pattern, "")
        val copy = project.files[copyPath] ?: throw IllegalStateException("Çakışma kopyası bulunamadı.")
        val files = project.files.toMutableMap()
        if (useCopy) files[original] = copy
        files.remove(copyPath)
        return local.save(ActProjectStore.edited(project, files, if (useCopy) "$original için Android kopyası seçildi" else "$copyPath silindi", "Çakışma"))
    }

    suspend fun duplicate(id: String): ActProject {
        val source = local.get(id) ?: throw IllegalStateException("Proje bulunamadı.")
        return createLocal((source.name + " kopyası").take(60), source.kind, source.mode, source.files)
    }

    suspend fun delete(id: String) {
        val project = local.get(id) ?: return
        if (project.mode == "devices" && project.hubId != null) api.delete("code-sync/projects/${project.hubId}")
        local.delete(id)
    }

    suspend fun changeMode(id: String, mode: String): ActProject {
        val p = local.get(id) ?: throw IllegalStateException("Proje bulunamadı.")
        require(mode in listOf("deviceOnly", "devices"))
        if (p.mode == mode) return p
        if (mode == "deviceOnly" && p.hubId != null) api.delete("code-sync/projects/${p.hubId}")
        return local.save(p.copy(mode = mode, hubId = if (mode == "deviceOnly") null else p.hubId,
            version = if (mode == "deviceOnly") 0 else p.version,
            base = if (mode == "deviceOnly") emptyMap() else p.base))
    }

    suspend fun readyPage(project: ActProject): String {
        val raw = ActBundler.page(project) ?: throw IllegalStateException("Projede açılacak HTML sayfası yok.")
        return packages.inlineVerified(raw)
    }

    suspend fun handOff(id: String, action: String, onProgress: (String) -> Unit): String {
        require(action in listOf("open_folder", "open_editor", "open_preview", "run"))
        val project = sync(id)
        val hubId = project.hubId ?: throw IllegalStateException("Projeyi PC'ye göndermek için şifreli senkronu aç.")
        val started = objectAt(api.post("code-sync/projects/$hubId/pc-tasks", buildJsonObject { put("action", action) }))
            ?: throw IllegalStateException("PC görevi başlatılamadı.")
        val taskId = started.number("id") ?: throw IllegalStateException("PC görev kimliği eksik.")
        repeat(40) {
            delay(2000)
            val task = objectAt(api.get("code-sync/pc-tasks/$taskId")) ?: throw IllegalStateException("PC sonucu okunamadı.")
            when (task.text("status")) {
                "done" -> return task.text("output").orEmpty().ifBlank { "PC işlemi tamamlandı." }
                "failed" -> throw IllegalStateException(task.text("output").orEmpty().ifBlank { "PC işlemi başarısız." })
                else -> onProgress("PC'nin yanıtı bekleniyor…")
            }
        }
        throw IllegalStateException("PC yanıt vermedi; açık ve internete bağlı mı?")
    }

    /** Pull before push. Local divergent edits become named conflict copies, never overwritten. */
    suspend fun sync(id: String): ActProject {
        var project = local.get(id) ?: throw IllegalStateException("Proje bulunamadı.")
        if (project.mode != "devices") return project
        val vault = vaults.loadOrCreate()
        if (project.hubId == null) {
            if (project.files.isEmpty()) return project
            val meta = vault.seal(buildJsonObject { put("name", project.name); put("kind", project.kind) }.toString())
            val created = objectAt(api.post("code-sync/projects", buildJsonObject { put("meta", meta) }))
                ?: throw IllegalStateException("Proje sunucuya açılamadı.")
            val hubId = created.number("id") ?: throw IllegalStateException("Sunucudan proje kimliği gelmedi.")
            project = local.save(project.copy(hubId = hubId))
        }
        repeat(3) { attempt ->
            project = mergeSnapshot(project, vault)
            val updates = ((project.base.keys + project.files.keys).distinct().sorted()).mapNotNull { path ->
                val content = project.files[path]
                val hash = content?.let { vault.contentHash(path, it) }
                if (project.base[path] == hash) null else buildJsonObject {
                    put("p", vault.pathToken(path))
                    put("b", vault.seal(buildJsonObject { put("path", path); if (content == null) put("content", kotlinx.serialization.json.JsonNull) else put("content", content) }.toString()))
                    if (hash == null) put("h", kotlinx.serialization.json.JsonNull) else put("h", hash)
                    put("d", content == null)
                }
            }
            if (updates.isEmpty()) return project
            try {
                val response = objectAt(api.post("code-sync/projects/${project.hubId}/push", buildJsonObject {
                    put("baseVersion", project.version)
                    put("summary", vault.seal("{\"text\":\"Android değişikliği\"}"))
                    put("device", "Android")
                    put("changes", buildJsonArray { updates.forEach(::add) })
                })) ?: throw IllegalStateException("Senkron yanıtı okunamadı.")
                if (response.text("ok") != "true") throw IllegalStateException("Değişiklikler eşitlenemedi.")
                val newBase = project.files.mapValues { (path, content) -> vault.contentHash(path, content) }
                project = local.save(project.copy(version = response.number("version") ?: project.version, base = newBase))
                // A merged push may have independent changes newer than this device's base.
                if (response.text("merged") == "true") project = mergeSnapshot(project, vault)
                return project
            } catch (error: ApiException) {
                if (error.statusCode != 409 || attempt == 2) throw error
            }
        }
        return project
    }

    private suspend fun mergeSnapshot(project: ActProject, vault: ActVault): ActProject {
        val snapshot = objectAt(api.get("code-sync/projects/${project.hubId}/snapshot"))
            ?: throw IllegalStateException("Proje kopyası alınamadı.")
        val remote = linkedMapOf<String, String>()
        val hashes = linkedMapOf<String, String>()
        for (item in arrayAt(snapshot["files"])) {
            val row = item as? JsonObject ?: throw IllegalStateException("Şifreli dosya geçersiz.")
            val blob = row.text("b") ?: throw IllegalStateException("Şifreli dosya eksik.")
            val envelope = objectAt(kotlinx.serialization.json.Json.parseToJsonElement(vault.open(blob)
                ?: throw IllegalStateException("Proje anahtarı eşleşmiyor."))) ?: throw IllegalStateException("Dosya açılmadı.")
            val path = envelope.text("path") ?: throw IllegalStateException("Dosya yolu eksik.")
            val content = envelope.text("content") ?: throw IllegalStateException("Dosya içeriği eksik.")
            if (!ActProjectRules.valid(path, content) || row.text("p") != vault.pathToken(path) || row.text("h") != vault.contentHash(path, content) || remote.containsKey(path)) {
                throw IllegalStateException("Şifreli proje doğrulanamadı.")
            }
            remote[path] = content
            hashes[path] = vault.contentHash(path, content)
        }
        val files = project.files.toMutableMap()
        val conflicts = mutableListOf<String>()
        for (path in (project.base.keys + remote.keys + files.keys).distinct()) {
            val old = project.base[path]
            val theirs = hashes[path]
            val mine = files[path]?.let { vault.contentHash(path, it) }
            val theirsChanged = theirs != old
            val mineChanged = mine != old
            if (!theirsChanged) continue
            if (mineChanged && mine != theirs && files[path] != null) {
                val ext = path.substringAfterLast('.', "")
                val stem = path.removeSuffix(if (ext.isEmpty()) "" else ".$ext")
                var copy = "$stem - Android kopyası${if (ext.isEmpty()) "" else ".$ext"}"
                var count = 2
                while (files.containsKey(copy) || remote.containsKey(copy)) {
                    copy = "$stem - Android kopyası $count${if (ext.isEmpty()) "" else ".$ext"}"
                    count++
                }
                val content = files[path]!!
                if (ActProjectRules.valid(copy, content) && files.size < 40) { files[copy] = content; conflicts.add(copy) }
                else throw IllegalStateException("Çakışma kopyası kaydedilemedi; yerel dosya korundu.")
            }
            if (theirs == null) files.remove(path) else files[path] = remote.getValue(path)
        }
        val changed = ActProjectStore.changes(project.files, files)
        val history = if (changed.isEmpty()) project.history else
            (listOf(ActHistory(summary = if (conflicts.isEmpty()) "Başka cihazdan gelen değişiklik" else "Çakışma kopyası kaydedildi",
                source = "Başka cihaz", changes = changed)) + project.history).take(30)
        return local.save(project.copy(files = files, history = history, version = snapshot.number("version") ?: project.version, base = hashes))
    }

    suspend fun syncAll(): List<ActProject> {
        val vault = vaults.loadOrCreate()
        val remote = objectAt(api.get("code-sync/projects")) ?: throw IllegalStateException("Proje listesi alınamadı.")
        inaccessibleProjects = 0
        var localList = local.all()
        val known = localList.mapNotNull { it.hubId }.toSet()
        val remoteIds = mutableSetOf<Int>()
        for (item in arrayAt(remote["projects"])) {
            val row = item as? JsonObject ?: continue
            val id = row.number("id") ?: continue
            remoteIds.add(id)
            if (id in known || (row.number("version") ?: 0) < 1) continue
            val meta = row.text("meta")?.let(vault::open)?.let { runCatching {
                kotlinx.serialization.json.Json.parseToJsonElement(it) as? JsonObject
            }.getOrNull() }
            if (meta == null) { inaccessibleProjects++; continue }
            val name = meta.text("name") ?: continue
            val kind = meta.text("kind") ?: continue
            val created = ActProject(name = name, kind = kind, mode = "devices", files = emptyMap(), hubId = id)
            val saved = local.save(created)
            try { mergeSnapshot(saved, vault) } catch (error: Exception) { local.delete(saved.id); throw error }
        }
        localList = local.all()
        // The authenticated hub list is authoritative for previously synced projects.
        // A deletion on another device must not silently recreate the deleted project.
        for (project in localList.filter { it.mode == "devices" && it.hubId != null && it.hubId !in remoteIds }) {
            local.delete(project.id)
        }
        localList = local.all()
        for (project in localList.filter { it.mode == "devices" }) sync(project.id)
        return local.all()
    }

    data class WriterState(val id: String, val status: String, val progress: String, val result: JsonObject?, val error: String?)

    suspend fun startWriter(operation: String, request: String, project: ActProject?, errors: List<String> = emptyList()): String {
        require(operation in listOf("create", "edit", "explain", "review"))
        require(request.trim().length in (if (operation == "create") 3 else 2)..1200) { "İstek 2–1200 karakter olmalı." }
        val files = project?.files.orEmpty()
        require(files.size <= 40 && files.all { (path, content) -> ActProjectRules.valid(path, content) }) { "Proje dosyaları yazıcı sınırını aşıyor." }
        val body = buildJsonObject {
            put("operation", operation); put("request", request.trim()); put("kind", project?.kind ?: "web")
            project?.name?.let { put("name", it) }
            put("files", buildJsonArray { files.toSortedMap().forEach { (path, content) -> add(buildJsonObject { put("path", path); put("content", content) }) } })
            if (errors.isNotEmpty()) put("errors", buildJsonArray {
                errors.take(20).forEach { message -> add(buildJsonObject { put("level", "error"); put("text", message.take(1000)) }) }
            })
        }
        val response = objectAt(api.post("code-sync/writer/jobs", body))
        return response?.text("jobId") ?: throw IllegalStateException("Yazıcı görevi başlatılamadı.")
    }

    suspend fun writerState(id: String): WriterState {
        require(id.matches(Regex("[A-Za-z0-9._:-]{8,128}")))
        val result = objectAt(api.get("code-sync/writer/jobs/$id")) ?: throw IllegalStateException("Yazıcı yanıtı okunamadı.")
        return WriterState(id, result.text("status") ?: "unknown", result.text("progress").orEmpty(), objectAt(result["result"]), result.text("error"))
    }

    suspend fun awaitWriter(id: String, onProgress: (String) -> Unit): WriterState {
        repeat(150) {
            val state = writerState(id)
            onProgress(if (state.status == "queued") "Sırada" else state.progress.ifEmpty { "Kod yazılıyor" })
            if (state.status in listOf("done", "failed", "cancelled")) {
                acknowledgeWriter(id)
                return state
            }
            delay(1500)
        }
        throw IllegalStateException("Görev beklenenden uzun sürdü; sonucu daha sonra kontrol et.")
    }

    suspend fun cancelWriter(id: String) { api.post("code-sync/writer/jobs/$id/cancel", buildJsonObject {}) }
    suspend fun acknowledgeWriter(id: String) { try { api.delete("code-sync/writer/jobs/$id") } catch (_: Exception) {} }

    suspend fun commitWriter(result: JsonObject, project: ActProject?, request: String, mode: String): ActProject {
        if (result.text("ok") != "true") throw IllegalStateException("Kod üretilemedi.")
        val files = project?.files?.toMutableMap() ?: linkedMapOf()
        for (item in arrayAt(result["changes"])) {
            val row = item as? JsonObject ?: throw IllegalStateException("Kod değişikliği geçersiz.")
            val path = row.text("path") ?: throw IllegalStateException("Dosya yolu eksik.")
            val after = row.text("after")
            if (after == null) files.remove(path) else {
                require(ActProjectRules.valid(path, after)) { "Üretilen dosya sınırı aşıyor: $path" }
                files[path] = after
            }
        }
        require(files.isNotEmpty() && files.size <= 40) { "Üretilen projede dosya yok veya sınır aşıldı." }
        val summary = result.text("summary").orEmpty().ifBlank { request.take(80) }
        val note = "- ${summary.replace('\n', ' ').take(140)}"
        val existingNote = files["PROJE.md"]
        files["PROJE.md"] = if (existingNote == null) "# ${project?.name ?: result.text("name") ?: "Proje"}\n\n## Kararlar ve değişiklikler\n$note"
        else (existingNote.lines() + note).takeLast(35).joinToString("\n")
        var verified = result.text("needsDeviceCheck") != "true"
        lastVerificationNote = null
        if (!verified && result.text("kind") != "python") {
            val candidate = ActProject(name = project?.name ?: result.text("name") ?: "Proje", kind = "web", files = files)
            val ready = runCatching { readyPage(candidate) }
            if (ready.isFailure) {
                lastVerificationNote = "Paket eksik veya sayfa hazırlanamadı; proje kaydedildi ama doğrulanmadı."
            } else {
                val checked = verifier.verify(ready.getOrThrow())
                if (checked.available && !checked.passed) {
                    throw IllegalStateException(checked.errors.firstOrNull() ?: "Sayfa doğrulanamadı; proje değişmedi.")
                }
                verified = checked.passed
                if (!checked.available) lastVerificationNote = "Sayfa telefonda denenemedi; değişiklik doğrulanmadan kaydedildi."
            }
        }
        return if (project == null) {
            val created = ActProject(name = (result.text("name") ?: "Proje").take(60),
                kind = result.text("kind") ?: "web", mode = mode, files = emptyMap())
            local.save(ActProjectStore.edited(created, files, summary, "Wiqo", verified))
        } else local.save(ActProjectStore.edited(project, files, summary, "Wiqo", verified))
    }
}
