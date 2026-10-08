package com.wiqo.android.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.wiqo.android.AppContainer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun ProfileScreen(container: AppContainer, onBack: () -> Unit, onDeleted: () -> Unit, onSaved: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var loading by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var email by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var address by remember { mutableStateOf("") }
    var tone by remember { mutableStateOf("samimi") }
    var language by remember { mutableStateOf("tr") }
    var location by remember { mutableStateOf("") }
    var proactive by remember { mutableStateOf(false) }
    var avatarKind by remember { mutableStateOf("initial") }
    var avatarEmoji by remember { mutableStateOf("") }
    var avatarColor by remember { mutableStateOf("indigo") }
    var avatarImage by remember { mutableStateOf<String?>(null) }
    var deleteDialog by remember { mutableStateOf(false) }
    var deletePassword by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        try {
            val profile = container.api.get("profile") as? JsonObject ?: throw IllegalStateException("Profil okunamadı.")
            email = profile.stringValue("email").orEmpty()
            name = profile.stringValue("displayName").orEmpty()
            address = profile.stringValue("preferredAddress").orEmpty()
            tone = profile.stringValue("tone") ?: "samimi"
            language = profile.stringValue("language") ?: "tr"
            location = profile.stringValue("location").orEmpty()
            proactive = profile.stringValue("proactiveEnabled") == "true"
            avatarKind = profile.stringValue("avatarKind") ?: "initial"
            avatarEmoji = profile.stringValue("avatarEmoji").orEmpty()
            avatarColor = profile.stringValue("avatarColor") ?: "indigo"
            avatarImage = profile.stringValue("avatarImage")
        } catch (failure: Exception) {
            error = failure.message ?: "Profil yüklenemedi."
        } finally { loading = false }
    }

    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri != null) scope.launch {
            try {
                val data = container.api.get("profile/export").toString()
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)?.use { it.write(data.toByteArray(Charsets.UTF_8)) }
                        ?: throw IllegalStateException("Dosya açılamadı.")
                }
                notice = "Verilerin dışa aktarıldı."
            } catch (failure: Exception) { error = failure.message ?: "Veriler dışa aktarılamadı." }
        }
    }
    val photoLauncher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) scope.launch {
            try {
                val encoded = withContext(Dispatchers.IO) {
                    val bytes = context.contentResolver.openInputStream(uri)?.use { it.readNBytes(10_000_001) }
                        ?: throw IllegalStateException("Fotoğraf açılamadı.")
                    if (bytes.size > 10_000_000) throw IllegalStateException("Fotoğraf 10 MB sınırını aşıyor.")
                    val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                    if (bounds.outWidth < 1 || bounds.outHeight < 1) throw IllegalStateException("Fotoğraf okunamadı.")
                    val sample = generateSequence(1) { it * 2 }.first { sample ->
                        bounds.outWidth / sample <= 512 && bounds.outHeight / sample <= 512
                    }
                    val options = android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
                    val bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                        ?: throw IllegalStateException("Fotoğraf okunamadı.")
                    try {
                        val output = java.io.ByteArrayOutputStream()
                        bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 75, output)
                        val base64 = android.util.Base64.encodeToString(output.toByteArray(), android.util.Base64.NO_WRAP)
                        if (base64.length > 400_000) throw IllegalStateException("Fotoğraf küçültülemedi. Başka bir fotoğraf seç.")
                        base64
                    } finally { bitmap.recycle() }
                }
                avatarImage = encoded
                avatarKind = "photo"
                error = null
            } catch (failure: Exception) { error = failure.message ?: "Fotoğraf hazırlanamadı." }
        }
    }

    Scaffold(topBar = {
        TopAppBar(title = { Text("Hesap") }, navigationIcon = {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Geri") }
        })
    }) { insets ->
        Column(
            Modifier.fillMaxSize().padding(insets).verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (loading) CircularProgressIndicator()
            else {
                Text(email)
                Text("Profil görseli")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("initial" to "Baş harf", "emoji" to "Emoji", "photo" to "Fotoğraf").forEach { (kind, label) ->
                        FilterChip(selected = avatarKind == kind, onClick = {
                            if (kind == "photo" && avatarImage == null) photoLauncher.launch("image/*") else avatarKind = kind
                        }, label = { Text(label) })
                    }
                }
                when (avatarKind) {
                    "emoji" -> OutlinedTextField(avatarEmoji, { avatarEmoji = it.take(16) }, label = { Text("Emoji") }, singleLine = true)
                    "photo" -> OutlinedButton(onClick = { photoLauncher.launch("image/*") }) { Text("Fotoğraf seç") }
                }
                listOf("indigo", "blue", "teal", "green", "orange", "pink", "purple", "graphite")
                    .chunked(2).forEach { colors ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        colors.forEach { color ->
                            FilterChip(selected = avatarColor == color, onClick = { avatarColor = color }, label = { Text(color) })
                        }
                    }
                }
                OutlinedTextField(name, { name = it.take(40) }, label = { Text("Ad") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                OutlinedTextField(address, { address = it.take(40) }, label = { Text("Hitap") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                Text("Yanıt tonu")
                Column {
                    listOf("samimi", "profesyonel", "kisa", "detayli").chunked(2).forEach { options ->
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            options.forEach { option ->
                                FilterChip(selected = tone == option, onClick = { tone = option },
                                    label = { Text(when (option) { "kisa" -> "Kısa"; "detayli" -> "Detaylı"; else -> option.replaceFirstChar(Char::uppercase) }) })
                            }
                        }
                    }
                }
                Text("Yanıt dili")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("tr", "en").forEach { option ->
                        FilterChip(selected = language == option, onClick = { language = option },
                            label = { Text(if (option == "tr") "Türkçe" else "English") })
                    }
                }
                OutlinedTextField(location, { location = it.take(80) }, label = { Text("Konum") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                androidx.compose.foundation.layout.Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Proaktif öneriler")
                    Switch(checked = proactive, onCheckedChange = { proactive = it })
                }
                error?.let { Text(it, color = androidx.compose.material3.MaterialTheme.colorScheme.error) }
                notice?.let { Text(it, color = androidx.compose.material3.MaterialTheme.colorScheme.primary) }
                Button(onClick = {
                    scope.launch {
                        busy = true; error = null; notice = null
                        try {
                            container.api.put("profile", buildJsonObject {
                                put("displayName", name.trim()); put("preferredAddress", address.trim())
                                put("tone", tone); put("language", language); put("location", location.trim())
                                put("proactiveEnabled", proactive)
                                put("avatarKind", avatarKind)
                                put("avatarColor", avatarColor)
                                if (avatarKind == "emoji") put("avatarEmoji", avatarEmoji.trim())
                                if (avatarKind == "photo") avatarImage?.let { put("avatarImage", it) }
                            })
                            notice = "Profil kaydedildi."
                            onSaved()
                        } catch (failure: Exception) { error = failure.message ?: "Profil kaydedilemedi." }
                        finally { busy = false }
                    }
                }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("Kaydet") }
                TextButton(onClick = { exportLauncher.launch("wiqo-verilerim.json") }) { Text("Verilerimi dışa aktar") }
                TextButton(onClick = { deleteDialog = true }) { Text("Hesabımı sil", color = androidx.compose.material3.MaterialTheme.colorScheme.error) }
            }
        }
    }

    if (deleteDialog) AlertDialog(
        onDismissRequest = { deleteDialog = false },
        title = { Text("Hesabı kalıcı olarak sil") },
        text = { OutlinedTextField(deletePassword, { deletePassword = it }, label = { Text("Şifre") },
            visualTransformation = PasswordVisualTransformation(), singleLine = true) },
        confirmButton = { TextButton(onClick = {
            scope.launch {
                busy = true
                try {
                    container.api.delete("profile", buildJsonObject { put("password", deletePassword) })
                    deleteDialog = false
                    onDeleted()
                } catch (failure: Exception) { error = failure.message ?: "Hesap silinemedi." }
                finally { busy = false }
            }
        }, enabled = deletePassword.isNotBlank() && !busy) { Text("Kalıcı olarak sil") } },
        dismissButton = { TextButton(onClick = { deleteDialog = false }) { Text("Vazgeç") } },
    )
}

private fun JsonObject.stringValue(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
