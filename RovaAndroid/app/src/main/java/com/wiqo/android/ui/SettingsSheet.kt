package com.wiqo.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.filled.VolumeDown
import androidx.compose.material.icons.automirrored.filled.VolumeMute
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.BrightnessMedium
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.outlined.BrightnessAuto
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.DarkMode
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.LightMode
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Nightlight
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.TrackChanges
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.UnfoldMore
import com.wiqo.android.data.local.ThemeMode
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.components.RovaActionTile
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import kotlinx.coroutines.launch

enum class SettingsSubPage {
    MAIN,
    PC,
    TASKS,
    ACTIVITY,
    MEMORY,
    GOALS,
    ACCOUNT,
    ADVANCED,
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSheet(
    onDismiss: () -> Unit,
    onOpenPC: () -> Unit = {},
    onOpenActivity: () -> Unit = {},
    onSignOut: () -> Unit = {},
    onOpenTasks: () -> Unit = {},
    onOpenMemory: () -> Unit = {},
    onOpenGoals: () -> Unit = {},
    onOpenAccount: () -> Unit = {},
    onOpenAdvanced: () -> Unit = {},
    isPaired: Boolean = false,
    isConnected: Boolean = false,
    deviceName: String = "PC",
    userName: String = "Osman Emre",
    initialPage: SettingsSubPage = SettingsSubPage.MAIN,
    currentThemeMode: ThemeMode = ThemeMode.SYSTEM,
    onThemeModeChange: (ThemeMode) -> Unit = {},
) {
    val colors = WiqoDesign.colors
    var currentPage by remember { mutableStateOf(initialPage) }

    // Intercept back navigation: if in sub-pages, go back to main settings; if in main, exit settings page
    BackHandler(enabled = true) {
        if (currentPage != SettingsSubPage.MAIN) {
            currentPage = SettingsSubPage.MAIN
        } else {
            onDismiss()
        }
    }

    val pageTitle = when (currentPage) {
        SettingsSubPage.MAIN -> "Ayarlar"
        SettingsSubPage.PC -> "PC"
        SettingsSubPage.TASKS -> "Görevler"
        SettingsSubPage.ACTIVITY -> "Etkinlik"
        SettingsSubPage.MEMORY -> "Hafıza"
        SettingsSubPage.GOALS -> "Hedefler"
        SettingsSubPage.ACCOUNT -> "Hesap"
        SettingsSubPage.ADVANCED -> "Gelişmiş"
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.canvas)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
        ) {
            // Unified iOS-Parity Header Bar
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 12.dp),
            ) {
                // Left back button (if in subpage -> back to main settings; if in main -> closes settings page)
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(colors.surface)
                        .border(1.dp, colors.line, CircleShape)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = ripple(bounded = true),
                            onClick = {
                                if (currentPage != SettingsSubPage.MAIN) {
                                    currentPage = SettingsSubPage.MAIN
                                } else {
                                    onDismiss()
                                }
                            },
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                        contentDescription = "Geri",
                        tint = colors.ink,
                        modifier = Modifier.size(20.dp),
                    )
                }

                // Center Title
                Text(
                    text = pageTitle,
                    fontFamily = WiqoSans,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.ink,
                    modifier = Modifier.align(Alignment.Center),
                )

                // Right action button: "Kaydet" in Account, "Kapat" elsewhere
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterEnd)
                        .clip(CircleShape)
                        .background(colors.surface)
                        .border(1.dp, colors.line, CircleShape)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = ripple(bounded = true),
                            onClick = {
                                if (currentPage == SettingsSubPage.ACCOUNT) {
                                    currentPage = SettingsSubPage.MAIN
                                } else {
                                    onDismiss()
                                }
                            },
                        )
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = if (currentPage == SettingsSubPage.ACCOUNT) "Kaydet" else "Kapat",
                        fontFamily = WiqoSans,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.ink,
                    )
                }
            }

            Spacer(Modifier.height(10.dp))

            // Animated Page Content
            AnimatedContent(
                targetState = currentPage,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                transitionSpec = {
                    if (targetState == SettingsSubPage.MAIN) {
                        slideInHorizontally { -it } togetherWith slideOutHorizontally { it }
                    } else {
                        slideInHorizontally { it } togetherWith slideOutHorizontally { -it }
                    }
                },
                label = "SettingsNavigation",
            ) { targetPage ->
                when (targetPage) {
                    SettingsSubPage.MAIN -> {
                        MainSettingsContent(
                            isPaired = isPaired,
                            deviceName = deviceName,
                            userName = userName,
                            onNavigate = { page -> currentPage = page },
                        )
                    }
                    SettingsSubPage.PC -> {
                        PCSettingsContent(
                            isPaired = isPaired,
                            isConnected = isConnected,
                            deviceName = deviceName,
                            onForgetDevice = {},
                        )
                    }
                    SettingsSubPage.TASKS -> {
                        TasksSettingsContent()
                    }
                    SettingsSubPage.ACTIVITY -> {
                        ActivitySettingsContent()
                    }
                    SettingsSubPage.MEMORY -> {
                        MemorySettingsContent()
                    }
                    SettingsSubPage.GOALS -> {
                        GoalsSettingsContent()
                    }
                    SettingsSubPage.ACCOUNT -> {
                        AccountSettingsContent(
                            initialName = userName,
                            onSignOut = onSignOut,
                        )
                    }
                    SettingsSubPage.ADVANCED -> {
                        AdvancedSettingsContent(
                            currentThemeMode = currentThemeMode,
                            onThemeModeChange = onThemeModeChange,
                        )
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 1. MAIN SETTINGS ROOT CARD
// ---------------------------------------------------------------------------
@Composable
private fun MainSettingsContent(
    isPaired: Boolean,
    deviceName: String,
    userName: String,
    onNavigate: (SettingsSubPage) -> Unit,
) {
    val colors = WiqoDesign.colors
    val cardShape = RoundedCornerShape(16.dp)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(cardShape)
                .background(colors.canvas)
                .border(1.dp, colors.line.copy(alpha = 0.6f), cardShape),
        ) {
            SettingsNavigationRow(
                title = "PC",
                icon = Icons.Outlined.Laptop,
                value = if (isPaired) deviceName else "Bağla",
                showsDivider = true,
                onClick = { onNavigate(SettingsSubPage.PC) },
            )

            SettingsNavigationRow(
                title = "Görevler",
                icon = Icons.Outlined.Checklist,
                value = "İncele",
                showsDivider = true,
                onClick = { onNavigate(SettingsSubPage.TASKS) },
            )

            SettingsNavigationRow(
                title = "Etkinlik",
                icon = Icons.Outlined.History,
                value = "Yapılanlar ve bekleyenler",
                showsDivider = true,
                onClick = { onNavigate(SettingsSubPage.ACTIVITY) },
            )

            SettingsNavigationRow(
                title = "Hafıza",
                icon = Icons.Outlined.Psychology,
                value = "Gör ve yönet",
                showsDivider = true,
                onClick = { onNavigate(SettingsSubPage.MEMORY) },
            )

            SettingsNavigationRow(
                title = "Hedefler",
                icon = Icons.Outlined.TrackChanges,
                value = "İlerlemeyi gör",
                showsDivider = true,
                onClick = { onNavigate(SettingsSubPage.GOALS) },
            )

            SettingsNavigationRow(
                title = "Hesap",
                icon = Icons.Outlined.AccountCircle,
                value = userName.ifBlank { "Osman Emre" },
                showsDivider = true,
                onClick = { onNavigate(SettingsSubPage.ACCOUNT) },
            )

            SettingsNavigationRow(
                title = "Gelişmiş",
                icon = Icons.Outlined.Tune,
                value = "Yasal ve destek",
                showsDivider = false,
                onClick = { onNavigate(SettingsSubPage.ADVANCED) },
            )
        }
    }
}

// ---------------------------------------------------------------------------
// 2. ACCOUNT SETTINGS (EXACT MATCH OF USER SCREENSHOT media_1790550964228.png)
// ---------------------------------------------------------------------------
@Composable
private fun AccountSettingsContent(
    initialName: String,
    onSignOut: () -> Unit,
) {
    val colors = WiqoDesign.colors
    var name by remember { mutableStateOf(initialName.ifBlank { "Osman Emre" }) }
    var preferredAddress by remember { mutableStateOf("") }
    var selectedAvatarTab by remember { mutableStateOf("Fotoğraf") }
    var tone by remember { mutableStateOf("Kısa ve öz") }
    var language by remember { mutableStateOf("Türkçe") }
    var location by remember { mutableStateOf("Çankırı") }
    var proactiveEnabled by remember { mutableStateOf(true) }
    var showSignOutConfirm by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(8.dp))

        // Avatar
        Box(
            modifier = Modifier
                .size(76.dp)
                .clip(CircleShape)
                .background(colors.ink.copy(alpha = 0.08f))
                .border(2.dp, colors.canvas, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = name.split(" ").mapNotNull { it.firstOrNull()?.toString() }.take(2).joinToString("").ifBlank { "OE" },
                fontFamily = WiqoSans,
                fontSize = 24.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.ink,
            )
        }

        Spacer(Modifier.height(10.dp))

        Text(
            text = name,
            fontFamily = WiqoSans,
            fontSize = 19.sp,
            fontWeight = FontWeight.SemiBold,
            color = colors.ink,
        )

        Spacer(Modifier.height(14.dp))

        // Segmented Control: Harf | Emoji | Fotoğraf
        Row(
            modifier = Modifier
                .clip(CircleShape)
                .background(colors.canvas)
                .border(1.dp, colors.line.copy(alpha = 0.6f), CircleShape)
                .padding(3.dp),
        ) {
            listOf("Harf", "Emoji", "Fotoğraf").forEach { tab ->
                val isSelected = selectedAvatarTab == tab
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(if (isSelected) colors.surface else Color.Transparent)
                        .clickable { selectedAvatarTab = tab }
                        .padding(horizontal = 20.dp, vertical = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = tab,
                        fontFamily = WiqoSans,
                        fontSize = 13.sp,
                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (isSelected) colors.ink else colors.ink3,
                    )
                }
            }
        }

        Spacer(Modifier.height(12.dp))

        // "Fotoğrafı değiştir" pill button
        Row(
            modifier = Modifier
                .clip(CircleShape)
                .background(colors.canvas)
                .border(1.dp, colors.line, CircleShape)
                .clickable { }
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.Outlined.Image, contentDescription = null, tint = colors.ink, modifier = Modifier.size(16.dp))
            Text(
                text = "Fotoğrafı değiştir",
                fontFamily = WiqoSans,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = colors.ink,
            )
        }

        Spacer(Modifier.height(24.dp))

        // SECTION: Kimlik
        SectionHeader("Kimlik")
        GroupCard {
            SettingsEditableRow(label = "Ad", value = name, onValueChange = { name = it })
            GroupDivider()
            SettingsEditableRow(label = "Hitap", value = preferredAddress, placeholder = "Örn. Emre, Hocam", onValueChange = { preferredAddress = it })
        }
        SectionFooter("Wiqo sana bu şekilde hitap eder.")

        Spacer(Modifier.height(18.dp))

        // SECTION: Wiqo'nun tarzı
        SectionHeader("Wiqo'nun tarzı")
        GroupCard {
            SettingsSelectRow(label = "Yanıt tonu", value = tone, onClick = {
                tone = when (tone) {
                    "Kısa ve öz" -> "Detaylı"
                    "Detaylı" -> "Samimi"
                    "Samimi" -> "Profesyonel"
                    else -> "Kısa ve öz"
                }
            })
            GroupDivider()
            SettingsSelectRow(label = "Yanıt dili", value = language, onClick = {
                language = if (language == "Türkçe") "English" else "Türkçe"
            })
        }

        Spacer(Modifier.height(18.dp))

        // SECTION: Kişiselleştirme
        SectionHeader("Kişiselleştirme")
        GroupCard {
            SettingsEditableRow(label = "Konum", value = location, onValueChange = { location = it })
            GroupDivider()
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Proaktif öneriler", fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.ink)
                Switch(
                    checked = proactiveEnabled,
                    onCheckedChange = { proactiveEnabled = it },
                    colors = SwitchDefaults.colors(checkedThumbColor = colors.canvas, checkedTrackColor = colors.ink),
                )
            }
        }
        SectionFooter("Konum; hava durumu ve yakındaki öneriler için kullanılır. Proaktif öneriler açıkken Wiqo sana uygun zamanda fikir sunar.")

        Spacer(Modifier.height(18.dp))

        // SECTION: Hesap
        SectionHeader("Hesap")
        GroupCard {
            SettingsInfoRow(label = "E-posta", value = "osmanemrekoca@gmail.com")
            GroupDivider()
            SettingsInfoRow(label = "Üyelik", value = "2026'dan beri")
        }

        Spacer(Modifier.height(18.dp))

        // SECTION: Plan
        SectionHeader("Plan")
        GroupCard {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Pro", fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(colors.ink)
                        .clickable { }
                        .padding(horizontal = 14.dp, vertical = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("Planlar", fontFamily = WiqoSans, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = colors.systemBackground)
                }
            }
            GroupDivider()
            UsageBarRow(title = "Bugünkü mesajlar", used = 18, limit = 100)
            GroupDivider()
            UsageBarRow(title = "Bugünkü görseller", used = 3, limit = 20)
        }

        Spacer(Modifier.height(18.dp))

        // SECTION: Bağlantılar
        SectionHeader("Bağlantılar")
        GroupCard {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Bağlı hesaplar", fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.ink)
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = colors.ink.copy(alpha = 0.25f), modifier = Modifier.size(16.dp))
            }
        }

        Spacer(Modifier.height(18.dp))

        // Destructive Actions
        GroupCard {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { showSignOutConfirm = true }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Çıkış yap", fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.red)
            }
            GroupDivider()
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Hesabı sil", fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.red)
            }
        }
        SectionFooter("Hesabın, sohbet hafızan, otomasyonların ve eşleşmiş cihazların kalıcı olarak silinir.")

        Spacer(Modifier.height(20.dp))
    }

    if (showSignOutConfirm) {
        AlertDialog(
            onDismissRequest = { showSignOutConfirm = false },
            title = { Text("Çıkış yap", fontFamily = WiqoSans, fontWeight = FontWeight.SemiBold) },
            text = { Text("Wiqo hesabından çıkmak istediğine emin misin?", fontFamily = WiqoSans) },
            confirmButton = {
                TextButton(onClick = {
                    showSignOutConfirm = false
                    onSignOut()
                }) {
                    Text("Çıkış yap", color = colors.red, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showSignOutConfirm = false }) {
                    Text("Vazgeç", color = colors.ink)
                }
            },
        )
    }
}

