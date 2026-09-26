package com.wiqo.android.data.artifacts

import android.content.Context
import com.wiqo.android.data.network.ApiException
import com.wiqo.android.data.network.WiqoApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import java.util.UUID

data class ChatArtifact(
    val id: String,
    val filename: String,
    val mimeType: String,
    val sha256: String,
    val downloadUrl: String,
)

/** Authenticated, integrity-checked artifact cache used by chat previews. */
class ArtifactRepository(context: Context, private val api: WiqoApi) {
    private val cacheRoot = File(context.applicationContext.cacheDir, "wiqo-artifacts")

    suspend fun clearAccount(accountId: String?) = withContext(Dispatchers.IO) {
        val safeAccountId = accountId?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,120}")) } ?: return@withContext
        File(cacheRoot, safeAccountId).deleteRecursively()
    }

    suspend fun download(artifact: ChatArtifact): File = withContext(Dispatchers.IO) {
        if (!artifact.id.matches(Regex("[A-Za-z0-9_-]{1,120}")) || !artifact.sha256.matches(Regex("[0-9a-fA-F]{64}"))) {
            throw ApiException("Dosya bilgisi geçersiz.", 400)
        }
        val safeName = artifact.filename.substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[^A-Za-z0-9._ -]"), "_")
            .take(120)
            .ifBlank { "dosya" }
        val account = api.currentAccountId()?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,120}")) }
            ?: throw ApiException("Oturum süresi dolmuş.", 401)
        val folder = File(File(cacheRoot, account), artifact.id)
        if (!folder.canonicalPath.startsWith(cacheRoot.canonicalPath + File.separator)) {
            throw ApiException("Dosya yolu güvenli değil.", 400)
        }
        val destination = File(folder, safeName)
        if (destination.isFile && digest(destination.readBytes()) == artifact.sha256.lowercase()) return@withContext destination

        val bytes = api.downloadArtifact(artifact.downloadUrl)
        if (digest(bytes) != artifact.sha256.lowercase()) throw ApiException("Dosya bütünlük doğrulamasını geçemedi.", 422)
        if (!folder.exists() && !folder.mkdirs()) throw ApiException("Dosya önizlemesi hazırlanamadı.", 500)
        val temporary = File(folder, ".${safeName}.${UUID.randomUUID()}.tmp")
        try {
            temporary.writeBytes(bytes)
            if (destination.exists() && !destination.delete()) throw ApiException("Önbellekteki dosya yenilenemedi.", 500)
            if (!temporary.renameTo(destination)) throw ApiException("Dosya önizlemesi kaydedilemedi.", 500)
        } finally {
            temporary.delete()
        }
        destination
    }

    private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { byte -> "%02x".format(byte) }
}
