package com.wiqo.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import com.wiqo.android.data.local.ThemeMode

internal val RadiusCard = 20
internal val RadiusControl = 10
internal val ScreenPadding = 16

@Composable
fun WiqoTheme(themeMode: ThemeMode = ThemeMode.SYSTEM, content: @Composable () -> Unit) {
    val dark = when (themeMode) {
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
    }
    val colors = if (dark) {
        darkColorScheme(
            primary = DarkInk,
            onPrimary = DarkCanvas,
            secondary = SignalGreen,
            onSecondary = ColorTextOnGreen,
            background = DarkCanvas,
            onBackground = DarkInk,
            surface = DarkSurface,
            onSurface = DarkInk,
            surfaceVariant = DarkInset,
            onSurfaceVariant = DarkInk.copy(alpha = 0.72f),
            error = androidx.compose.ui.graphics.Color(0xFFFF6B63),
        )
    } else {
        lightColorScheme(
            primary = LightInk,
            onPrimary = LightSurface,
            secondary = SignalGreen,
            onSecondary = ColorTextOnGreen,
            background = LightCanvas,
            onBackground = LightInk,
            surface = LightSurface,
            onSurface = LightInk,
            surfaceVariant = LightInset,
            onSurfaceVariant = LightInk.copy(alpha = 0.68f),
            error = androidx.compose.ui.graphics.Color(0xFFC83B34),
        )
    }
    MaterialTheme(colorScheme = colors, typography = WiqoTypography, content = content)
}

private val ColorTextOnGreen = androidx.compose.ui.graphics.Color(0xFF17200F)
