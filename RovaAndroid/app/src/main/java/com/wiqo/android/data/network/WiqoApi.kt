package com.wiqo.android.data.network

import com.wiqo.android.data.security.SecureTokenStore
import com.wiqo.android.data.attachments.ChatAttachment
import com.wiqo.android.data.attachments.ChatFileContent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager
import java.io.IOException
import java.time.Instant
import java.util.concurrent.TimeUnit

data class ChatTurn(val role: String, val content: String)

data class ChatReply(
    val conversationId: String,
    val reply: String,
    val requestId: String?,
    val terminal: JsonObject?,
)

class WiqoApi(private val tokenStore: SecureTokenStore) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = false }
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(100, TimeUnit.SECONDS)
        .callTimeout(110, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    suspend fun login(email: String, password: String): String = authenticate(
        "auth/login",
        buildJsonObject { put("email", email.trim()); put("password", password) },
    )

    suspend fun register(email: String, password: String, inviteCode: String?): String {
        val body = buildJsonObject {
            put("email", email.trim())
            put("password", password)
            inviteCode?.trim()?.takeIf(String::isNotEmpty)?.let { put("inviteCode", it) }
        }
        return authenticate("auth/register", body)
    }

    suspend fun requestPasswordReset(email: String) {
        authorizedJson("auth/forgot-password", "POST", buildJsonObject { put("email", email.trim()) }, authorize = false)
    }

    suspend fun resetPassword(email: String, code: String, newPassword: String): String {
        val response = authorizedJson(
            "auth/reset-password",
            "POST",
            buildJsonObject { put("email", email.trim()); put("code", code.trim()); put("newPassword", newPassword) },
            authorize = false,
        ).jsonObject
        return response.string("token")?.also { tokenStore.write(SecureTokenStore.SESSION_TOKEN, it) }
            ?: throw ApiException("Sunucudan geçersiz bir yanıt alındı.", 502)
    }

    suspend fun get(path: String): JsonElement = authorizedJson(path, "GET")

    suspend fun conversationMessages(conversationId: String): List<JsonObject> {
        val encodedId = java.net.URLEncoder.encode(conversationId, Charsets.UTF_8.name())
        val root = get("conversations/$encodedId/messages") as? JsonObject ?: throw ApiException("Sohbet geçmişi okunamadı.", 502)
        val messages = root["messages"] as? JsonArray ?: return emptyList()
        return messages.mapNotNull { it as? JsonObject }
    }

    suspend fun post(path: String, body: JsonObject): JsonElement = authorizedJson(path, "POST", body)

    suspend fun put(path: String, body: JsonObject): JsonElement = authorizedJson(path, "PUT", body)

    suspend fun delete(path: String, body: JsonObject = JsonObject(emptyMap())): JsonElement = authorizedJson(path, "DELETE", body)

    suspend fun registerFcmToken(token: String) {
        post("notifications/fcm-token", buildJsonObject {
            put("token", token)
            put("applicationId", "com.wiqo.android")
        })
    }

    suspend fun revokeFcmToken(token: String?) {
        post("notifications/fcm-token/revoke", buildJsonObject {
            token?.takeIf(String::isNotBlank)?.let { put("token", it) }
        })
    }

    suspend fun verifyGooglePlayPurchase(purchaseToken: String): JsonElement = post(
        "billing/google-play/verify",
        buildJsonObject { put("purchaseToken", purchaseToken) },
    )

    suspend fun downloadArtifact(downloadUrl: String): ByteArray = withContext(Dispatchers.IO) {
        val url = runCatching { downloadUrl.toHttpUrl() }
            .getOrElse { throw ApiException("Dosya bağlantısı geçersiz.", 400, it) }
        if (url.scheme != "https" || url.host != BASE_URL.toHttpUrl().host || url.port != 443) {
            throw ApiException("Dosya bağlantısı güvenli değil.", 400)
        }
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer ${requireSessionToken()}")
            .get()
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw ApiException(if (response.code == 404) "Dosyanın süresi dolmuş; yeniden oluşturabilirsin." else "Dosya indirilemedi.", response.code)
            }
            val body = response.body ?: throw ApiException("Sunucudan boş dosya alındı.", 502)
            if (body.contentLength() > MAX_ARTIFACT_BYTES) throw ApiException("Dosya güvenli boyut sınırını aşıyor.", 413)
            val bytes = body.byteStream().use { it.readNBytes(MAX_ARTIFACT_BYTES + 1) }
            if (bytes.size > MAX_ARTIFACT_BYTES) throw ApiException("Dosya güvenli boyut sınırını aşıyor.", 413)
            bytes
        }
    }

    suspend fun sendCompanionStatus(deviceId: String): JsonElement {
        val response = sendCompanionCommand(deviceId, "getSystemStatus") as? JsonObject
            ?: throw ApiException("PC yanıtı okunamadı.", 502)
        val data = response["data"] as? JsonObject ?: throw ApiException("PC durum bilgisi eksik.", 502)
        return data["value"] ?: data
    }

    suspend fun sendCompanionCommand(deviceId: String, type: String, value: Int? = null): JsonElement {
        if (tokenStore.read(SecureTokenStore.COMPANION_DEVICE_ID) != deviceId) {
            throw ApiException("Bu telefon seçilen PC ile eşleşmemiş.", 403)
        }
        val pairingToken = tokenStore.read(SecureTokenStore.PAIRING_TOKEN)
            ?: throw ApiException("Önce bu Wiqo hesabıyla PC eşleştir.", 409)
        val nonceBytes = ByteArray(32).also(SecureRandom()::nextBytes)
        val nonce = android.util.Base64.encodeToString(
            nonceBytes,
            android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING,
        )
        val request = signedDeviceCommandRequest(
            id = java.util.UUID.randomUUID().toString(),
            type = type,
            token = pairingToken,
            nonce = nonce,
            createdAtEpochMs = System.currentTimeMillis(),
            value = value,
        )
        val response = post("devices/${java.net.URLEncoder.encode(deviceId, Charsets.UTF_8.name())}/command", request) as? JsonObject
            ?: throw ApiException("PC yanıtı okunamadı.", 502)
        if (response.string("status") != "completed") {
            val error = response["error"] as? JsonObject
            throw ApiException(error?.string("message") ?: "PC durum bilgisi alınamadı.", 502)
        }
        return response
    }

    fun backendConfirmationBody(confirmationId: String, approved: Boolean, details: JsonObject): JsonObject = buildJsonObject {
        put("confirmationId", confirmationId)
        put("approved", approved)
        if (approved && details.string("wiqoGrantId") != null) {
            val pairingToken = tokenStore.read(SecureTokenStore.PAIRING_TOKEN)
                ?: throw ApiException("Terminal iznini imzalamak için önce PC ile eşleştir.", 409)
            val grantId = details.string("wiqoGrantId")!!
            val root = details.string("wiqoGrantRoot")
                ?: throw ApiException("Terminal izin bilgisi eksik.", 502)
            val mode = details.string("wiqoGrantMode")
                ?: throw ApiException("Terminal izin bilgisi eksik.", 502)
            val expiry = details.string("wiqoGrantExpiresAt")?.toIntOrNull()
                ?: throw ApiException("Terminal izin süresi eksik.", 502)
            val expectedDeviceId = details.string("wiqoGrantDeviceId")
            val pairedCompanionId = tokenStore.read(SecureTokenStore.COMPANION_DEVICE_ID)
            if (expectedDeviceId != null && pairedCompanionId?.equals(expectedDeviceId, ignoreCase = true) != true) {
                throw ApiException("Terminal izni başka bir PC için oluşturulmuş.", 403)
            }
            put("terminalGrant", buildJsonObject {
                put("grantId", grantId)
                put("signature", signedTerminalGrant(grantId, root, mode, expiry, pairingToken))
                put("scope", "task")
            })
        }
    }

    suspend fun claimRelayOrLocalQr(rawCode: String): String {
        if (rawCode.startsWith("rova-pair:v1:")) return claimLocalQr(rawCode)
        if (!rawCode.startsWith("rova-relay:v1:")) throw ApiException("Bu Wiqo eşleşme QR kodu değil.", 400)
        val encoded = rawCode.removePrefix("rova-relay:v1:")
        val qr = runCatching {
            json.parseToJsonElement(
                String(
                    android.util.Base64.decode(encoded, android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING),
                    Charsets.UTF_8,
                ),
            ).jsonObject
        }.getOrElse { throw ApiException("Eşleşme QR kodu geçersiz.", 400, it) }
        val sessionId = qr.string("sessionID", "sessionId") ?: throw ApiException("Eşleşme QR kodu geçersiz.", 400)
        val secret = qr.string("secret") ?: throw ApiException("Eşleşme QR kodu geçersiz.", 400)
        val expiry = qr.string("expiresAt")?.let { runCatching { Instant.parse(it) }.getOrNull() }
            ?: throw ApiException("Eşleşme QR kodu geçersiz.", 400)
        if (expiry <= Instant.now() || secret.length < 32 || sessionId.length > 80) {
            throw ApiException("Eşleşme QR kodunun süresi dolmuş veya kod geçersiz.", 410)
        }
        val response = post("device-pairing/sessions/${java.net.URLEncoder.encode(sessionId, Charsets.UTF_8.name())}/claim", buildJsonObject { put("secret", secret) }).jsonObject
        val deviceId = response.string("deviceId") ?: throw ApiException("PC eşleştirmesi tamamlanamadı.", 502)
        val pairingToken = response.string("pairingToken") ?: throw ApiException("PC eşleştirmesi tamamlanamadı.", 502)
        tokenStore.write(SecureTokenStore.PAIRING_TOKEN, pairingToken)
        tokenStore.write(SecureTokenStore.PAIRING_DEVICE_ID, deviceId)
        tokenStore.write(SecureTokenStore.PAIRING_FINGERPRINT, "relay")
        tokenStore.write(SecureTokenStore.COMPANION_DEVICE_ID, deviceId)
        return "${response.string("displayName") ?: "PC"} eşlendi."
    }

    private suspend fun claimLocalQr(rawCode: String): String = withContext(Dispatchers.IO) {
        val encoded = rawCode.removePrefix("rova-pair:v1:")
        val qr = runCatching {
            json.parseToJsonElement(
                String(
                    android.util.Base64.decode(encoded, android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING),
                    Charsets.UTF_8,
                ),
            ).jsonObject
        }.getOrElse { throw ApiException("Yerel eşleşme QR kodu geçersiz.", 400, it) }
        val version = qr.int("version")
        val host = qr.string("host")
        val port = qr.int("port")
        val fingerprint = qr.string("certificateFingerprint")?.lowercase()
        val pairingCode = qr.string("pairingCode")
        val expiresAt = qr.string("expiresAt")?.let { runCatching { Instant.parse(it) }.getOrNull() }
        if (version != 1 || host.isNullOrBlank() || host.length > 253 || port == null || port !in 1..65535 ||
            fingerprint?.matches(Regex("[0-9a-f]{64}")) != true || pairingCode?.matches(Regex("[0-9]{6}")) != true ||
            expiresAt == null || expiresAt <= Instant.now()
        ) throw ApiException("Yerel eşleşme QR kodu geçersiz veya süresi dolmuş.", 410)

        val requestId = java.util.UUID.randomUUID().toString()
        val deviceId = tokenStore.stableDeviceId()
        val backendToken = tokenStore.read(SecureTokenStore.SESSION_TOKEN)
            ?: throw ApiException("Önce Wiqo hesabında oturum aç.", 401)
        val deviceName = listOf(android.os.Build.MANUFACTURER.trim(), android.os.Build.MODEL.trim())
            .filter(String::isNotBlank).joinToString(" ").ifBlank { "Android" }.take(128)
        val socket = openPinnedSocket(host, port, fingerprint)
        try {
            val hello = readEnvelope(socket)
            val helloMessage = hello["message"] as? JsonObject
            val companionInfo = helloMessage?.takeIf { it.string("kind") == "hello" }
                ?.get("value") as? JsonObject
                ?: throw ApiException("PC karşılama mesajı doğrulanamadı.", 502)
            val companionId = companionInfo.string("id") ?: throw ApiException("PC kimliği alınamadı.", 502)

            writeEnvelope(socket, wireEnvelope(requestId, "pair", buildJsonObject {
                put("code", pairingCode)
                put("deviceName", deviceName)
                put("deviceID", deviceId)
            }))
            val reply = readEnvelope(socket)
            if (reply.int("version") != 1 || reply.string("requestID") != requestId) {
                throw ApiException("PC eşleşme yanıtı doğrulanamadı.", 502)
            }
            val message = reply["message"] as? JsonObject ?: throw ApiException("PC eşleşme yanıtı eksik.", 502)
            if (message.string("kind") == "failure") {
                val error = message["value"] as? JsonObject
                throw ApiException(error?.string("message") ?: "PC eşleştirmeyi reddetti.", 403)
            }
            if (message.string("kind") != "pairAccepted") throw ApiException("PC eşleşme yanıtı tanınmadı.", 502)
            val value = message["value"] as? JsonObject ?: throw ApiException("PC eşleşme yanıtı eksik.", 502)
            val token = value.string("token") ?: throw ApiException("PC eşleşme yanıtı eksik.", 502)
            val responseDeviceId = value.string("deviceID")
            val responseFingerprint = value.string("certificateFingerprint")?.lowercase()
            if (responseDeviceId?.equals(deviceId, ignoreCase = true) != true || responseFingerprint != fingerprint || token.length !in 32..512) {
                throw ApiException("PC eşleşme bilgileri doğrulanamadı.", 502)
            }

            val authRequestId = java.util.UUID.randomUUID().toString()
            writeEnvelope(socket, wireEnvelope(authRequestId, "authenticate", buildJsonObject {
                put("token", token)
                put("deviceID", deviceId)
            }))
            val authenticated = readEnvelope(socket)
            val authMessage = authenticated["message"] as? JsonObject
            val authValue = authMessage?.takeIf { it.string("kind") == "authenticated" }
                ?.get("value") as? JsonObject
            val authenticatedDevice = authValue?.get("deviceInfo") as? JsonObject
            if (authenticated.int("version") != 1 || authenticated.string("requestID") != authRequestId ||
                authenticatedDevice?.string("id")?.equals(companionId, ignoreCase = true) != true
            ) throw ApiException("PC güvenli bağlantıyı doğrulayamadı.", 403)

            writeEnvelope(socket, wireEnvelope(java.util.UUID.randomUUID().toString(), "backendToken", JsonPrimitive(backendToken)))
            tokenStore.write(SecureTokenStore.PAIRING_TOKEN, token)
            tokenStore.write(SecureTokenStore.PAIRING_DEVICE_ID, deviceId)
            tokenStore.write(SecureTokenStore.PAIRING_FINGERPRINT, fingerprint)
            tokenStore.write(SecureTokenStore.COMPANION_DEVICE_ID, companionId)
            val displayName = companionInfo.string("displayName") ?: host
            "$displayName bilgisayarı eşlendi."
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun openPinnedSocket(host: String, port: Int, expectedFingerprint: String): SSLSocket {
        val trustManager = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val certificate = chain?.firstOrNull() ?: throw CertificateException("PC sertifikası eksik.")
                val actual = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
                    .joinToString("") { byte -> "%02x".format(byte) }
                if (!MessageDigest.isEqual(actual.toByteArray(), expectedFingerprint.toByteArray())) {
                    throw CertificateException("PC sertifika parmak izi eşleşmedi.")
                }
            }
        }
        val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trustManager), SecureRandom()) }
        val socket = context.socketFactory.createSocket() as SSLSocket
        try {
            socket.connect(java.net.InetSocketAddress(host, port), LOCAL_CONNECT_TIMEOUT_MS)
            socket.soTimeout = LOCAL_READ_TIMEOUT_MS
            socket.startHandshake()
            return socket
        } catch (error: javax.net.ssl.SSLHandshakeException) {
            runCatching { socket.close() }
            throw ApiException("PC sertifika doğrulaması başarısız oldu.", 403, error)
        } catch (error: Exception) {
            runCatching { socket.close() }
            throw ApiException("PC ile yerel bağlantı kurulamadı. Aynı ağa bağlı olduğunu kontrol et.", 503, error)
        }
    }

    private fun writeEnvelope(socket: SSLSocket, envelope: JsonObject) {
        val payload = json.encodeToString(JsonObject.serializer(), envelope).toByteArray(Charsets.UTF_8)
        if (payload.size > MAX_FRAME_BYTES) throw ApiException("Eşleşme isteği çok büyük.", 413)
        val length = payload.size
        socket.outputStream.write(byteArrayOf((length ushr 24).toByte(), (length ushr 16).toByte(), (length ushr 8).toByte(), length.toByte()))
        socket.outputStream.write(payload)
        socket.outputStream.flush()
    }

    private fun readEnvelope(socket: SSLSocket): JsonObject {
        try {
            val input = socket.inputStream
            val header = ByteArray(4)
            readFully(input, header)
            val responseLength = ((header[0].toLong() and 0xff) shl 24) or ((header[1].toLong() and 0xff) shl 16) or
                ((header[2].toLong() and 0xff) shl 8) or (header[3].toLong() and 0xff)
            if (responseLength !in 1..MAX_FRAME_BYTES.toLong()) throw ApiException("PC eşleşme yanıtı geçersiz.", 502)
            val frame = ByteArray(responseLength.toInt()).also { readFully(input, it) }
            return runCatching { json.parseToJsonElement(frame.toString(Charsets.UTF_8)).jsonObject }
                .getOrElse { throw ApiException("PC'den geçersiz eşleşme yanıtı alındı.", 502, it) }
        } catch (error: ApiException) {
            throw error
        } catch (error: Exception) {
            throw ApiException("PC bağlantısı yanıt tamamlanmadan kapandı.", 503, error)
        }
    }

    private fun wireEnvelope(requestId: String, kind: String, value: JsonElement) = buildJsonObject {
        put("version", 1)
        put("requestID", requestId)
        put("message", buildJsonObject { put("kind", kind); put("value", value) })
    }

    private fun readFully(input: java.io.InputStream, target: ByteArray) {
        var offset = 0
        while (offset < target.size) {
            val count = input.read(target, offset, target.size - offset)
            if (count < 0) throw IOException("PC bağlantısı yanıt tamamlanmadan kapandı.")
            offset += count
        }
    }

    fun currentAccountId(): String? {
        val token = tokenStore.read(SecureTokenStore.SESSION_TOKEN) ?: return null
        val payload = token.split('.').getOrNull(1) ?: return null
        val decoded = runCatching { android.util.Base64.decode(payload, android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING) }.getOrNull() ?: return null
        val userId = runCatching { json.parseToJsonElement(decoded.toString(Charsets.UTF_8)).jsonObject["userId"] }.getOrNull()
        return (userId as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank)
    }

    suspend fun converse(
        conversationId: String,
        messages: List<ChatTurn>,
        attachments: List<ChatAttachment> = emptyList(),
        files: List<ChatFileContent> = emptyList(),
        createAgent: Boolean = false,
        onProgress: (String) -> Unit,
        onDelta: (String) -> Unit = {},
        onEvent: (JsonObject) -> Unit = {},
    ): ChatReply = withContext(Dispatchers.IO) {
        val id = java.util.UUID.randomUUID().toString()
        val requestBody = buildJsonObject {
            put("conversationId", conversationId)
            put("requestId", id)
            put("messages", buildJsonArray { messages.forEach { add(buildJsonObject { put("role", it.role); put("content", it.content) }) } })
            put("attachments", buildJsonArray {
                attachments.forEach { attachment ->
                    add(buildJsonObject {
                        put("name", attachment.name)
                        put("mimeType", attachment.mimeType)
                        put("dataBase64", attachment.dataBase64)
                    })
                }
            })
            put("files", buildJsonArray { files.forEach { add(it.toJson()) } })
            put("availableApps", JsonArray(emptyList()))
            put("availableCapabilities", JsonArray(emptyList()))
            put("clientFeatures", buildJsonArray { add(JsonPrimitive("artifact-directory-v1")) })
            put("locale", java.util.Locale.getDefault().toLanguageTag())
            if (createAgent) put("composerIntent", "create_agent")
            tokenStore.read(SecureTokenStore.COMPANION_DEVICE_ID)?.let { put("deviceId", it) }
        }
        val request = Request.Builder()
            .url("$BASE_URL/copilot/chat")
            .header("Accept", "text/event-stream")
            .header("Authorization", "Bearer ${requireSessionToken()}")
            .post(json.encodeToString(JsonObject.serializer(), requestBody).toRequestBody(JSON_MEDIA_TYPE))
            .build()
        val call = client.newCall(request)
        val job = currentCoroutineContext()[kotlinx.coroutines.Job]
        val cancellation = job?.invokeOnCompletion { cause ->
            if (cause is kotlinx.coroutines.CancellationException) call.cancel()
        }
        try {
            call.execute().use { response ->
                if (!response.isSuccessful) {
                    val error = response.apiError(json)
                    if (error.statusCode >= 500) return@withContext waitForCopilotRequest(id, conversationId, onProgress, onEvent)
                    throw error
                }
                val source = response.body?.source() ?: throw ApiException("Sunucudan boş yanıt alındı.", 502)
                var eventName = "message"
                val dataLines = StringBuilder()
                var final: JsonObject? = null
                while (!source.exhausted()) {
                    currentCoroutineContext().ensureActive()
                    val line = source.readUtf8Line() ?: break
                    when {
                        line.startsWith("event:") -> eventName = line.removePrefix("event:").trim()
                        line.startsWith("data:") -> {
                            if (dataLines.isNotEmpty()) dataLines.append('\n')
                            dataLines.append(line.removePrefix("data:").trimStart())
                        }
                        line.isEmpty() -> {
                            val data = dataLines.toString()
                            if (data.isNotEmpty()) {
                                val value = runCatching { json.parseToJsonElement(data) as? JsonObject }.getOrNull()
                                when ((value?.string("type") ?: eventName).lowercase()) {
                                    "status", "progress" -> value?.string("text", "message", "label")?.let(onProgress)
                                    "delta", "text_delta" -> value?.string("text", "delta", "content")?.let(onDelta)
                                    "reset" -> onProgress("")
                                    "error" -> throw ApiException(value?.string("message") ?: "Yanıt alınamadı.", 502)
                                    "done", "complete", "completed", "result" -> if (value != null) final = value
                                    else -> if (value != null) onEvent(value)
                                }
                            }
                            eventName = "message"
                            dataLines.setLength(0)
                        }
                    }
                    if (final != null) break
                }
                val payload = final ?: return@withContext waitForCopilotRequest(id, conversationId, onProgress, onEvent)
                val reply = payload.string("reply", "text", "content")
                    ?: throw ApiException("Sunucudan geçersiz bir yanıt alındı.", 502)
                ChatReply(conversationId, reply, payload.string("requestId") ?: id, payload)
            }
        } catch (error: IOException) {
            currentCoroutineContext().ensureActive()
            waitForCopilotRequest(id, conversationId, onProgress, onEvent)
        } finally {
            cancellation?.dispose()
            call.cancel()
        }
    }

    private suspend fun waitForCopilotRequest(
        requestId: String,
        conversationId: String,
        onProgress: (String) -> Unit,
        onEvent: (JsonObject) -> Unit,
    ): ChatReply {
        val deadline = System.nanoTime() + TimeUnit.MINUTES.toNanos(16)
        var missingCount = 0
        onProgress("Bağlantı kesildi; Wiqo işlemin sonucunu koruyor…")
        while (System.nanoTime() < deadline) {
            currentCoroutineContext().ensureActive()
            try {
                val root = get("copilot/requests/${java.net.URLEncoder.encode(requestId, Charsets.UTF_8.name())}") as? JsonObject
                    ?: throw ApiException("İşlem durumu okunamadı.", 502)
                when (root.string("status")) {
                    "done" -> {
                        val response = root["response"] as? JsonObject ?: throw ApiException("İşlem yanıtı eksik.", 502)
                        val reply = response.string("reply") ?: throw ApiException("İşlem yanıtı eksik.", 502)
                        return ChatReply(conversationId, reply, requestId, response)
                    }
                    "failed" -> {
                        val error = root["error"] as? JsonObject
                        throw ApiException(error?.string("message") ?: "İşlem tamamlanamadı.", 502)
                    }
                    "awaiting_backend_confirmation" -> {
                        onProgress("İşlem onayını bekliyor…")
                        val response = root["response"] as? JsonObject
                        if (response != null) onEvent(buildJsonObject {
                            put("type", "confirmation_needed")
                            put("backendConfirmations", response["backendConfirmations"] ?: JsonArray(emptyList()))
                        })
                    }
                    "awaiting_weather_location" -> {
                        onProgress("Hava durumu için konum bekleniyor…")
                        onEvent(buildJsonObject { put("type", "location_required"); put("requestId", requestId) })
                    }
                    "running", "queued", "waiting_approval" -> onProgress("İşlem bağlantıdan bağımsız devam ediyor…")
                    else -> {
                        missingCount += 1
                        if (missingCount >= 3) throw ApiException("İşlem bulunamadı.", 404)
                    }
                }
            } catch (error: ApiException) {
                if (error.statusCode != 404) throw error
                missingCount += 1
                if (missingCount >= 3) throw error
            } catch (error: IOException) {
                currentCoroutineContext().ensureActive()
            }
            delay(if (missingCount > 0) 500 else 2_000)
        }
        throw ApiException("İşlem sunucuda devam ediyor olabilir. Sohbeti açıp biraz sonra tekrar kontrol et.", 408)
    }

    private suspend fun authenticate(path: String, body: JsonObject): String {
        val response = authorizedJson(path, "POST", body, authorize = false).jsonObject
        return response.string("token")?.also { tokenStore.write(SecureTokenStore.SESSION_TOKEN, it) }
            ?: throw ApiException("Sunucudan geçersiz bir yanıt alındı.", 502)
    }

    private suspend fun authorizedJson(
        path: String,
        method: String,
        body: JsonObject? = null,
        authorize: Boolean = true,
    ): JsonElement = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url("$BASE_URL/${path.trimStart('/')}").header("Accept", "application/json")
        if (authorize) builder.header("Authorization", "Bearer ${requireSessionToken()}")
        val request = if (method == "GET") builder.get().build() else builder
            .header("Content-Type", "application/json")
            .method(method, (body?.let { json.encodeToString(JsonObject.serializer(), it) } ?: "{}").toRequestBody(JSON_MEDIA_TYPE))
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw response.apiError(json)
            val raw = response.body?.string().orEmpty()
            if (raw.isBlank()) JsonObject(emptyMap()) else runCatching { json.parseToJsonElement(raw) }
                .getOrElse { throw ApiException("Sunucudan geçersiz bir yanıt alındı.", 502, it) }
        }
    }

    private fun requireSessionToken(): String = tokenStore.read(SecureTokenStore.SESSION_TOKEN)
        ?: throw ApiException("Önce Wiqo hesabına giriş yap.", 401)

    private fun okhttp3.Response.apiError(json: Json): ApiException {
        val message = body?.string()?.let { raw ->
            runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull()
                ?.let { root -> root["error"]?.jsonObject?.string("message") ?: root.string("message") }
        }
        return ApiException(message ?: if (code == 401) "Oturumun sona erdi. Yeniden giriş yap." else "İstek tamamlanamadı.", code)
    }

    companion object {
        const val BASE_URL = "https://api.wiqoai.com"
        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
        private const val MAX_FRAME_BYTES = 1_048_576
        private const val MAX_ARTIFACT_BYTES = 50 * 1024 * 1024
        private const val LOCAL_CONNECT_TIMEOUT_MS = 4_000
        private const val LOCAL_READ_TIMEOUT_MS = 6_000
    }
}

class ApiException(message: String, val statusCode: Int = 0, cause: Throwable? = null) : Exception(message, cause)

private fun JsonObject.string(vararg keys: String): String? = keys.firstNotNullOfOrNull { key ->
    this[key]?.let { element -> (element as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank) }
}

private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.contentOrNull?.toIntOrNull()
