package com.wiqo.android.data.attachments

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.StringReader
import java.util.concurrent.TimeUnit
import java.util.zip.ZipInputStream

/** Content extracted on the phone. Only this text, never the document bytes, reaches the backend. */
data class ChatFileContent(
    val name: String,
    val type: String,
    val byteCount: Int,
    val pageCount: Int?,
    val source: String,
    val text: String,
    val truncated: Boolean,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("name", name)
        put("type", type)
        put("byteCount", byteCount)
        pageCount?.let { put("pageCount", it) }
        put("source", source)
        put("text", text)
        put("tables", buildJsonArray {})
        put("truncated", truncated)
    }
}

/** Android's PDF renderer, ML Kit OCR, and the platform ZIP/XML reader are loaded only on demand. */
class DocumentContentLoader(context: Context) {
    private val appContext = context.applicationContext
    private val resolver = appContext.contentResolver

    suspend fun load(uris: List<Uri>): List<ChatFileContent> = withContext(Dispatchers.IO) {
        if (uris.size > MAX_FILES) throw AttachmentException("Bir kerede en fazla beş dosya ekleyebilirsin.")
        uris.map(::extract)
    }

    private fun extract(uri: Uri): ChatFileContent {
        val name = displayName(uri)
        val extension = name.substringAfterLast('.', "").lowercase()
        val bytes = readBounded(uri)
        val type: String
        val source: String
        val pageCount: Int?
        val content: String
        val truncatedByPages: Boolean
        when (extension) {
            "txt", "md", "json", "log", "xml", "html", "rtf" -> {
                type = "text"; source = "text"; pageCount = null; truncatedByPages = false
                content = bytes.toString(Charsets.UTF_8)
            }
            "csv", "tsv" -> {
                type = "csv"; source = "text"; pageCount = null; truncatedByPages = false
                content = bytes.toString(Charsets.UTF_8)
            }
            "docx" -> {
                type = "docx"; source = "text"; pageCount = null; truncatedByPages = false
                content = readOfficeXml(bytes, name, "word/document.xml") { xml ->
                    xmlText(xml, setOf("t"), setOf("p"))
                }
            }
            "pptx" -> {
                type = "pptx"; source = "text"; pageCount = null
                val slides = officeEntries(bytes, name).filterKeys { it.matches(Regex("ppt/slides/slide[0-9]+\\.xml")) }
                    .toList().sortedBy { it.first.substringAfter("slide").substringBefore('.').toIntOrNull() ?: 0 }
                truncatedByPages = slides.size > MAX_OFFICE_PARTS
                content = slides.take(MAX_OFFICE_PARTS).joinToString("\n\n") { (path, xml) ->
                    "--- ${path.substringAfterLast('/').substringBefore('.')} ---\n${xmlText(xml, setOf("t"), setOf("p"))}"
                }
            }
            "xlsx" -> {
                type = "xlsx"; source = "text"; pageCount = null
                val entries = officeEntries(bytes, name)
                val shared = entries["xl/sharedStrings.xml"]?.let(::sharedStrings).orEmpty()
                val sheets = entries.filterKeys { it.matches(Regex("xl/worksheets/sheet[0-9]+\\.xml")) }.toList()
                    .sortedBy { it.first.substringAfter("sheet").substringBefore('.').toIntOrNull() ?: 0 }
                truncatedByPages = sheets.size > MAX_OFFICE_PARTS
                content = sheets.take(MAX_OFFICE_PARTS).joinToString("\n\n") { (path, xml) ->
                    "--- ${path.substringAfterLast('/').substringBefore('.')} ---\n${sheetText(xml, shared)}"
                }
            }
            "pdf" -> {
                type = "pdf"; source = "ocr"
                val rendered = readPdf(bytes)
                pageCount = rendered.first
                truncatedByPages = pageCount > MAX_PDF_PAGES
                content = rendered.second
            }
            "png", "jpg", "jpeg", "webp" -> {
                type = "image"; source = "ocr"; pageCount = null; truncatedByPages = false
                content = recognizeImage(bytes)
            }
            else -> throw AttachmentException("$name desteklenmiyor. PDF, Office, CSV, metin veya görsel seç.")
        }
        val trimmed = content.trim()
        if (trimmed.isEmpty()) throw AttachmentException("$name içinde okunabilir içerik bulunamadı.")
        return ChatFileContent(name, type, bytes.size, pageCount, source, trimmed.take(MAX_TEXT_CHARS), truncatedByPages || trimmed.length > MAX_TEXT_CHARS)
    }

    private fun displayName(uri: Uri): String {
        val value = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
        return value?.substringAfterLast('/')?.substringAfterLast('\\')?.take(255)?.takeIf(String::isNotBlank)
            ?: throw AttachmentException("Dosya adı okunamadı.")
    }

    private fun readBounded(uri: Uri): ByteArray {
        val stream = resolver.openInputStream(uri) ?: throw AttachmentException("Dosya açılamadı.")
        return stream.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (output.size() + count > MAX_SOURCE_BYTES) throw AttachmentException("Dosya 50 MB sınırını aşıyor.")
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }

