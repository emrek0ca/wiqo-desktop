import io
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
import document_adapter as adapter


class DocumentAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def test_optional_dependency_failure_is_structured(self):
        source = self.root / "sample.txt"
        source.write_text("Türkçe öğrenci belgesi", encoding="utf-8")
        with patch.object(adapter, "dependencies", return_value={"markitdown": False, "docling": False}):
            result = adapter.handle({"action": "extractDocument", "path": str(source)})
        self.assertFalse(result["ok"])
        self.assertEqual(result["errorCode"], "DEPENDENCY_MISSING")

    def test_no_remote_paths_or_archives(self):
        self.assertFalse(adapter.handle({"action": "extractDocument", "path": "https://example.com/file.pdf"})["ok"])
        source = self.root / "bad.docx"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("../secret", "outside")
        self.assertEqual(adapter.handle({"action": "extractDocument", "path": str(source)})["errorCode"], "DOCUMENT_UNSAFE")

    def test_stream_scope_and_turkish_text(self):
        source = self.root / "sample.txt"
        source.write_text("Öğrenci belgesi: Çağrı Şen, İstanbul. Ücret 1.250 TL.", encoding="utf-8")
        result = adapter.handle({"action": "extractDocument", "path": str(source), "maxChars": 500})
        self.assertTrue(result["ok"], result)
        self.assertIn("Çağrı Şen", result["text"])
        self.assertFalse(result["truncated"])
        self.assertEqual(len(result["sha256"]), 64)
        clipped = adapter.handle({"action": "extractDocument", "path": str(source), "maxChars": 10})
        self.assertTrue(clipped["truncated"])

    def test_missing_ocr_cannot_be_success(self):
        source = self.root / "scan.pdf"
        source.write_bytes(b"%PDF-1.7\n")
        with patch.object(adapter, "dependencies", return_value={"markitdown": True, "docling": False}), patch.object(adapter, "markitdown", side_effect=adapter.DocumentError("DOCUMENT_EMPTY")):
            result = adapter.handle({"action": "extractDocument", "path": str(source)})
        self.assertFalse(result["ok"])
        self.assertEqual(result["errorCode"], "DOCUMENT_EMPTY")

    def test_layout_falls_back_honestly(self):
        source = self.root / "text.pdf"
        source.write_bytes(b"%PDF-1.7\n")
        with patch.object(adapter, "dependencies", return_value={"markitdown": True, "docling": False}), patch.object(adapter, "markitdown", return_value=("--- Sayfa 1 ---\nBelgenin okunabilir metni.", 1)):
            result = adapter.handle({"action": "extractDocument", "path": str(source), "quality": "layout"})
        self.assertTrue(result["ok"])
        self.assertIn("LAYOUT_FALLBACK", result["warnings"])

    def test_offline_guard_restores_socket(self):
        import socket
        previous = socket.socket.connect
        with adapter.offline():
            with self.assertRaises(adapter.DocumentError):
                socket.create_connection(("example.com", 443))
        self.assertIs(socket.socket.connect, previous)

    def test_real_docx_table_and_heading(self):
        source = self.root / "report.docx"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("[Content_Types].xml", '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
            archive.writestr("word/document.xml", '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Öğrenci bilgileri</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Ad</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Çağrı Şen</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>')
        result = adapter.handle({"action": "extractDocument", "path": str(source)})
        self.assertTrue(result["ok"], result)
        self.assertIn("Çağrı Şen", result["text"])
        self.assertIn("|", result["text"])


if __name__ == "__main__":
    unittest.main()
