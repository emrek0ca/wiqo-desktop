package com.wiqo.android.data.act

import android.content.Context
import android.util.AtomicFile
import com.wiqo.android.data.network.WiqoApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.security.MessageDigest
import java.util.UUID

@Serializable
data class ActChange(val path: String, val before: String? = null, val after: String? = null)

@Serializable
data class ActHistory(
    val id: String = UUID.randomUUID().toString(),
    val summary: String,
    val at: Long = System.currentTimeMillis(),
    val verified: Boolean = true,
    val source: String,
    val changes: List<ActChange>,
)

@Serializable
data class ActProject(
    val id: String = UUID.randomUUID().toString(),
    val mode: String = "deviceOnly",
    val name: String,
    val kind: String = "web",
    val files: Map<String, String>,
    val history: List<ActHistory> = emptyList(),
    val hubId: Int? = null,
    val version: Int = 0,
    val base: Map<String, String> = emptyMap(),
    val updatedAt: Long = System.currentTimeMillis(),
)

/** The full project stays in app-private storage, scoped to the signed-in account. */
class ActProjectStore(context: Context, private val api: WiqoApi) {
    private val appContext = context.applicationContext
    private val json = Json { ignoreUnknownKeys = true }

    private fun directory(): File {
        val user = api.currentAccountId() ?: throw IllegalStateException("Act için oturum aç.")
        val name = MessageDigest.getInstance("SHA-256").digest(user.toByteArray()).joinToString("") { "%02x".format(it) }.take(24)
        return File(appContext.filesDir, "act-projects-v2/$name").also { check(it.isDirectory || it.mkdirs()) }
    }

    private fun file(id: String): File {
        require(runCatching { UUID.fromString(id) }.isSuccess) { "Geçersiz proje kimliği." }
        return File(directory(), "$id.json")
    }

    suspend fun all(): List<ActProject> = withContext(Dispatchers.IO) {
        directory().listFiles().orEmpty().filter { it.name.endsWith(".json") }.mapNotNull {
            runCatching { json.decodeFromString<ActProject>(it.readText()) }.getOrNull()
        }.sortedByDescending { it.updatedAt }
    }

    suspend fun get(id: String): ActProject? = withContext(Dispatchers.IO) {
        val target = file(id)
        if (!target.exists()) null else runCatching { json.decodeFromString<ActProject>(target.readText()) }.getOrNull()
    }

    suspend fun save(project: ActProject): ActProject = withContext(Dispatchers.IO) {
        require(project.files.size <= 40) { "En fazla 40 dosya olabilir." }
        project.files.forEach { (path, content) -> require(ActProjectRules.valid(path, content)) { "Dosya sınırı aşıldı: $path" } }
        val stored = project.copy(updatedAt = System.currentTimeMillis())
        val atomic = AtomicFile(file(stored.id))
        val bytes = json.encodeToString(ActProject.serializer(), stored).toByteArray()
        val output = atomic.startWrite()
        try {
            output.write(bytes)
            atomic.finishWrite(output)
        } catch (error: Exception) {
            atomic.failWrite(output)
            throw error
        }
        stored
    }

    suspend fun delete(id: String) = withContext(Dispatchers.IO) {
        check(!file(id).exists() || file(id).delete()) { "Proje silinemedi." }
    }

    companion object {
        fun changes(before: Map<String, String>, after: Map<String, String>): List<ActChange> =
            (before.keys + after.keys).distinct().sorted().mapNotNull { path ->
                if (before[path] == after[path]) null else ActChange(path, before[path], after[path])
            }

        fun edited(project: ActProject, files: Map<String, String>, summary: String, source: String = "Elle düzenleme", verified: Boolean = true): ActProject {
            val diff = changes(project.files, files)
            return if (diff.isEmpty()) project else project.copy(
                files = files,
                history = (listOf(ActHistory(summary = summary.take(140), source = source, verified = verified, changes = diff)) + project.history).take(30),
            )
        }
    }
}

object ActProjectRules {
    private val extensions = setOf("html", "htm", "css", "js", "json", "txt", "md", "py", "svg", "csv")
    fun valid(path: String, content: String): Boolean {
        val parts = path.split('/')
        return parts.size in 1..4 && parts.all { it.isNotBlank() && !it.startsWith('.') && it != ".." } &&
            !path.contains('\\') && !path.contains('\u0000') && path.length <= 80 &&
            path.substringAfterLast('.', "").lowercase() in extensions && content.toByteArray().size <= 100 * 1024
    }
}
