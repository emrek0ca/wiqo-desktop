package com.wiqo.android.data.local

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

enum class ThemeMode { SYSTEM, LIGHT, DARK }

private val Context.wiqoPreferences by preferencesDataStore(name = "wiqo_preferences")

class UserPreferencesStore(private val context: Context) {
    val themeMode: Flow<ThemeMode> = context.wiqoPreferences.data.map { preferences ->
        preferences[THEME_MODE]?.let { value -> runCatching { ThemeMode.valueOf(value) }.getOrNull() } ?: ThemeMode.SYSTEM
    }

    suspend fun setThemeMode(mode: ThemeMode) {
        context.wiqoPreferences.edit { preferences -> preferences[THEME_MODE] = mode.name }
    }

    private companion object {
        val THEME_MODE = stringPreferencesKey("theme_mode")
    }
}
