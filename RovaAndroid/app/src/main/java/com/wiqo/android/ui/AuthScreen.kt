package com.wiqo.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp

@Composable
internal fun AuthScreen(
    state: AuthUiState,
    onLogin: (String, String) -> Unit,
    onRegister: (String, String, String?) -> Unit,
    onResetRequest: (String) -> Unit,
    onReset: (String, String, String) -> Unit,
) {
    var email by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var invite by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var mode by rememberSaveable { mutableStateOf("login") }
    Column(
        modifier = Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Column(Modifier.widthIn(max = 440.dp).fillMaxWidth()) {
            Text("Wiqo", style = MaterialTheme.typography.displayLarge, color = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.height(8.dp))
            Text(
                when (mode) {
                    "register" -> "Hesabını oluştur"
                    "forgot", "reset" -> "Şifreni yenile"
                    else -> "Hesabına giriş yap"
                },
                style = MaterialTheme.typography.headlineMedium,
            )
            Spacer(Modifier.height(24.dp))
            OutlinedTextField(email, { email = it }, Modifier.fillMaxWidth(), label = { Text("E-posta") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), singleLine = true)
            Spacer(Modifier.height(12.dp))
            if (mode != "forgot") {
                OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text(if (mode == "reset") "Yeni parola" else "Parola") }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), singleLine = true)
                Spacer(Modifier.height(12.dp))
            }
            if (mode == "register") {
                OutlinedTextField(invite, { invite = it }, Modifier.fillMaxWidth(), label = { Text("Davet kodu (isteğe bağlı)") }, singleLine = true)
                Spacer(Modifier.height(12.dp))
            }
            if (mode == "reset") {
                OutlinedTextField(code, { code = it }, Modifier.fillMaxWidth(), label = { Text("E-posta kodu") }, singleLine = true)
                Spacer(Modifier.height(12.dp))
            }
            state.message?.let {
                Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.height(12.dp))
            }
            Button(
                onClick = {
                    when (mode) {
                        "register" -> onRegister(email, password, invite)
                        "forgot" -> { onResetRequest(email); mode = "reset" }
                        "reset" -> onReset(email, code, password)
                        else -> onLogin(email, password)
                    }
                },
                enabled = !state.busy && email.isNotBlank() && (mode == "forgot" || password.isNotBlank()),
                modifier = Modifier.fillMaxWidth().height(48.dp),
            ) {
                if (state.busy) CircularProgressIndicator(Modifier.height(20.dp), strokeWidth = 2.dp)
                else Text(when (mode) { "register" -> "Hesap oluştur"; "forgot" -> "Kodu gönder"; "reset" -> "Parolayı yenile"; else -> "Giriş yap" })
            }
            Spacer(Modifier.height(12.dp))
            when (mode) {
                "login" -> {
                    TextButton(onClick = { mode = "forgot" }, modifier = Modifier.align(Alignment.CenterHorizontally)) { Text("Parolamı unuttum") }
                    OutlinedButton(onClick = { mode = "register" }, modifier = Modifier.fillMaxWidth()) { Text("Yeni hesap oluştur") }
                }
                else -> TextButton(onClick = { mode = "login" }, modifier = Modifier.align(Alignment.CenterHorizontally)) { Text("Giriş ekranına dön") }
            }
        }
    }
}
