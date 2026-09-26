package com.wiqo.android.data.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Encrypts session and pairing credentials with a non-exportable Android Keystore key. */
class SecureTokenStore(context: Context) {
    private val preferences = context.getSharedPreferences("wiqo_secure_tokens", Context.MODE_PRIVATE)

    @Synchronized
    fun read(key: String = SESSION_TOKEN): String? {
        val packed = preferences.getString(key, null) ?: return null
        return runCatching {
            val bytes = Base64.decode(packed, Base64.NO_WRAP)
            require(bytes.size > IV_BYTES)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, bytes.copyOfRange(0, IV_BYTES)))
            cipher.doFinal(bytes.copyOfRange(IV_BYTES, bytes.size)).toString(Charsets.UTF_8)
        }.getOrElse {
            preferences.edit().remove(key).apply()
            null
        }
    }

    @Synchronized
    fun write(key: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val encrypted = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        check(preferences.edit().putString(key, Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit())
    }

    @Synchronized
    fun stableDeviceId(): String {
        read(LOCAL_DEVICE_ID)?.let { existing ->
            if (runCatching { java.util.UUID.fromString(existing) }.isSuccess) return existing
        }
        return java.util.UUID.randomUUID().toString().also { write(LOCAL_DEVICE_ID, it) }
    }

    @Synchronized
    fun remove(key: String) {
        preferences.edit().remove(key).apply()
    }

    @Synchronized
    fun clearCredentials() {
        preferences.edit().clear().commit()
        runCatching { keyStore().deleteEntry(KEY_ALIAS) }
    }

    private fun secretKey(): SecretKey {
        val existing = keyStore().getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    companion object {
        const val SESSION_TOKEN = "session_token"
        const val PAIRING_TOKEN = "paired_pc_token"
        const val PAIRING_FINGERPRINT = "paired_pc_fingerprint"
        const val PAIRING_DEVICE_ID = "paired_pc_device_id"
        const val COMPANION_DEVICE_ID = "companion_device_id"
        private const val LOCAL_DEVICE_ID = "local_device_id"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "wiqo-account-and-pairing-v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
    }
}