// ---------------------------------------------------------------------------
// 3. TASKS & AUTOMATIONS (EXACT MATCH OF RovaIOS/IOSViews.swift:1218)
// ---------------------------------------------------------------------------
@Composable
private fun TasksSettingsContent() {
    val colors = WiqoDesign.colors

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
    ) {
        SectionHeader("Görevler ve otomasyonlar")
        GroupCard {
            SettingsNavigationRow(
                title = "Arka plan görevleri",
                icon = Icons.Outlined.Checklist,
                value = "Çalışan ve bitenler",
                showsDivider = true,
                onClick = { },
            )
            SettingsNavigationRow(
                title = "Ajanlarım",
                icon = Icons.Outlined.AutoAwesome,
                value = "Rol, rutin ve hafıza",
                showsDivider = false,
                onClick = { },
            )
        }

        Spacer(Modifier.height(30.dp))

        // Empty state matching iOS ContentUnavailableView("Görev yok", systemImage: "checklist")
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 40.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(
                imageVector = Icons.Outlined.Checklist,
                contentDescription = null,
                tint = colors.ink.copy(alpha = 0.3f),
                modifier = Modifier.size(48.dp),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = "Görev yok",
                fontFamily = WiqoSans,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.ink,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "Arka planda çalışan uzun bir görev veya bekleyen otomasyon bulunmuyor.",
                fontFamily = WiqoSans,
                fontSize = 13.sp,
                color = colors.ink3,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 32.dp),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// 4. ACTIVITY CONTENT (EXACT MATCH OF RovaIOS/IOSViews.swift:43)
// ---------------------------------------------------------------------------
@Composable
private fun ActivitySettingsContent() {
    val colors = WiqoDesign.colors

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
    ) {
        SectionHeader("İlgi bekleyen")
        GroupCard {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                Text("Burada bir şey yok.", fontFamily = WiqoSans, fontSize = 14.sp, color = colors.ink3)
            }
        }

        Spacer(Modifier.height(18.dp))

        SectionHeader("Yaklaşan")
        GroupCard {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                Text("Yaklaşan planlanmış görev yok.", fontFamily = WiqoSans, fontSize = 14.sp, color = colors.ink3)
            }
        }

        Spacer(Modifier.height(18.dp))

        SectionHeader("Son etkinlik")
        GroupCard {
            Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
                Text("Sohbet geçmişi senkronize edildi", fontFamily = WiqoSans, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colors.ink)
                Spacer(Modifier.height(4.dp))
                Text("Bugün, 07:10", fontFamily = WiqoSans, fontSize = 12.sp, color = colors.ink3)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 5. MEMORY CONTENT (EXACT MATCH OF RovaIOS/IOSViews.swift:364)
// ---------------------------------------------------------------------------
@Composable
private fun MemorySettingsContent() {
    val colors = WiqoDesign.colors
    val memories = remember {
        mutableStateListOf(
            "Genellikle kısa ve teknik cevapları tercih ediyor.",
            "Projelerinde modern Jetpack Compose ve Material 3 kullanıyor.",
            "Android ve iOS arayüzlerinin birebir uyumlu olmasını istiyor.",
        )
    }
    var showDeleteAllConfirm by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
    ) {
        Text(
            text = "Wiqo'nun hatırladıklarını burada görebilir ve silebilirsin.",
            fontFamily = WiqoSans,
            fontSize = 13.sp,
            color = colors.ink3,
            modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
        )

        Spacer(Modifier.height(8.dp))

        if (memories.isEmpty()) {
            GroupCard {
                Box(modifier = Modifier.fillMaxWidth().padding(20.dp), contentAlignment = Alignment.Center) {
                    Text("Kayıtlı hafıza yok.", fontFamily = WiqoSans, fontSize = 14.sp, color = colors.ink3)
                }
            }
        } else {
            GroupCard {
                memories.forEachIndexed { index, memory ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        verticalAlignment = Alignment.Top,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            text = memory,
                            fontFamily = WiqoSans,
                            fontSize = 14.sp,
                            color = colors.ink,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(12.dp))
                        Text(
                            text = "Sil",
                            fontFamily = WiqoSans,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium,
                            color = colors.red,
                            modifier = Modifier.clickable { memories.removeAt(index) },
                        )
                    }
                    if (index < memories.lastIndex) {
                        GroupDivider()
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            Text(
                text = "Tüm hafızayı sil",
                fontFamily = WiqoSans,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = colors.red,
                modifier = Modifier
                    .clickable { showDeleteAllConfirm = true }
                    .padding(horizontal = 4.dp, vertical = 8.dp),
            )
        }
    }

    if (showDeleteAllConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteAllConfirm = false },
            title = { Text("Tüm hafıza silinsin mi?", fontFamily = WiqoSans, fontWeight = FontWeight.SemiBold) },
            text = { Text("Wiqo'nun geçmiş sohbetlerden öğrendiği tüm bilgiler kalıcı olarak silinir.", fontFamily = WiqoSans) },
            confirmButton = {
                TextButton(onClick = {
                    memories.clear()
                    showDeleteAllConfirm = false
                }) {
                    Text("Tümünü sil", color = colors.red, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteAllConfirm = false }) {
                    Text("Vazgeç", color = colors.ink)
                }
            },
        )
    }
}

