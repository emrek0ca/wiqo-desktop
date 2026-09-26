package com.wiqo.android.data.network

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Mirrors RovaShared.RovaTerminalPolicy for the default task-scoped approval. */
internal fun signedTerminalGrant(
    grantId: String,
    rootDirectory: String,
    mode: String,
    expiresAt: Int,
    token: String,
): String {
    val canonicalGrantId = java.util.UUID.fromString(grantId).toString()
    require(mode == "read" || mode == "full")
    require(rootDirectory.isNotBlank() && rootDirectory.length <= 2_048)
    require(expiresAt > 0 && token.isNotBlank())
    val message = "wiqo-terminal-grant:v1:$canonicalGrantId:$rootDirectory:$mode:$expiresAt"
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(token.toByteArray(Charsets.UTF_8), "HmacSHA256"))
    return mac.doFinal(message.toByteArray(Charsets.UTF_8)).joinToString("") { byte -> "%02x".format(byte) }
}
