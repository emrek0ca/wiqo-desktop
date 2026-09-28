package com.wiqo.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.wiqo.android.AppContainer
import com.wiqo.android.data.network.ApiException
import com.wiqo.android.data.security.SecureTokenStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class AuthUiState(
    val signedIn: Boolean = false,
    val busy: Boolean = false,
    val message: String? = null,
)

class AuthViewModel(private val container: AppContainer) : ViewModel() {
    private val mutableState = MutableStateFlow(AuthUiState(signedIn = true))
    val state = mutableState.asStateFlow()

    fun login(email: String, password: String) = authenticate { container.api.login(email, password) }

    fun register(email: String, password: String, inviteCode: String?) = authenticate {
        container.api.register(email, password, inviteCode)
    }

    fun requestReset(email: String) = runAction {
        container.api.requestPasswordReset(email)
        mutableState.value = AuthUiState(message = "Şifre sıfırlama bağlantısı veya kodu gönderildi.")
    }

    fun resetPassword(email: String, code: String, password: String) = authenticate {
        container.api.resetPassword(email, code, password)
    }

    fun signOut() {
        val accountId = container.api.currentAccountId()
        viewModelScope.launch {
            accountId?.let { container.database.conversations().clearAccount(it) }
            runCatching { container.artifacts.clearAccount(accountId) }
            container.pushRegistration.revoke()
            container.tokenStore.clearCredentials()
            mutableState.value = AuthUiState()
        }
    }

    fun clearMessage() { mutableState.value = mutableState.value.copy(message = null) }

    private fun authenticate(action: suspend () -> String) = runAction {
        action()
        container.pushRegistration.register()
        mutableState.value = AuthUiState(signedIn = true)
    }

    private fun runAction(action: suspend () -> Unit) {
        if (mutableState.value.busy) return
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(busy = true, message = null)
            try {
                action()
            } catch (error: ApiException) {
                mutableState.value = mutableState.value.copy(busy = false, message = error.message ?: "İstek tamamlanamadı.")
            } catch (_: Exception) {
                mutableState.value = mutableState.value.copy(busy = false, message = "Bağlantı kurulamadı. Tekrar deneyebilirsin.")
            }
        }
    }

    class Factory(private val container: AppContainer) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = AuthViewModel(container) as T
    }
}
