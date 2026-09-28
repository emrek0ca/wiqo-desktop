package com.wiqo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.components.WiqoActionButton
import com.wiqo.android.ui.components.WiqoField
import com.wiqo.android.ui.components.WiqoPillButton
import com.wiqo.android.ui.components.WiqoPillKind
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ForgotPasswordSheet(
    initialEmail: String,
    onDismiss: () -> Unit,
    onRequestCode: (String) -> Unit,
    onResetPassword: (String, String, String) -> Unit,
    isSubmitting: Boolean = false,
    errorMessage: String? = null,
) {
    val colors = WiqoDesign.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    var email by remember { mutableStateOf(initialEmail) }
    var code by remember { mutableStateOf("") }
    var newPassword by remember { mutableStateOf("") }
    var step by remember { mutableStateOf(1) } // 1: Request Code, 2: Reset

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.surface,
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 36.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = if (step == 1) "Şifremi unuttum" else "Yeni şifre belirle",
                    fontFamily = WiqoSans,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.ink,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = { scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() } }) {
                    Icon(Icons.Default.Close, contentDescription = "Kapat", tint = colors.ink.copy(alpha = 0.5f))
                }
            }

            Text(
                text = if (step == 1)
                    "Hesabına bağlı e-posta adresine 6 haneli bir kod göndereceğiz."
                else
                    "E-postana gelen 6 haneli kodu ve yeni şifreni gir.",
                fontFamily = WiqoSans,
                fontSize = 13.sp,
                color = colors.ink.copy(alpha = 0.6f),
            )

            if (step == 1) {
                WiqoField {
                    BasicTextField(
                        value = email,
                        onValueChange = { email = it },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                        cursorBrush = SolidColor(colors.ink),
                        textStyle = androidx.compose.ui.text.TextStyle(
                            fontFamily = WiqoSans,
                            fontSize = 15.sp,
                            color = colors.ink,
                        ),
                        decorationBox = { inner ->
                            if (email.isEmpty()) Text("E-posta", fontFamily = WiqoSans, fontSize = 15.sp, color = colors.ink3)
                            inner()
                        },
                    )
                }

                if (errorMessage != null) {
                    Text(text = errorMessage, color = colors.red, fontSize = 13.sp, fontFamily = WiqoSans)
                }

                WiqoActionButton(
                    title = "Kodu gönder",
                    isLoading = isSubmitting,
                    enabled = email.isNotBlank(),
                    onClick = {
                        onRequestCode(email)
                        step = 2
                    },
                )
            } else {
                WiqoField {
                    BasicTextField(
                        value = code,
                        onValueChange = { code = it },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        cursorBrush = SolidColor(colors.ink),
                        textStyle = androidx.compose.ui.text.TextStyle(
                            fontFamily = WiqoSans,
                            fontSize = 15.sp,
                            color = colors.ink,
                        ),
                        decorationBox = { inner ->
                            if (code.isEmpty()) Text("6 haneli kod", fontFamily = WiqoSans, fontSize = 15.sp, color = colors.ink3)
                            inner()
                        },
                    )
                }

                WiqoField {
                    BasicTextField(
                        value = newPassword,
                        onValueChange = { newPassword = it },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        cursorBrush = SolidColor(colors.ink),
                        textStyle = androidx.compose.ui.text.TextStyle(
                            fontFamily = WiqoSans,
                            fontSize = 15.sp,
                            color = colors.ink,
                        ),
                        decorationBox = { inner ->
                            if (newPassword.isEmpty()) Text("Yeni şifre (en az 8 karakter)", fontFamily = WiqoSans, fontSize = 15.sp, color = colors.ink3)
                            inner()
                        },
                    )
                }

                if (errorMessage != null) {
                    Text(text = errorMessage, color = colors.red, fontSize = 13.sp, fontFamily = WiqoSans)
                }

                WiqoActionButton(
                    title = "Şifreyi yenile",
                    isLoading = isSubmitting,
                    enabled = code.isNotBlank() && newPassword.length >= 8,
                    onClick = {
                        onResetPassword(email, code, newPassword)
                    },
                )

                WiqoPillButton(
                    text = "Geri dön",
                    kind = WiqoPillKind.Ghost,
                    onClick = { step = 1 },
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                )
            }
        }
    }
}
