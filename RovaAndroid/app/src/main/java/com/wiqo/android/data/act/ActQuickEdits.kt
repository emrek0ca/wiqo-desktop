package com.wiqo.android.data.act

import java.text.Normalizer
import kotlin.math.pow

/** Applies only unambiguous design-token edits locally; other requests go to the writer. */
object ActQuickEdits {
    data class Result(val changed: Map<String, String>, val summary: String)
    private val colors = mapOf("kirmizi" to "#e5322d", "mavi" to "#2563eb", "yesil" to "#16a34a",
        "turuncu" to "#f97316", "mor" to "#7c3aed", "pembe" to "#ec4899", "sari" to "#eab308",
        "turkuaz" to "#0d9488", "lacivert" to "#1e3a8a", "bordo" to "#9f1239", "kahverengi" to "#92400e",
        "siyah" to "#111827", "gri" to "#6b7280")
    private val root = Regex(":root\\s*\\{[^}]*}", RegexOption.IGNORE_CASE)
    private val prohibited = Regex("\\b(ekle|ekleme|sil|kaldir|degistir(?!\\s*$)|olustur|calisma|islev|davranis|hesapla|yeni|sayfa|dosya|animasyon|resim|gorsel)\\w*")

    fun apply(request: String, files: Map<String, String>): Result? {
        val folded = fold(request)
        val clauses = folded.replace(Regex("\\s+ve\\s+|,|;|\\s+ayrica\\s+|\\s+sonra\\s+|\\s+bir de\\s+"), "|")
            .split('|').map(String::trim).filter(String::isNotEmpty)
        if (clauses.isEmpty() || clauses.size > 4) return null
        var working = files
        val summaries = mutableListOf<String>()
        for (clause in clauses) {
            if (prohibited.containsMatchIn(clause) && !clause.contains(Regex("basli[kg]"))) return null
            val next = clause(clause, request, working) ?: return null
            working = next.first
            summaries.add(next.second)
        }
        val changed = working.filter { files[it.key] != it.value }
        if (changed.isEmpty()) return null
        return Result(changed, summaries.joinToString(", ").replaceFirstChar(Char::uppercase))
    }

    private fun fold(text: String): String = Normalizer.normalize(text.lowercase(java.util.Locale.forLanguageTag("tr-TR"))
        .replace('ı', 'i'), Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "")

