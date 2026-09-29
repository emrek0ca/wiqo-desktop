package com.wiqo.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.BorderStroke
import android.content.Intent
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.R
import com.wiqo.android.ui.components.WiqoChevron
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit

data class ConversationItem(
    val id: String,
    val title: String,
    val updatedAt: Long,
)

@Composable
fun SidebarOverlay(
    isOpen: Boolean,
    onDismiss: () -> Unit,
    conversations: List<ConversationItem>,
    currentConversationId: String,
    onSelectConversation: (String) -> Unit,
    onNewChat: () -> Unit,
    onDeleteConversation: (String) -> Unit,
    onOpenSettings: () -> Unit,
    userName: String = "Kullanıcı",
    userEmail: String = "",
    modifier: Modifier = Modifier,
) {
    val colors = WiqoDesign.colors
    val context = LocalContext.current
    var searchQuery by remember { mutableStateOf("") }

    val filteredConversations = remember(conversations, searchQuery) {
        if (searchQuery.isBlank()) conversations
        else conversations.filter { it.title.contains(searchQuery, ignoreCase = true) }
    }

    // Grouping by date matching iOS
    val groupedSections = remember(filteredConversations) {
        val today = LocalDate.now()
        val groups = linkedMapOf<String, MutableList<ConversationItem>>()
        filteredConversations.forEach { item ->
            val date = Instant.ofEpochMilli(item.updatedAt).atZone(ZoneId.systemDefault()).toLocalDate()
            val daysDiff = ChronoUnit.DAYS.between(date, today)
            val section = when {
                daysDiff == 0L -> "Bugün"
                daysDiff == 1L -> "Dün"
                daysDiff in 2L..7L -> "Önceki 7 gün"
                daysDiff in 8L..30L -> "Önceki 30 gün"
                else -> "Daha eski"
            }
            groups.getOrPut(section) { mutableListOf() }.add(item)
        }
        groups
    }

    if (isOpen) {
        Box(modifier = modifier.fillMaxSize()) {
            // Backdrop
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.32f))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onDismiss,
                    ),
            )

            // Drawer content (304dp width matching iOS)
            Column(
                modifier = Modifier
                    .width(304.dp)
                    .fillMaxHeight()
                    .background(colors.systemBackground)
                    .padding(top = 16.dp, bottom = 16.dp),
            ) {
                // Header
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 18.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Image(
                        painter = painterResource(if (colors.isDark) R.drawable.wiqo_mark_dark else R.drawable.wiqo_mark),
                        contentDescription = "Wiqo",
                        modifier = Modifier.size(26.dp),
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        text = "Wiqo",
                        fontFamily = WiqoSans,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                        color = colors.ink,
                        modifier = Modifier.weight(1f),
                    )
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .background(colors.inset, CircleShape)
                            .clip(CircleShape)
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = ripple(bounded = true),
                                onClick = onNewChat,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Edit,
                            contentDescription = "Yeni sohbet",
                            tint = colors.ink,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }

                // Search field
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 14.dp, vertical = 6.dp)
                        .height(38.dp)
                        .background(colors.inset, RoundedCornerShape(10.dp))
                        .padding(horizontal = 10.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Default.Search,
                            contentDescription = null,
                            tint = colors.ink.copy(alpha = 0.5f),
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        BasicTextField(
                            value = searchQuery,
                            onValueChange = { searchQuery = it },
                            modifier = Modifier.weight(1f),
                            singleLine = true,
                            cursorBrush = SolidColor(colors.ink),
                            textStyle = androidx.compose.ui.text.TextStyle(
                                fontFamily = WiqoSans,
                                fontSize = 14.sp,
                                color = colors.ink,
                            ),
                            decorationBox = { inner ->
                                if (searchQuery.isEmpty()) {
                                    Text(
                                        text = "Sohbetlerde ara",
                                        fontFamily = WiqoSans,
                                        fontSize = 14.sp,
                                        color = colors.ink3,
                                    )
                                }
                                inner()
                            },
                        )
                        if (searchQuery.isNotEmpty()) {
                            Icon(
                                imageVector = Icons.Default.Close,
                                contentDescription = "Temizle",
                                tint = colors.ink.copy(alpha = 0.5f),
                                modifier = Modifier
                                    .size(16.dp)
                                    .clickable { searchQuery = "" },
                            )
                        }
                    }
                }

                Spacer(Modifier.height(8.dp))

                // Conversations list
                if (filteredConversations.isEmpty()) {
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth()
                            .padding(top = 48.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.Chat,
                            contentDescription = null,
                            tint = colors.ink3,
                            modifier = Modifier.size(28.dp),
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = if (searchQuery.isEmpty()) "Henüz sohbet yok" else "Sonuç bulunamadı",
                            fontFamily = WiqoSans,
                            fontSize = 14.sp,
                            color = colors.ink.copy(alpha = 0.6f),
                        )
                    }
                } else {
                    LazyColumn(modifier = Modifier.weight(1f)) {
                        groupedSections.forEach { (sectionTitle, items) ->
                            item(key = "header-$sectionTitle") {
                                Text(
                                    text = sectionTitle,
                                    fontFamily = WiqoSans,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = colors.ink.copy(alpha = 0.5f),
                                    modifier = Modifier
                                        .padding(horizontal = 24.dp)
                                        .padding(top = 14.dp, bottom = 4.dp),
                                )
                            }
                            items(items, key = { it.id }) { item ->
                                var menuExpanded by remember { mutableStateOf(false) }
                                val isSelected = item.id == currentConversationId

                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = 10.dp, vertical = 1.dp)
                                        .clip(RoundedCornerShape(8.dp))
                                        .background(if (isSelected) colors.inset else Color.Transparent)
                                        .clickable { onSelectConversation(item.id) }
                                        .padding(horizontal = 14.dp, vertical = 9.dp),
                                ) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Text(
                                            text = item.title.ifBlank { "Yeni sohbet" },
                                            fontFamily = WiqoSans,
                                            fontSize = 14.sp,
                                            fontWeight = if (isSelected) FontWeight.Medium else FontWeight.Normal,
                                            color = colors.ink,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.weight(1f),
                                        )
                                        Box {
                                            IconButton(
                                                onClick = { menuExpanded = true },
                                                modifier = Modifier.size(28.dp),
                                            ) {
                                                Icon(
                                                    imageVector = Icons.Outlined.MoreVert,
                                                    contentDescription = "Seçenekler",
                                                    tint = colors.ink3,
                                                    modifier = Modifier.size(17.dp),
                                                )
                                            }
                                            DropdownMenu(
                                                expanded = menuExpanded,
                                                onDismissRequest = { menuExpanded = false },
                                                shape = RoundedCornerShape(16.dp),
                                                containerColor = colors.surface,
                                                border = BorderStroke(0.5.dp, colors.line),
                                                shadowElevation = 8.dp,
                                                tonalElevation = 2.dp,
                                            ) {
                                                DropdownMenuItem(
                                                    text = { Text("Sohbeti paylaş", color = colors.ink, fontFamily = WiqoSans, fontWeight = FontWeight.Normal) },
                                                    onClick = {
                                                        menuExpanded = false
                                                        val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                                            putExtra(Intent.EXTRA_TEXT, item.title)
                                                            type = "text/plain"
                                                        }
                                                        context.startActivity(Intent.createChooser(sendIntent, "Sohbeti Paylaş"))
                                                    },
                                                    leadingIcon = {
                                                        Icon(Icons.Outlined.Share, contentDescription = null, tint = colors.ink, modifier = Modifier.size(18.dp))
                                                    },
                                                )
                                                DropdownMenuItem(
                                                    text = { Text("Sohbeti sil", color = colors.red, fontFamily = WiqoSans, fontWeight = FontWeight.Medium) },
                                                    onClick = {
                                                        menuExpanded = false
                                                        onDeleteConversation(item.id)
                                                    },
                                                    leadingIcon = {
                                                        Icon(Icons.Outlined.Delete, contentDescription = null, tint = colors.red, modifier = Modifier.size(18.dp))
                                                    },
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Divider above profile row
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(0.5.dp)
                        .background(colors.line),
                )

                // Profile row at bottom
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = ripple(),
                            onClick = onOpenSettings,
                        )
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(34.dp)
                            .background(colors.ink, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = userName.take(1).uppercase().ifBlank { "W" },
                            fontFamily = WiqoSans,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                            color = colors.systemBackground,
                        )
                    }
                    Spacer(Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = userName.ifBlank { "Wiqo hesabı" },
                            fontFamily = WiqoSans,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            color = colors.ink,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (userEmail.isNotBlank()) {
                            Text(
                                text = userEmail,
                                fontFamily = WiqoSans,
                                fontSize = 11.sp,
                                color = colors.ink.copy(alpha = 0.5f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    WiqoChevron()
                }
            }
        }
    }
}