// ---------------------------------------------------------------------------
// 6. GOALS CONTENT (EXACT MATCH OF RovaIOS/IOSViews.swift:428)
// ---------------------------------------------------------------------------
@Composable
private fun GoalsSettingsContent() {
    val colors = WiqoDesign.colors

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
    ) {
        Text(
            text = "Hedeflerini sohbette Wiqo'ya söyle. Alt görevler tamamlandıkça ilerleme burada güncellenir.",
            fontFamily = WiqoSans,
            fontSize = 13.sp,
            color = colors.ink3,
            modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
        )

        Spacer(Modifier.height(10.dp))

        GroupCard {
            GoalItemRow(
                title = "Wiqo Android uygulamasını tamamla",
                done = 6,
                total = 7,
            )
            GroupDivider()
            GoalItemRow(
                title = "Material 3 tasarım sistemini doğrula",
                done = 4,
                total = 4,
            )
        }
    }
}

@Composable
private fun GoalItemRow(title: String, done: Int, total: Int) {
    val colors = WiqoDesign.colors
    val progress = (done.toFloat() / maxOf(1, total).toFloat()).coerceIn(0f, 1f)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
    ) {
        Text(title, fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.ink)
        Spacer(Modifier.height(10.dp))
        LinearProgressIndicator(
            progress = { progress },
            modifier = Modifier
                .fillMaxWidth()
                .height(6.dp)
                .clip(CircleShape),
            color = colors.ink,
            trackColor = colors.line,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = "$done / $total alt görev tamamlandı",
            fontFamily = WiqoSans,
            fontSize = 12.sp,
            color = colors.ink3,
        )
    }
}

