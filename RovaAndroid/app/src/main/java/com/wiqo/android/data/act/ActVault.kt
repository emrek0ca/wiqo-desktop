package com.wiqo.android.data.act

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.wiqo.android.data.network.WiqoApi
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Wire-compatible with iOS ActKeys (HKDF-SHA256, AES-GCM combined blob, HMAC tokens). */
class ActVault(private val master: ByteArray) {
    init { require(master.size == 32) }
    private val content = derive("content")
    private val pathKey = derive("path")
    private val hashKey = derive("hash")

    private fun derive(info: String): ByteArray {
        val salt = "wiqo.act.v1".toByteArray()
        val extract = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(salt, "HmacSHA256")) }.doFinal(master)
        return Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(extract, "HmacSHA256")) }
            .doFinal(info.toByteArray() + byteArrayOf(1)).copyOf(32)
    }

    fun seal(text: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(content, "AES"))
        return Base64.encodeToString(cipher.iv + cipher.doFinal(text.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }

    fun open(blob: String): String? = runCatching {
        val bytes = Base64.decode(blob, Base64.DEFAULT)
        require(bytes.size > 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(content, "AES"), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
    }.getOrNull()

    fun pathToken(path: String): String = hmac(pathKey, path.toByteArray())
    fun contentHash(path: String, text: String): String = hmac(hashKey, (path + "\u0000" + text).toByteArray())
    private fun hmac(key: ByteArray, bytes: ByteArray): String = Mac.getInstance("HmacSHA256")
        .apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(bytes).joinToString("") { "%02x".format(it) }

    fun recoveryCode(): String {
        val check = MessageDigest.getInstance("SHA-256").digest(master).copyOf(2)
        return base32(master + check).chunked(5).joinToString("-")
    }

    internal fun masterCopy(): ByteArray = master.copyOf()

    companion object {
        fun fromRecoveryCode(code: String): ActVault? {
            val bytes = decodeBase32(code.uppercase().filter { it != '-' && !it.isWhitespace() }) ?: return null
            if (bytes.size != 34) return null
            val master = bytes.copyOf(32)
            val check = MessageDigest.getInstance("SHA-256").digest(master).copyOf(2)
            return if (MessageDigest.isEqual(check, bytes.copyOfRange(32, 34))) ActVault(master) else null
        }

        private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        private fun base32(bytes: ByteArray): String {
            val out = StringBuilder()
            var buffer = 0
            var bits = 0
            for (byte in bytes) {
                buffer = (buffer shl 8) or (byte.toInt() and 255)
                bits += 8
                while (bits >= 5) { out.append(ALPHABET[(buffer shr (bits - 5)) and 31]); bits -= 5 }
            }
            if (bits > 0) out.append(ALPHABET[(buffer shl (5 - bits)) and 31])
            return out.toString()
        }
        private fun decodeBase32(text: String): ByteArray? {
            val out = ArrayList<Byte>()
            var buffer = 0
            var bits = 0
            for (char in text) {
                val digit = ALPHABET.indexOf(char)
                if (digit < 0) return null
                buffer = (buffer shl 5) or digit
                bits += 5
                if (bits >= 8) { out.add(((buffer shr (bits - 8)) and 255).toByte()); bits -= 8 }
            }
            return out.toByteArray()
        }
    }
}

/** The account key survives sign-out; Android Keystore protects the stored master. */
class ActVaultStore(context: Context, private val api: WiqoApi) {
    private val prefs = context.applicationContext.getSharedPreferences("act_vault_v1", Context.MODE_PRIVATE)
    private fun account(): String = api.currentAccountId() ?: throw IllegalStateException("Act için oturum aç.")
    private fun suffix(): String = MessageDigest.getInstance("SHA-256").digest(account().toByteArray())
        .joinToString("") { "%02x".format(it) }.take(24)
    private fun alias(): String = "wiqo-act-master-${suffix()}"
    private fun keystore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun wrappingKey(): SecretKey {
        (keystore().getKey(alias(), null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias(), KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build())
        }.generateKey()
    }
    @Synchronized fun load(): ActVault? = runCatching {
        val data = Base64.decode(prefs.getString(suffix(), null) ?: return null, Base64.DEFAULT)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
        ActVault(cipher.doFinal(data.copyOfRange(12, data.size)))
    }.getOrNull()
    @Synchronized fun loadOrCreate(): ActVault {
        load()?.let { return it }
        if (prefs.contains(suffix())) throw IllegalStateException("Act anahtarı bu cihazda açılamadı; kurtarma kodunu gir.")
        return ActVault(ByteArray(32).also(SecureRandom()::nextBytes)).also(::save)
    }
    @Synchronized fun save(vault: ActVault) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        check(prefs.edit().putString(suffix(), Base64.encodeToString(cipher.iv + cipher.doFinal(vault.masterCopy()), Base64.NO_WRAP)).commit())
    }
}
