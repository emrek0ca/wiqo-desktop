package com.wiqo.android.data.attachments

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

data class ChatAttachment(val name: String, val mimeType: String, val dataBase64: String)

class AttachmentLoader(context: Context) {
    private val resolver: ContentResolver = context.applicationContext.contentResolver

    suspend fun load(uris: List<Uri>): List<ChatAttachment> = withContext(Dispatchers.IO) {
        if (uris.size > MAX_FILES) throw AttachmentException("Bir kerede en fazla $MAX_FILES dosya ekleyebilirsin.")
        var encodedBytes = 0L
        uris.map { uri ->
            val name = displayName(uri)
            val mimeType = resolver.getType(uri)?.takeIf(String::isNotBlank) ?: "application/octet-stream"
            val bytes = readBounded(uri)
            val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
            encodedBytes += encoded.length
            if (encodedBytes > MAX_BASE64_BYTES) throw AttachmentException("Eklerin toplam boyutu çok büyük. Daha küçük dosyalar seçip tekrar dene.")
            ChatAttachment(name, mimeType, encoded)
        }
    }

    private fun displayName(uri: Uri): String {
        val fromProvider = runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull()
        return fromProvider?.takeIf(String::isNotBlank)?.substringAfterLast('/')?.take(MAX_NAME_CHARS)
            ?: "Ek.${resolver.getType(uri)?.substringAfter('/')?.take(12) ?: "bin"}"
    }

    private fun readBounded(uri: Uri): ByteArray {
        val output = ByteArrayOutputStream()
        val input = resolver.openInputStream(uri) ?: throw AttachmentException("Seçilen dosya açılamadı.")
        input.use { stream ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var total = 0
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                total += count
                if (total > MAX_FILE_BYTES) throw AttachmentException("Bir dosya 8 MB sınırını aşıyor: ${displayName(uri)}")
                output.write(buffer, 0, count)
            }
        }
        if (output.size() == 0) throw AttachmentException("Seçilen dosya boş: ${displayName(uri)}")
        return output.toByteArray()
    }

    companion object {
        private const val MAX_FILES = 5
        private const val MAX_FILE_BYTES = 8 * 1024 * 1024
        private const val MAX_BASE64_BYTES = 18_000_000L
        private const val MAX_NAME_CHARS = 120
    }
}

class AttachmentException(message: String) : Exception(message)