// ---------------------------------------------------------------------------
// 7. ADVANCED SETTINGS (EXACT MATCH OF RovaIOS/IOSViews.swift:1235)
// ---------------------------------------------------------------------------
@Composable
private fun AdvancedSettingsContent(
    currentThemeMode: ThemeMode,
    onThemeModeChange: (ThemeMode) -> Unit,
) {
    val colors = WiqoDesign.colors

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
    ) {
        SectionHeader("Görünüm")
        GroupCard {
            ThemeOptionRow(
                title = "Sistem",
                subtitle = "Cihaz ayarlarını takip et",
                icon = Icons.Outlined.BrightnessAuto,
                isSelected = currentThemeMode == ThemeMode.SYSTEM,
                showsDivider = true,
                onClick = { onThemeModeChange(ThemeMode.SYSTEM) },
            )
            ThemeOptionRow(
                title = "Açık",
                subtitle = "Her zaman açık tema",
                icon = Icons.Outlined.LightMode,
                isSelected = currentThemeMode == ThemeMode.LIGHT,
                showsDivider = true,
                onClick = { onThemeModeChange(ThemeMode.LIGHT) },
            )
            ThemeOptionRow(
                title = "Koyu",
                subtitle = "Her zaman koyu tema",
                icon = Icons.Outlined.DarkMode,
                isSelected = currentThemeMode == ThemeMode.DARK,
                showsDivider = false,
                onClick = { onThemeModeChange(ThemeMode.DARK) },
            )
        }

        Spacer(Modifier.height(24.dp))

        SectionHeader("Yasal ve destek")
        GroupCard {
            LegalRow("Gizlilik Politikası", showsDivider = true)
            LegalRow("Kullanım Şartları", showsDivider = true)
            LegalRow("Destek", showsDivider = false)
        }

        Spacer(Modifier.height(24.dp))

        SectionHeader("Sürüm")
        GroupCard {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 16.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "Wiqo 1.0.0 (1)",
                    fontFamily = WiqoSans,
                    fontSize = 13.sp,
                    color = colors.ink3,
                )
            }
        }
    }
}

