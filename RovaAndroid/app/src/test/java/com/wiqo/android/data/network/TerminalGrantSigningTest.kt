package com.wiqo.android.data.network

import org.junit.Assert.assertEquals
import org.junit.Test

class TerminalGrantSigningTest {
    @Test
    fun matchesSharedTerminalGrantSignatureFormat() {
        assertEquals(
            "4e8e6f23890c4fbd0c863eb3c58502dfdf4440b3dacbf2313bbf42359e4a7896",
            signedTerminalGrant(
                grantId = "00000000-0000-0000-0000-000000000001",
                rootDirectory = "/Users/demo",
                mode = "read",
                expiresAt = 1_700_000_300,
                token = "pairing-token-for-test",
            ),
        )
    }
}
