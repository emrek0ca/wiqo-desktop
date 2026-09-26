package com.wiqo.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatRichContentTest {
    @Test
    fun `message metadata preserves only renderable attachment artifact and task fields`() {
        val hash = "a".repeat(64)
        val metadata = parseMessageMetadata(
            """{"attachments":["brief.pdf"],"artifacts":[{"id":"artifact_1","filename":"summary.pdf","mimeType":"application/pdf","sha256":"$hash","downloadURL":"https://api.wiqoai.com/artifacts/artifact_1"}],"projectTask":{"id":42,"title":"Haftalık rapor"},"backendConfirmations":[{"id":"c1","title":"Dosyayı kaydet","summary":"Masaüstüne kaydedilsin mi?"}]}""",
        )

        assertEquals(listOf("brief.pdf"), metadata.attachmentNames)
        assertEquals("summary.pdf", metadata.artifacts.single().filename)
        assertEquals("artifact_1", metadata.artifacts.single().id)
        assertEquals("project-detail", metadata.related?.route)
        assertEquals("42", metadata.related?.id)
        assertEquals("Dosyayı kaydet", metadata.confirmations.single().title)
        assertTrue(parseMessageMetadata("not-json").artifacts.isEmpty())
    }
}