    private fun clause(clause: String, original: String, files: Map<String, String>): Pair<Map<String, String>, String>? {
        if (Regex("basli[kg]").containsMatchIn(clause)) {
            val title = Regex("['\"“”‘’]([^'\"“”‘’]{1,60})['\"“”‘’]").find(original)?.groupValues?.get(1)?.trim() ?: return null
            val changed = files.toMutableMap()
            var edited = false
            for ((path, html) in files.filterKeys { it.endsWith(".html") }) {
                var text = html
                val escaped = title.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                val h1 = Regex("<h1\\b[^>]*>[\\s\\S]*?</h1>", RegexOption.IGNORE_CASE)
                val titleTag = Regex("<title>[\\s\\S]*?</title>", RegexOption.IGNORE_CASE)
                h1.find(text)?.let { match ->
                    text = text.replaceRange(match.range, match.value.substringBefore('>') + ">" + escaped + "</h1>")
                    edited = true
                }
                titleTag.find(text)?.let { match -> text = text.replaceRange(match.range, "<title>$escaped</title>"); edited = true }
                changed[path] = text
            }
            return if (edited) changed to "Başlık değişti" else null
        }
        if (clause.contains(Regex("\\b(tema|mod|modu)\\b|temay"))) {
            val dark = clause.contains(Regex("\\b(koyu|karanlik|gece|dark)\\b"))
            val light = clause.contains(Regex("\\b(acik|aydinlik|gunduz|light)\\b"))
            if (!dark && !light) return null
            val tokens = if (dark) mapOf("--bg" to "#0e1014", "--surface" to "#1a1d24", "--fg" to "#f2f4f8", "--muted" to "#9aa3b2", "--border" to "#2c313b")
                else mapOf("--bg" to "#f5f6f8", "--surface" to "#ffffff", "--fg" to "#14161a", "--muted" to "#5c6573", "--border" to "#e2e4e9")
            return setTokens(files, tokens)?.let { it to if (dark) "Koyu tema" else "Açık tema" }
        }
        if (clause.contains(Regex("\\b(yuvarlak|keskin|kare|kosesiz|yuvarlat)\\w*"))) {
            val sharp = clause.contains(Regex("\\b(keskin|kare|kosesiz)\\w*"))
            val buttons = clause.contains(Regex("\\b(buton|tus|dugme)\\w*"))
            val tokens = if (buttons) mapOf("--radius-btn" to if (sharp) "0px" else "999px")
                else if (sharp) mapOf("--radius" to "0px", "--radius-btn" to "0px")
                else mapOf("--radius" to "28px", "--radius-btn" to "20px")
            return setTokens(files, tokens)?.let { it to if (sharp) "Köşeler keskin" else "Köşeler yuvarlak" }
        }
        if (clause.contains(Regex("\\b(yazi|font|punto|boyut|puntosu|yazilar)\\w*")) &&
            clause.contains(Regex("\\b(buyut|artir|buyuk|kucult|azalt|kucuk)\\w*"))) {
            val current = token(files, "--text-size")?.removeSuffix("px")?.trim()?.toIntOrNull() ?: return null
            val bigger = clause.contains(Regex("\\b(buyut|artir|buyuk)\\w*"))
            val next = (current + if (bigger) 2 else -2).coerceIn(12, 28)
            return setTokens(files, mapOf("--text-size" to "${next}px"))?.let { it to if (bigger) "Yazı büyüdü" else "Yazı küçüldü" }
        }
        val hex = Regex("#[0-9a-f]{6}\\b").find(clause)?.value ?: clause.split(Regex("[^a-z]+"))
            .firstNotNullOfOrNull { colors[it] } ?: return null
        if (clause.contains(Regex("arka\\s*plan|zemin"))) {
            val dark = luminance(hex) < .45
            return setTokens(files, mapOf("--bg" to hex, "--fg" to if (dark) "#f2f4f8" else "#14161a",
                "--muted" to if (dark) "#b4bcc9" else "#5c6573"))?.let { it to "Arka plan rengi değişti" }
        }
        if (clause.contains(Regex("yazi\\s*renk|metin\\s*renk|yazilar")))
            return setTokens(files, mapOf("--fg" to hex))?.let { it to "Yazı rengi değişti" }
        return setTokens(files, mapOf("--accent" to hex, "--accent-fg" to if (luminance(hex) > .4) "#14161a" else "#ffffff"))?.let { it to "Ana renk değişti" }
    }

    private fun tokenFile(files: Map<String, String>): String? = files.keys.sorted().firstOrNull { path ->
        (path.endsWith(".css") || path.endsWith(".html")) && root.find(files[path].orEmpty())?.value?.contains("--accent") == true
    }
    private fun token(files: Map<String, String>, name: String): String? {
        val path = tokenFile(files) ?: return null
        val body = root.find(files[path].orEmpty())?.value ?: return null
        return Regex("${Regex.escape(name)}\\s*:\\s*([^;}]+)").find(body)?.groupValues?.get(1)?.trim()
    }
    private fun setTokens(files: Map<String, String>, tokens: Map<String, String>): Map<String, String>? {
        val path = tokenFile(files) ?: return null
        var body = root.find(files[path].orEmpty())?.value ?: return null
        for ((name, value) in tokens) {
            val regex = Regex("(${Regex.escape(name)}\\s*:\\s*)[^;}]+")
            if (!regex.containsMatchIn(body)) return null
            val match = regex.find(body) ?: return null
            body = body.replaceRange(match.range, match.groupValues[1] + value)
        }
        val original = files[path].orEmpty()
        val updated = root.find(original)?.let { original.replaceRange(it.range, body) } ?: return null
        return files + (path to updated)
    }
    private fun luminance(hex: String): Double {
        val n = hex.removePrefix("#").toIntOrNull(16) ?: return .5
        fun channel(value: Int): Double { val v = value / 255.0; return if (v <= .03928) v / 12.92 else ((v + .055) / 1.055).pow(2.4) }
        return .2126 * channel((n shr 16) and 255) + .7152 * channel((n shr 8) and 255) + .0722 * channel(n and 255)
    }
}
