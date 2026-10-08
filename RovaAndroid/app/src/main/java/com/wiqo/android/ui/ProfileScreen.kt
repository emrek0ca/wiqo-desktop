package com.wiqo.android.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
                OutlinedTextField(name, { name = it.take(40) }, label = { Text("Ad") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                OutlinedTextField(address, { address = it.take(40) }, label = { Text("Hitap") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                Text("Yanıt tonu")
                androidx.compose.material3.SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    listOf("samimi", "profesyonel", "kisa", "detayli").forEachIndexed { index, option ->
                        androidx.compose.material3.SegmentedButton(
                            selected = tone == option,
                            onClick = { tone = option },
                            shape = androidx.compose.material3.SegmentedButtonDefaults.itemShape(index, 4),
                            label = { Text(when (option) { "kisa" -> "Kısa"; "detayli" -> "Detaylı"; else -> option.replaceFirstChar(Char::uppercase) }) },
                        )
                    }
                }
                Text("Yanıt dili")
                androidx.compose.material3.SingleChoiceSegmentedButtonRow {
                    listOf("tr", "en").forEachIndexed { index, option ->
                        androidx.compose.material3.SegmentedButton(selected = language == option, onClick = { language = option },
                            shape = androidx.compose.material3.SegmentedButtonDefaults.itemShape(index, 2),
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
