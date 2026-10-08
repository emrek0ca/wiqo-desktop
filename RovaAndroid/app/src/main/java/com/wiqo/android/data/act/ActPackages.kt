package com.wiqo.android.data.act

import android.content.Context
import android.util.AtomicFile
import android.util.Base64
import com.wiqo.android.data.network.WiqoApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayInputStream
import java.io.File
import java.security.MessageDigest
import java.util.zip.GZIPInputStream

/** Verified public JavaScript packages, compatible with iOS ActPackages catalog and paths. */
class ActPackages(context: Context, private val api: WiqoApi) {
    private val directory = File(context.applicationContext.filesDir, "act-packages-v1").also { it.mkdirs() }
    private val http = OkHttpClient.Builder().followRedirects(false).build()
    private val tag = Regex("<script\\b[^>]*\\bsrc\\s*=\\s*['\"](?:\\./)?(act-vendor/[^'\"]+)['\"][^>]*>\\s*</script\\s*>", RegexOption.IGNORE_CASE)

    fun referencedPaths(html: String): List<String> = tag.findAll(html).map { it.groupValues[1] }.distinct().toList()

    suspend fun inlineVerified(html: String): String = withContext(Dispatchers.IO) {
        val paths = referencedPaths(html)
        if (paths.isEmpty()) return@withContext html
        val catalog = runCatching { api.get("code-sync/packages") as? JsonObject }.getOrNull()
            ?.also { save(File(directory, "catalog.json"), it.toString().toByteArray()) }
            ?: runCatching { kotlinx.serialization.json.Json.parseToJsonElement(File(directory, "catalog.json").readText()) as? JsonObject }.getOrNull()
            ?: throw IllegalStateException("Act paket listesi alınamadı; sayfa doğrulanamadı.")
        val web = catalog["web"] as? JsonArray ?: throw IllegalStateException("Act paket listesi geçersiz.")
        val replacements = linkedMapOf<String, String>()
        for (path in paths) {
            val item = web.filterIsInstance<JsonObject>().firstOrNull { it.text("path") == path }
                ?: throw IllegalStateException("Paket izinli listede yok: $path")
            validate(item, path)
            val code = cachedCode(item) ?: fetchCode(item)
            replacements[path] = "<script data-act-package=\"${item.text("id")}@${item.text("version")}\">\n" +
                code.replace("</script", "<\\/script", true) + "\n</script>"
        }
        tag.replace(html) { match -> replacements[match.groupValues[1]] ?: match.value }
    }

    private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
    private fun validate(item: JsonObject, wantedPath: String) {
        val id = item.text("id").orEmpty()
        val version = item.text("version").orEmpty()
        val path = item.text("path").orEmpty()
        val entry = item.text("archiveEntry").orEmpty()
        val url = item.text("archiveUrl").orEmpty()
        val integrity = item.text("integrity").orEmpty()
        require(id.matches(Regex("[A-Za-z0-9._-]{1,40}")) && version.matches(Regex("[A-Za-z0-9._-]{1,40}")) &&
            path == wantedPath && path.matches(Regex("act-vendor/[A-Za-z0-9._-]+\\.js")) &&
            entry.split('/').all { it.isNotBlank() && it != "." && it != ".." } &&
            url.startsWith("https://registry.npmjs.org/") &&
            integrity.matches(Regex("sha512-[A-Za-z0-9+/=]+"))) { "Paket tanımı güvenli değil." }
    }

    private fun stem(item: JsonObject): String {
        val integrity = item.text("integrity").orEmpty()
        val digest = MessageDigest.getInstance("SHA-256").digest(integrity.toByteArray()).joinToString("") { "%02x".format(it) }.take(16)
        return "${item.text("id")}-${item.text("version")}-${digest}"
    }