@Composable
private fun ThemeOptionRow(
    title: String,
    subtitle: String,
    icon: ImageVector,
    isSelected: Boolean,
    showsDivider: Boolean,
    onClick: () -> Unit,
) {
    val colors = WiqoDesign.colors

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = ripple(),
                    onClick = onClick,
                )
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (isSelected) colors.signal else colors.ink3,
                modifier = Modifier.size(20.dp),
            )

            Spacer(Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    fontFamily = WiqoSans,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.ink,
                )
                Text(
                    text = subtitle,
                    fontFamily = WiqoSans,
                    fontSize = 13.sp,
                    color = colors.ink3,
                )
            }

            if (isSelected) {
                Icon(
                    imageVector = Icons.Outlined.Check,
                    contentDescription = null,
                    tint = colors.signal,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        if (showsDivider) {
            HorizontalDivider(
                modifier = Modifier.padding(start = 48.dp),
                thickness = 0.5.dp,
                color = colors.line,
            )
        }
    }
}

@Composable
private fun LegalRow(title: String, showsDivider: Boolean) {
    val colors = WiqoDesign.colors

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { }
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(title, fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.ink)
            Icon(
                imageVector = Icons.AutoMirrored.Filled.OpenInNew,
                contentDescription = null,
                tint = colors.ink3,
                modifier = Modifier.size(16.dp),
            )
        }
        if (showsDivider) GroupDivider()
    }
}

