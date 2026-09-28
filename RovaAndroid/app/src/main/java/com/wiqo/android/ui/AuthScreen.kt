package com.wiqo.android.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.R
import com.wiqo.android.ui.components.WiqoActionButton
import com.wiqo.android.ui.components.WiqoCheckbox
import com.wiqo.android.ui.components.WiqoField
import com.wiqo.android.ui.components.WiqoPillButton
import com.wiqo.android.ui.components.WiqoPillKind
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans

@Composable
internal fun AuthScreen(
    state: AuthUiState,
    onLogin: (String, String) -> Unit,
    onRegister: (String, String, String?) -> Unit,
    onResetRequest: (String) -> Unit,
    onReset: (String, String, String) -> Unit,
) {
    val colors = WiqoDesign.colors
    val context = LocalContext.current

    var email by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var inviteCode by rememberSaveable { mutableStateOf("") }
    var isRegistering by rememberSaveable { mutableStateOf(false) }
    var showsPassword by rememberSaveable { mutableStateOf(false) }
    var showingForgotPassword by rememberSaveable { mutableStateOf(false) }
    var acceptedPrivacy by rememberSaveable { mutableStateOf(false) }
    var acceptedTerms by rememberSaveable { mutableStateOf(false) }

    val canSubmit = email.isNotBlank() && password.length >= 8 &&
            (!isRegistering || (acceptedPrivacy && acceptedTerms)) && !state.busy

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.canvas),
    ) {
        // Decorative background image with gradient dissolve mask at top
        Image(
            painter = painterResource(R.drawable.wiqo_background),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(0.dp)),
            alpha = 0.78f,
        )

        // Gradient overlay for smooth dissolve
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.0f to colors.canvas,
                        0.18f to colors.canvas.copy(alpha = 0.85f),
                        0.35f to Color.Transparent,
                        1.0f to colors.canvas.copy(alpha = 0.90f),
                    )
                ),
        )

        // Scrollable content
        Column(
            modifier = Modifier
                .fillMaxSize()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Spacer(Modifier.height(24.dp))

            // Brand Header
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Image(
                    painter = painterResource(if (colors.isDark) R.drawable.wiqo_mark_dark else R.drawable.wiqo_mark),
                    contentDescription = "Wiqo",
                    modifier = Modifier
                        .size(84.dp)
                        .shadow(7.dp, RoundedCornerShape(16.dp), ambientColor = colors.ink.copy(alpha = 0.2f)),
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    text = "Wiqo",
                    fontFamily = WiqoSans,
                    fontSize = 32.sp,
                    fontWeight = FontWeight.Bold,
                    color = colors.ink,
                )
            }

            Spacer(Modifier.height(28.dp))

            // Form Card
            Column(
                modifier = Modifier
                    .widthIn(max = 440.dp)
                    .fillMaxWidth()
                    .shadow(10.dp, RoundedCornerShape(WiqoDesign.BigCardRadius), ambientColor = Color.Black.copy(alpha = 0.08f))
                    .clip(RoundedCornerShape(WiqoDesign.BigCardRadius))
                    .background(colors.surface)
                    .border(0.5.dp, colors.line, RoundedCornerShape(WiqoDesign.BigCardRadius))
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    text = if (isRegistering) "Hesap oluştur" else "Giriş yap",
                    fontFamily = WiqoSans,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.ink,
                )

                // Email field
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

                // Password field
                WiqoField {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        BasicTextField(
                            value = password,
                            onValueChange = { password = it },
                            modifier = Modifier.weight(1f),
                            singleLine = true,
                            visualTransformation = if (showsPassword) VisualTransformation.None else PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                            cursorBrush = SolidColor(colors.ink),
                            textStyle = androidx.compose.ui.text.TextStyle(
                                fontFamily = WiqoSans,
                                fontSize = 15.sp,
                                color = colors.ink,
                            ),
                            decorationBox = { inner ->
                                if (password.isEmpty()) Text("Şifre", fontFamily = WiqoSans, fontSize = 15.sp, color = colors.ink3)
                                inner()
                            },
                        )
                        IconButton(
                            onClick = { showsPassword = !showsPassword },
                            modifier = Modifier.size(32.dp),
                        ) {
                            Icon(
                                imageVector = if (showsPassword) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                contentDescription = if (showsPassword) "Şifreyi gizle" else "Şifreyi göster",
                                tint = colors.ink.copy(alpha = 0.5f),
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }

                // Invite code (optional, only during registration)
                if (isRegistering) {
                    WiqoField {
                        BasicTextField(
                            value = inviteCode,
                            onValueChange = { inviteCode = it.uppercase() },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            cursorBrush = SolidColor(colors.ink),
                            textStyle = androidx.compose.ui.text.TextStyle(
                                fontFamily = WiqoSans,
                                fontSize = 15.sp,
                                color = colors.ink,
                            ),
                            decorationBox = { inner ->
                                if (inviteCode.isEmpty()) Text("Davet kodu (opsiyonel)", fontFamily = WiqoSans, fontSize = 15.sp, color = colors.ink3)
                                inner()
                            },
                        )
                    }

                    if (inviteCode.isBlank()) {
                        Text(
                            text = "Bir arkadaşının davet kodu varsa gir - ikiniz de 14 gün Pro kazanırsınız.",
                            fontFamily = WiqoSans,
                            fontSize = 12.sp,
                            color = colors.ink.copy(alpha = 0.6f),
                        )
                    }

                    // Consents
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            WiqoCheckbox(checked = acceptedPrivacy, onCheckedChange = { acceptedPrivacy = it })
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = "Gizlilik Politikası'nı kabul ediyorum.",
                                fontFamily = WiqoSans,
                                fontSize = 12.sp,
                                color = colors.ink,
                                modifier = Modifier.clickable {
                                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://wiqo.app/privacy")))
                                },
                            )
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            WiqoCheckbox(checked = acceptedTerms, onCheckedChange = { acceptedTerms = it })
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = "Kullanım Koşulları'nı kabul ediyorum.",
                                fontFamily = WiqoSans,
                                fontSize = 12.sp,
                                color = colors.ink,
                                modifier = Modifier.clickable {
                                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://wiqo.app/terms")))
                                },
                            )
                        }
                    }
                } else {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                onClick = { showingForgotPassword = true },
                            ),
                        contentAlignment = Alignment.CenterEnd,
                    ) {
                        Text(
                            text = "Şifremi unuttum",
                            fontFamily = WiqoSans,
                            fontSize = 13.sp,
                            color = colors.ink.copy(alpha = 0.6f),
                        )
                    }
                }

                // Error message
                state.message?.let {
                    Text(
                        text = it,
                        fontFamily = WiqoSans,
                        fontSize = 13.sp,
                        color = colors.red,
                    )
                }

                Spacer(Modifier.height(4.dp))

                // Action button
                WiqoActionButton(
                    title = if (isRegistering) "Hesap oluştur" else "Giriş yap",
                    isLoading = state.busy,
                    enabled = canSubmit,
                    onClick = {
                        if (isRegistering) onRegister(email, password, inviteCode.ifBlank { null })
                        else onLogin(email, password)
                    },
                )

                // Toggle Login / Register
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = { isRegistering = !isRegistering },
                        )
                        .padding(vertical = 4.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = if (isRegistering) "Zaten bir hesabın var mı? Giriş yap" else "Hesabın yok mu? Kaydol",
                        fontFamily = WiqoSans,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.ink.copy(alpha = 0.7f),
                    )
                }
            }

            Spacer(Modifier.height(16.dp))
        }

        // Forgot password sheet
        if (showingForgotPassword) {
            ForgotPasswordSheet(
                initialEmail = email,
                onDismiss = { showingForgotPassword = false },
                onRequestCode = onResetRequest,
                onResetPassword = { resetEmail, resetCode, newPass ->
                    onReset(resetEmail, resetCode, newPass)
                    showingForgotPassword = false
                },
                isSubmitting = state.busy,
                errorMessage = state.message,
            )
        }
    }
}
