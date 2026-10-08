package com.wiqo.android.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.wiqo.android.AppContainer

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun SubscriptionScreen(container: AppContainer, onBack: () -> Unit = {}) {
    val state by container.billing.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    LaunchedEffect(Unit) { container.billing.load() }

    Scaffold(topBar = { TopAppBar(title = { Text("Planlar") }, navigationIcon = {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Geri") }
    }) }) { insets ->
        Box(Modifier.fillMaxWidth().padding(insets), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.fillMaxWidth().widthIn(max = 620.dp).verticalScroll(rememberScrollState()).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                Text("Wiqo'yu yükselt", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
                Text("Daha fazla mesaj, görsel ve PC bağlantısı için bir plan seç.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            PlanCard(
                title = "Free",
                price = "Ücretsiz",
                current = state.tier == "free",
                features = listOf("Günde 10 mesaj", "Günde 1 görsel", "PC bağlantısı yok"),
            )
            PlanCard(
                title = "Pro",
                price = state.price?.let { "$it/ay" } ?: if (state.loading) "Fiyat yükleniyor" else "Fiyat şu anda kullanılamıyor",
                current = state.tier == "pro",
                features = listOf("Günde 100 mesaj", "Günde 10 görsel", "PC bağlantısı"),
            ) {
                if (state.tier != "pro") {
                    Button(
                        onClick = { context.findActivity()?.let(container.billing::purchase) },
                        enabled = state.available && !state.busy,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (state.busy) CircularProgressIndicator(Modifier.height(18.dp), strokeWidth = 2.dp)
                        else Text("Pro'ya geç")
                    }
                    if (!state.loading && !state.available) {
                        Text("Wiqo Pro Google Play'de henüz kullanılamıyor. Daha sonra tekrar deneyebilirsin.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
            state.statusMessage?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium) }
            OutlinedButton(onClick = container.billing::restore, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                Text("Satın alımları geri yükle")
            }
            HorizontalDivider()
            Text(
                "Pro, Google Play üzerinden aylık otomatik yenilenen bir aboneliktir. Ödeme satın alma onayıyla Google Play hesabından alınır. Aboneliğini Play Store'daki Ödemeler ve abonelikler bölümünden yönetebilir veya iptal edebilirsin.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                TextButton(onClick = { uriHandler.openUri("https://wiqoai.com/privacy") }) { Text("Gizlilik Politikası") }
                TextButton(onClick = { uriHandler.openUri("https://wiqoai.com/terms") }) { Text("Kullanım Şartları") }
            }
            Spacer(Modifier.height(8.dp))
            }
        }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

@Composable
private fun PlanCard(
    title: String,
    price: String,
    current: Boolean,
    features: List<String>,
    action: @Composable () -> Unit = {},
) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title, style = MaterialTheme.typography.titleLarge)
                if (current) Text("Mevcut plan", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.weight(1f))
                Text(price, style = MaterialTheme.typography.titleMedium)
            }
            features.forEach { feature ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                    Text(feature, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            action()
        }
    }
}
