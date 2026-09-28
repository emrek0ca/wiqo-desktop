package com.wiqo.android.data.network

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class DeviceCommandSigningTest {
    @Test
    fun statusCommandSignatureMatchesWindowsProtocolV2CanonicalVector() {
        val request = signedStatusCommandRequest(
            id = "00000000-0000-0000-0000-000000000001",
            type = "getSystemStatus",
            token = "pairing-token-for-test",
            nonce = "nonce",
            createdAtEpochMs = 1_700_000_000_000,
        )

        assertEquals("db1447533c1bb0829b87650bc3f29b2f7e0584e57047ac08ecd7671684d68984", request["signature"]?.jsonPrimitive?.content)
        assertEquals("2023-11-14T22:13:20Z", request["createdAt"]?.jsonPrimitive?.content)
        assertEquals("none", request["payload"]?.jsonObject?.get("kind")?.jsonPrimitive?.content)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsCommandTypesOutsideReadOnlyAllowList() {
        signedStatusCommandRequest(
            id = "00000000-0000-0000-0000-000000000001",
            type = "deleteFile",
            token = "pairing-token-for-test",
            nonce = "nonce",
            createdAtEpochMs = 1_700_000_000_000,
        )
    }
}
