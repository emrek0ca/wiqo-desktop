package com.wiqo.android.data.network

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicBoolean

/** FCM remains optional until the user configures Firebase for com.wiqo.android. */
class PushRegistration(context: Context, private val api: WiqoApi) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences("wiqo_push_registration", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val registrationEnabled = AtomicBoolean(false)
    private val registrationLock = Mutex()

    fun register() {
        if (FirebaseApp.getApps(appContext).isEmpty()) return
        registrationEnabled.set(true)
        runCatching { FirebaseMessaging.getInstance().register() }
            .getOrNull()
            ?.addOnFailureListener { /* Push is optional; retry on the next authenticated startup. */ }
    }

    suspend fun revoke() {
        registrationEnabled.set(false)
        val installationId = preferences.getString(INSTALLATION_ID_KEY, null)
        registrationLock.withLock {
            if (installationId != null) runCatching { api.revokeFcmToken(installationId) }
            preferences.edit().remove(INSTALLATION_ID_KEY).apply()
        }
    }

    fun onRegistered(installationId: String) {
        if (installationId.isBlank() || !registrationEnabled.get()) return
        scope.launch {
            registrationLock.withLock {
                if (!registrationEnabled.get()) return@withLock
                preferences.edit().putString(INSTALLATION_ID_KEY, installationId).apply()
                runCatching { api.registerFcmToken(installationId) }
            }
        }
    }

    private companion object {
        const val INSTALLATION_ID_KEY = "installation_id"
    }
}