    private fun readPdf(bytes: ByteArray): Pair<Int, String> {
        val temporary = File.createTempFile("wiqo-document-", ".pdf", appContext.cacheDir)
        try {
            temporary.writeBytes(bytes)
            ParcelFileDescriptor.open(temporary, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRenderer(descriptor).use { renderer ->
                    val pages = minOf(renderer.pageCount, MAX_PDF_PAGES)
                    val text = (0 until pages).joinToString("\n\n") { index ->
                        renderer.openPage(index).use { page ->
                            val scale = minOf(1.7f, 1800f / maxOf(page.width, page.height))
                            val image = Bitmap.createBitmap(
                                maxOf(1, (page.width * scale).toInt()),
                                maxOf(1, (page.height * scale).toInt()),
                                Bitmap.Config.ARGB_8888,
                            )
                            try {
                                page.render(image, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                "--- Sayfa ${index + 1} ---\n${recognizeBitmap(image)}"
                            } finally { image.recycle() }
                        }
                    }
                    return renderer.pageCount to text
                }
            }
        } catch (error: AttachmentException) {
            throw error
        } catch (_: Exception) {
            throw AttachmentException("PDF okunamadı; dosya bozuk veya parola korumalı olabilir.")
        } finally {
            temporary.delete()
        }
    }

    private fun recognizeImage(bytes: ByteArray): String {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) throw AttachmentException("Görsel okunamadı.")
        options.inJustDecodeBounds = false
        options.inSampleSize = maxOf(1, maxOf(options.outWidth, options.outHeight) / 2200)
        val image = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            ?: throw AttachmentException("Görsel okunamadı.")
        return try { recognizeBitmap(image) } finally { image.recycle() }
    }

    private fun recognizeBitmap(bitmap: Bitmap): String {
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        return try {
            Tasks.await(recognizer.process(InputImage.fromBitmap(bitmap, 0)), 25, TimeUnit.SECONDS).text
        } catch (_: Exception) {
            throw AttachmentException("Metin tanıma tamamlanamadı. Tekrar deneyebilirsin.")
        } finally { recognizer.close() }
    }

    private fun readOfficeXml(bytes: ByteArray, name: String, path: String, parse: (String) -> String): String =
        officeEntries(bytes, name)[path]?.let(parse) ?: throw AttachmentException("$name okunamadı.")

    private fun officeEntries(bytes: ByteArray, name: String): Map<String, String> {
        val entries = mutableMapOf<String, String>()
        var total = 0
        try {
            ZipInputStream(ByteArrayInputStream(bytes)).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    val path = entry.name
                    if (!path.startsWith("word/") && !path.startsWith("ppt/slides/") && !path.startsWith("xl/")) continue
                    if (!path.endsWith(".xml")) continue
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = zip.read(buffer)
                        if (count < 0) break
                        total += count
                        if (output.size() + count > MAX_XML_PART_BYTES || total > MAX_XML_TOTAL_BYTES) {
                            throw AttachmentException("$name içeriği güvenli boyut sınırını aşıyor.")
                        }
                        output.write(buffer, 0, count)
                    }
                    entries[path] = output.toString(Charsets.UTF_8.name())
                }
            }
        } catch (error: AttachmentException) { throw error }
        catch (_: Exception) { throw AttachmentException("$name okunamadı.") }
        return entries
    }

    private fun parser(xml: String): XmlPullParser = XmlPullParserFactory.newInstance().newPullParser().apply {
        setInput(StringReader(xml))
    }

    private fun xmlText(xml: String, textTags: Set<String>, paragraphTags: Set<String>): String {
        val parser = parser(xml)
        val result = StringBuilder()
        while (parser.next() != XmlPullParser.END_DOCUMENT && result.length < MAX_TEXT_CHARS + 1) {
            val tag = parser.name?.substringAfter(':')
            when {
                parser.eventType == XmlPullParser.START_TAG && tag in textTags -> result.append(parser.nextText())
                parser.eventType == XmlPullParser.END_TAG && tag in paragraphTags -> result.append('\n')
            }
        }
        return result.toString()
    }

    private fun sharedStrings(xml: String): List<String> {
        val parser = parser(xml)
        val strings = mutableListOf<String>()
        val current = StringBuilder()
        while (parser.next() != XmlPullParser.END_DOCUMENT && strings.size < 20_000) {
            val tag = parser.name?.substringAfter(':')
            if (parser.eventType == XmlPullParser.START_TAG && tag == "t") current.append(parser.nextText())
            if (parser.eventType == XmlPullParser.END_TAG && tag == "si") {
                strings += current.toString().take(300)
                current.setLength(0)
            }
        }
        return strings
    }

    private fun sheetText(xml: String, shared: List<String>): String {
        val parser = parser(xml)
        val result = StringBuilder()
        var cellType: String? = null
        var rows = 0
        while (parser.next() != XmlPullParser.END_DOCUMENT && rows < 200 && result.length < MAX_TEXT_CHARS + 1) {
            val tag = parser.name?.substringAfter(':')
            when {
                parser.eventType == XmlPullParser.START_TAG && tag == "c" -> cellType = parser.getAttributeValue(null, "t")
                parser.eventType == XmlPullParser.START_TAG && tag == "v" -> {
                    val value = parser.nextText()
                    result.append(if (cellType == "s") shared.getOrNull(value.toIntOrNull() ?: -1).orEmpty() else value)
                    result.append('\t')
                }
                parser.eventType == XmlPullParser.END_TAG && tag == "row" -> { result.append('\n'); rows++ }
            }
        }
        return result.toString()
    }

    private companion object {
        const val MAX_FILES = 5
        const val MAX_SOURCE_BYTES = 50 * 1024 * 1024
        const val MAX_TEXT_CHARS = 400_000
        const val MAX_PDF_PAGES = 30
        const val MAX_OFFICE_PARTS = 200
        const val MAX_XML_PART_BYTES = 10 * 1024 * 1024
        const val MAX_XML_TOTAL_BYTES = 25 * 1024 * 1024
    }
}