// ---------------------------------------------------------------------------
// 8. PC SETTINGS CONTENT (MATCHING PCSettingsSheet.kt & iOS PCSettingsView)
// ---------------------------------------------------------------------------
@Composable
private fun PCSettingsContent(
    isPaired: Boolean,
    isConnected: Boolean,
    deviceName: String,
    onForgetDevice: () -> Unit,
) {
    val colors = WiqoDesign.colors
    var volume by remember { mutableFloatStateOf(0.6f) }
    var brightness by remember { mutableFloatStateOf(0.85f) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
    ) {
        SectionHeader("Cihaz durumu")
        GroupCard {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(colors.inset),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Outlined.Laptop, contentDescription = null, tint = colors.ink, modifier = Modifier.size(20.dp))
                }
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(deviceName, fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
                    Text(
                        if (isConnected) "Bağlı ve hazır" else if (isPaired) "Çevrimdışı" else "Eşleşme bekleniyor",
                        fontFamily = WiqoSans,
                        fontSize = 12.sp,
                        color = if (isConnected) colors.green else colors.ink3,
                    )
                }
            }
        }

        Spacer(Modifier.height(18.dp))

        SectionHeader("Hızlı kontroller")
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            RovaActionTile(title = "Kilitle", icon = Icons.Outlined.Lock, onClick = { }, modifier = Modifier.weight(1f))
            RovaActionTile(title = "Uyku", icon = Icons.Outlined.Nightlight, onClick = { }, modifier = Modifier.weight(1f))
            RovaActionTile(title = "Sessiz", icon = Icons.AutoMirrored.Filled.VolumeMute, onClick = { }, modifier = Modifier.weight(1f))
            RovaActionTile(title = "Ekran Uyut", icon = Icons.Outlined.Laptop, onClick = { }, modifier = Modifier.weight(1f))
        }

        Spacer(Modifier.height(18.dp))

        SectionHeader("Ses ve Parlaklık")
        GroupCard {
            Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.AutoMirrored.Filled.VolumeDown, contentDescription = null, tint = colors.ink3, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Slider(
                        value = volume,
                        onValueChange = { volume = it },
                        modifier = Modifier.weight(1f),
                        colors = SliderDefaults.colors(thumbColor = colors.ink, activeTrackColor = colors.ink),
                    )
                    Spacer(Modifier.width(8.dp))
                    Icon(Icons.AutoMirrored.Filled.VolumeUp, contentDescription = null, tint = colors.ink3, modifier = Modifier.size(18.dp))
                }
                GroupDivider()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.BrightnessMedium, contentDescription = null, tint = colors.ink3, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Slider(
                        value = brightness,
                        onValueChange = { brightness = it },
                        modifier = Modifier.weight(1f),
                        colors = SliderDefaults.colors(thumbColor = colors.ink, activeTrackColor = colors.ink),
                    )
                }
            }
        }

        Spacer(Modifier.height(18.dp))

        GroupCard {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onForgetDevice() }
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Delete, contentDescription = null, tint = colors.red, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                Text("Cihazı Unut", fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.red)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// COMMON REUSABLE SETTINGS COMPONENTS
// ---------------------------------------------------------------------------
@Composable
private fun GroupCard(content: @Composable () -> Unit) {
    val colors = WiqoDesign.colors
    val cardShape = RoundedCornerShape(16.dp)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(cardShape)
            .background(colors.canvas)
            .border(1.dp, colors.line.copy(alpha = 0.6f), cardShape),
    ) {
        content()
    }
}

