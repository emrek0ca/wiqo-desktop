package com.wiqo.android.data.billing

import org.junit.Assert.assertEquals
import org.junit.Test

class GooglePlayAccountIdTest {
    @Test
    fun matchesBackendExternalAccountBinding() {
        assertEquals(
            "8130e95e048f95f869f49556dbc872db21858bd26d0079d83610fee1c7ef98e8",
            googlePlayAccountId("1234"),
        )
    }
}
