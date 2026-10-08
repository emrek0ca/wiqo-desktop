package com.wiqo.android.data.network

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Signs the read-only, empty-payload device status commands used by the Android PC screen. */
internal fun signedStatusCommandRequest(
    id: String,
    type: String,
    token: String,
    nonce: String,
    createdAtEpochMs: Long,
): JsonObject {
    require(type == "getSystemStatus" || type == "ping")
    return signedDeviceCommandRequest(id, type, token, nonce, createdAtEpochMs)
}

/** Only the explicit PC controls exposed by the Android screen may be signed. */
internal fun signedDeviceCommandRequest(
    id: String,
    type: String,
    token: String,
    nonce: String,
    createdAtEpochMs: Long,
    value: Int? = null,
): JsonObject {
    require(UUID.fromString(id).toString() == id.lowercase())
    val payload: JsonObject
    val canonicalPayload: String
    when (type) {
        "getSystemStatus", "ping", "lockMac", "sleepMac", "displaySleep", "toggleMute" -> {
            require(value == null)
            payload = buildJsonObject { put("kind", "none") }
            canonicalPayload = """{"kind":"none"}"""
        }
        "setVolume", "setBrightness" -> {
            require(value != null && value in 0..100)
            val kind = if (type == "setVolume") "volume" else "brightness"
            payload = buildJsonObject { put("kind", kind); put("value", value) }
            canonicalPayload = """{"kind":"$kind","value":$value}"""
        }
        else -> throw IllegalArgumentException("Unsupported device command")
    }
    require(token.isNotBlank() && nonce.isNotBlank() && nonce.length <= 200)
    require(createdAtEpochMs > 0)

    val payloadDigest = sha256Hex(canonicalPayload.toByteArray(Charsets.UTF_8))
    val message = "wiqo-command:v2:$id:$type:$createdAtEpochMs:$nonce:$payloadDigest"
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(token.toByteArray(Charsets.UTF_8), "HmacSHA256"))
    val signature = mac.doFinal(message.toByteArray(Charsets.UTF_8)).toHex()
    val createdAt = DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(createdAtEpochMs))
    return buildJsonObject {
        put("id", id)
        put("type", type)
        put("payload", payload)
        put("createdAt", createdAt)
        put("signatureVersion", 2)
        put("createdAtEpochMs", createdAtEpochMs)
        put("signature", signature)
        put("nonce", nonce)
    }
}

private fun sha256Hex(value: ByteArray): String =
    java.security.MessageDigest.getInstance("SHA-256").digest(value).toHex()

private fun ByteArray.toHex(): String = joinToString("") { byte -> "%02x".format(byte) }