@Composable
private fun GroupDivider() {
    HorizontalDivider(
        modifier = Modifier.padding(start = 16.dp),
        thickness = 0.5.dp,
        color = WiqoDesign.colors.separator,
    )
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        fontFamily = WiqoSans,
        fontSize = 13.sp,
        fontWeight = FontWeight.Medium,
        color = WiqoDesign.colors.ink3,
        modifier = Modifier.padding(horizontal = 6.dp, vertical = 6.dp),
    )
}

@Composable
private fun SectionFooter(text: String) {
    Text(
        text = text,
        fontFamily = WiqoSans,
        fontSize = 12.sp,
        color = WiqoDesign.colors.ink3,
        modifier = Modifier.padding(horizontal = 6.dp, vertical = 6.dp),
    )
}

@Composable
private fun SettingsNavigationRow(
    title: String,
    icon: ImageVector,
    value: String,
    showsDivider: Boolean,
    onClick: () -> Unit,
) {
    val colors = WiqoDesign.colors
    val interactionSource = remember { MutableInteractionSource() }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(
                interactionSource = interactionSource,
                indication = ripple(),
                onClick = onClick,
            ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = colors.ink.copy(alpha = 0.6f),
                modifier = Modifier.size(20.dp),
            )

            Spacer(Modifier.width(12.dp))

            Text(
                text = title,
                fontFamily = WiqoSans,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = colors.ink,
            )

            Spacer(Modifier.weight(1f))

            Text(
                text = value,
                fontFamily = WiqoSans,
                fontSize = 14.sp,
                color = colors.ink3,
                maxLines = 1,
            )

            Spacer(Modifier.width(6.dp))

            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.ink.copy(alpha = 0.25f),
                modifier = Modifier.size(16.dp),
            )
        }

        if (showsDivider) {
            HorizontalDivider(
                modifier = Modifier.padding(start = 46.dp),
                thickness = 0.5.dp,
                color = colors.separator,
            )
        }
    }
}