    private fun cachedCode(item: JsonObject): String? {
        val base = stem(item)
        val bytes = runCatching { File(directory, "$base.js").readBytes() }.getOrNull() ?: return null
        val sidecar = runCatching { kotlinx.serialization.json.Json.parseToJsonElement(File(directory, "$base.json").readText()) as? JsonObject }.getOrNull() ?: return null
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        if (sidecar.text("integrity") != item.text("integrity") || sidecar.text("entrySHA256") != hash) return null
        return bytes.toString(Charsets.UTF_8)
    }

    private fun fetchCode(item: JsonObject): String {
        val url = item.text("archiveUrl")!!
        val response = http.newCall(Request.Builder().url(url).get().build()).execute()
        val archive = response.use {
            if (!it.isSuccessful) throw IllegalStateException("Act paketi indirilemedi: ${item.text("id")}")
            val bytes = it.body?.byteStream()?.use { stream -> stream.readNBytes(12 * 1024 * 1024 + 1) }
                ?: throw IllegalStateException("Act paketi boş.")
            require(bytes.size <= 12 * 1024 * 1024) { "Act paket arşivi çok büyük." }
            bytes
        }
        val sri = "sha512-" + Base64.encodeToString(MessageDigest.getInstance("SHA-512").digest(archive), Base64.NO_WRAP)
        require(sri == item.text("integrity")) { "Act paketi doğrulanamadı." }
        val tar = GZIPInputStream(ByteArrayInputStream(archive)).use { it.readNBytes(64 * 1024 * 1024 + 1) }
        require(tar.size <= 64 * 1024 * 1024) { "Act paketi açılınca çok büyük." }
        val codeBytes = tarEntry(tar, item.text("archiveEntry")!!) ?: throw IllegalStateException("Paket dosyası arşivde yok.")
        require(codeBytes.isNotEmpty() && codeBytes.size <= 4 * 1024 * 1024) { "Act paket dosyası geçersiz." }
        val code = codeBytes.toString(Charsets.UTF_8)
        val base = stem(item)
        val hash = MessageDigest.getInstance("SHA-256").digest(codeBytes).joinToString("") { "%02x".format(it) }
        save(File(directory, "$base.js"), codeBytes)
        save(File(directory, "$base.json"), "{\"integrity\":\"${item.text("integrity")}\",\"entrySHA256\":\"$hash\"}".toByteArray())
        return code
    }

    private fun tarEntry(tar: ByteArray, wanted: String): ByteArray? {
        var offset = 0
        var longName: String? = null
        var paxPath: String? = null
        while (offset + 512 <= tar.size) {
            val header = tar.copyOfRange(offset, offset + 512)
            if (header.all { it == 0.toByte() }) return null
            fun field(start: Int, length: Int): String = header.copyOfRange(start, start + length)
                .takeWhile { it != 0.toByte() }.toByteArray().toString(Charsets.UTF_8)
            val size = field(124, 12).trim().toLongOrNull(8) ?: return null
            if (size < 0 || size > 64L * 1024 * 1024 || offset + 512L + size > tar.size) return null
            val start = offset + 512
            val body = tar.copyOfRange(start, start + size.toInt())
            offset = start + (((size + 511) / 512) * 512).toInt()
            val type = header[156].toInt().toChar()
            when (type) {
                'L' -> { longName = body.takeWhile { it != 0.toByte() }.toByteArray().toString(Charsets.UTF_8); continue }
                'x' -> { paxPath = body.toString(Charsets.UTF_8).lineSequence().firstOrNull { it.contains(" path=") }?.substringAfter(" path="); continue }
                'g' -> continue
            }
            val prefix = field(345, 155)
            val name = paxPath ?: longName ?: (if (prefix.isEmpty()) field(0, 100) else "$prefix/${field(0, 100)}")
            paxPath = null; longName = null
            if (type == '0' || type == '\u0000') {
                if (name == wanted || name.removePrefix("./") == wanted) return body
            }
        }
        return null
    }

    private fun save(file: File, bytes: ByteArray) {
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try { stream.write(bytes); atomic.finishWrite(stream) }
        catch (error: Exception) { atomic.failWrite(stream); throw error }
    }
}
