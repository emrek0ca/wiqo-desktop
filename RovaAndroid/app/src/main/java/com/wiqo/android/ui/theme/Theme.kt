package com.wiqo.android.ui.theme

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.unit.dp
import com.wiqo.android.data.local.ThemeMode

object WiqoDesign {
    val BigCardRadius = 20.dp
    val CardRadius = 16.dp
    val ChipRadius = 15.dp
    val BubbleRadius = 20.dp
    val ControlRadius = 10.dp
    val FieldRadius = 12.dp
    val ComposerRadius = 26.dp
    val ScreenPadding = 16.dp
    val CardSpacing = 12.dp

    val EaseCurve = CubicBezierEasing(0.23f, 1f, 0.32f, 1f)
    val SlideCurve = CubicBezierEasing(0.22f, 1f, 0.36f, 1f)

    val colors: WiqoColors
        @Composable
        @ReadOnlyComposable
        get() = LocalWiqoColors.current
}

val LocalWiqoColors = staticCompositionLocalOf<WiqoColors> {
    error("No WiqoColors provided")
}

@Composable
fun WiqoTheme(themeMode: ThemeMode = ThemeMode.SYSTEM, content: @Composable () -> Unit) {
    val dark = when (themeMode) {
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
    }

    val wiqoColors = if (dark) {
        WiqoColors(
            ink = DarkInk,
            canvas = DarkCanvas,
            surface = DarkSurface,
            systemBackground = DarkSystemBackground,
            secondarySystemBackground = DarkSecondarySystemBackground,
            inset = DarkInset,
            line = DarkLine,
            lineStrong = DarkLineStrong,
            ink3 = DarkInk3,
            separator = DarkSeparator,
            isDark = true,
        )
    } else {
        WiqoColors(
            ink = LightInk,
            canvas = LightCanvas,
            surface = LightSurface,
            systemBackground = LightSystemBackground,
            secondarySystemBackground = LightSecondarySystemBackground,
            inset = LightInset,
            line = LightLine,
            lineStrong = LightLineStrong,
            ink3 = LightInk3,
            separator = LightSeparator,
            isDark = false,
        )
    }

    val materialColors = if (dark) {
        darkColorScheme(
            primary = wiqoColors.ink,
            onPrimary = wiqoColors.systemBackground,
            secondary = wiqoColors.signal,
            background = wiqoColors.canvas,
            onBackground = wiqoColors.ink,
            surface = wiqoColors.surface,
            onSurface = wiqoColors.ink,
            surfaceVariant = wiqoColors.inset,
            onSurfaceVariant = wiqoColors.ink.copy(alpha = 0.72f),
            error = wiqoColors.red,
        )
    } else {
        lightColorScheme(
            primary = wiqoColors.ink,
            onPrimary = wiqoColors.surface,
            secondary = wiqoColors.signal,
            background = wiqoColors.canvas,
            onBackground = wiqoColors.ink,
            surface = wiqoColors.surface,
            onSurface = wiqoColors.ink,
            surfaceVariant = wiqoColors.inset,
            onSurfaceVariant = wiqoColors.ink.copy(alpha = 0.68f),
            error = wiqoColors.red,
        )
    }

    CompositionLocalProvider(LocalWiqoColors provides wiqoColors) {
        MaterialTheme(colorScheme = materialColors, typography = WiqoTypography, content = content)
    }
}
