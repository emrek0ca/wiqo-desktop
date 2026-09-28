package com.wiqo.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color

internal val WiqoSignalGreen = Color(0xFF8CC729)

// Light Palette (iOS Exact)
internal val LightInk = Color(0xFF0E1F33)
internal val LightCanvas = Color(0xFFF2F2F7)
internal val LightSurface = Color(0xFFFFFFFF)
internal val LightSystemBackground = Color(0xFFFFFFFF)
internal val LightSecondarySystemBackground = Color(0xFFF2F2F7)
internal val LightInset = Color(0x1F767680)
internal val LightLine = Color(0x14000000)
internal val LightLineStrong = Color(0x2E000000)
internal val LightInk3 = Color(0x4D3C3C43)
internal val LightSeparator = Color(0x333C3C43)

// Dark Palette (iOS Exact)
internal val DarkInk = Color(0xFFC7D4E6)
internal val DarkCanvas = Color(0xFF000000)
internal val DarkSurface = Color(0xFF1C1C1E)
internal val DarkSystemBackground = Color(0xFF000000)
internal val DarkSecondarySystemBackground = Color(0xFF1C1C1E)
internal val DarkInset = Color(0x3D767680)
internal val DarkLine = Color(0x14FFFFFF)
internal val DarkLineStrong = Color(0x2EFFFFFF)
internal val DarkInk3 = Color(0x4DEBEBF5)
internal val DarkSeparator = Color(0x40545458)

// Semantic Accents
internal val WiqoGreen = Color(0xFF34C759)
internal val WiqoRed = Color(0xFFFF3B30)
internal val WiqoOrange = Color(0xFFFF9500)
internal val WiqoBlue = Color(0xFF007AFF)

@Immutable
data class WiqoColors(
    val ink: Color,
    val canvas: Color,
    val surface: Color,
    val systemBackground: Color,
    val secondarySystemBackground: Color,
    val inset: Color,
    val line: Color,
    val lineStrong: Color,
    val ink3: Color,
    val separator: Color,
    val signal: Color = WiqoSignalGreen,
    val green: Color = WiqoGreen,
    val red: Color = WiqoRed,
    val orange: Color = WiqoOrange,
    val blue: Color = WiqoBlue,
    val isDark: Boolean,
) {
    fun tint(color: Color): Color = color.copy(alpha = 0.12f)
}