@Composable
private fun SettingsEditableRow(
    label: String,
    value: String,
    placeholder: String = "",
    onValueChange: (String) -> Unit,
) {
    val colors = WiqoDesign.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.ink)
        Text(
            text = value.ifBlank { placeholder },
            fontFamily = WiqoSans,
            fontSize = 15.sp,
            color = if (value.isBlank()) colors.ink3 else colors.ink,
        )
    }
}

@Composable
private fun SettingsSelectRow(
    label: String,
    value: String,
    onClick: () -> Unit,
) {
    val colors = WiqoDesign.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.ink)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(value, fontFamily = WiqoSans, fontSize = 14.sp, color = colors.ink3)
            Icon(Icons.Outlined.UnfoldMore, contentDescription = null, tint = colors.ink3, modifier = Modifier.size(16.dp))
        }
    }
}

@Composable
private fun SettingsInfoRow(label: String, value: String) {
    val colors = WiqoDesign.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontFamily = WiqoSans, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.ink)
        Text(value, fontFamily = WiqoSans, fontSize = 14.sp, color = colors.ink3)
    }
}

@Composable
private fun UsageBarRow(title: String, used: Int, limit: Int) {
    val colors = WiqoDesign.colors
    val progress = (used.toFloat() / maxOf(1, limit).toFloat()).coerceIn(0f, 1f)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(title, fontFamily = WiqoSans, fontSize = 14.sp, color = colors.ink)
            Text("$used / $limit", fontFamily = WiqoSans, fontSize = 13.sp, color = colors.ink3)
        }
        Spacer(Modifier.height(6.dp))
        LinearProgressIndicator(
            progress = { progress },
            modifier = Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(CircleShape),
            color = colors.ink,
            trackColor = colors.line,
        )
    }
}
