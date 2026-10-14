"""Optional local document adapter. Caller owns authorization, deadline and cancellation.

No service, model-supplied code, URL conversion, plugins or cloud document APIs.
Only a validated snapshot of the explicitly selected file reaches the libraries.
"""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import logging
import os
from pathlib import Path
import socket
import stat
import sys
import zipfile

MAX_BYTES = 25 * 1024 * 1024
MAX_TEXT = 500_000
MAX_PAGES = 200
FORMATS = {".pdf", ".docx", ".pptx", ".xlsx", ".csv", ".txt", ".md", ".html"}


class DocumentError(Exception):
    def __init__(self, code: str):
        self.code = code


MESSAGES = {
    "DOCUMENT_UNSUPPORTED": "Bu belge biçimi desteklenmiyor.",
    "DOCUMENT_TOO_LARGE": "Belge güvenli boyut sınırını aşıyor.",
    "DOCUMENT_UNSAFE": "Belge yolu veya arşiv içeriği güvenli değil.",
    "DOCUMENT_EMPTY": "Belgeden okunabilir içerik çıkarılamadı; OCR gerekebilir.",
    "DOCUMENT_PARSE_FAILED": "Belge açılamadı; bozuk veya parola korumalı olabilir.",
    "DEPENDENCY_MISSING": "Gelişmiş belge okuyucusu kurulu değil; yerel belge paketini kurun.",
    "DOCUMENT_MODELS_MISSING": "Belge düzeni/OCR modelleri cihazda hazır değil.",
    "DOCUMENT_NETWORK_BLOCKED": "Belge okuma sırasında dış bağlantı engellendi.",
}


def dependencies() -> dict[str, bool]:
    return {name: importlib.util.find_spec(name) is not None for name in ("markitdown", "docling")}


def snapshot(raw_path: str) -> tuple[bytes, str]:
    path = Path(raw_path)
    if not path.is_absolute() or path.is_symlink() or path.suffix.lower() not in FORMATS:
        raise DocumentError("DOCUMENT_UNSUPPORTED" if path.suffix.lower() not in FORMATS else "DOCUMENT_UNSAFE")
    # No URL interpretation and no symlink traversal through ancestors.
    if any(parent.is_symlink() for parent in path.parents):
        raise DocumentError("DOCUMENT_UNSAFE")
    with os.fdopen(os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)), "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise DocumentError("DOCUMENT_UNSAFE")
        if info.st_size > MAX_BYTES:
            raise DocumentError("DOCUMENT_TOO_LARGE")
        data = source.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise DocumentError("DOCUMENT_TOO_LARGE")
    if not data:
        raise DocumentError("DOCUMENT_EMPTY")
    suffix = path.suffix.lower()
    if suffix == ".pdf" and not data[:1024].lstrip().startswith(b"%PDF-"):
        raise DocumentError("DOCUMENT_PARSE_FAILED")
    if suffix in {".docx", ".pptx", ".xlsx"}:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = archive.infolist()
            if len(entries) > 10_000 or sum(item.file_size for item in entries) > 100 * 1024 * 1024:
                raise DocumentError("DOCUMENT_TOO_LARGE")
            for item in entries:
                if item.flag_bits & 1 or item.file_size > 32 * 1024 * 1024:
                    raise DocumentError("DOCUMENT_UNSAFE")
                if item.filename.startswith(("/", "\\")) or ".." in item.filename.replace("\\", "/").split("/"):
                    raise DocumentError("DOCUMENT_UNSAFE")
    return data, suffix


@contextlib.contextmanager
def offline():
    """Libraries operate offline. This is defense in depth, not an OS sandbox."""
    connect, connect_ex, create = socket.socket.connect, socket.socket.connect_ex, socket.create_connection
    def blocked(*_args, **_kwargs):
        raise DocumentError("DOCUMENT_NETWORK_BLOCKED")
    socket.socket.connect = blocked
    socket.socket.connect_ex = blocked
    socket.create_connection = blocked
    try:
        yield
    finally:
        socket.socket.connect, socket.socket.connect_ex, socket.create_connection = connect, connect_ex, create


def markitdown(data: bytes, suffix: str) -> tuple[str, int | None]:
    if suffix == ".pdf":
        # Inspect EVERY page: text on page one must not hide scanned pages later.
        from pdfminer.high_level import extract_pages
        from pdfminer.layout import LTTextContainer, LTContainer, LTImage
        pages = []
        for page in extract_pages(io.BytesIO(data), maxpages=MAX_PAGES + 1):
            if len(pages) >= MAX_PAGES:
                raise DocumentError("DOCUMENT_TOO_LARGE")
            text = "".join(item.get_text() for item in page if isinstance(item, LTTextContainer)).strip()
            def has_image(item):
                return isinstance(item, LTImage) or isinstance(item, LTContainer) and any(has_image(child) for child in item)
            if len(text) < 20 and has_image(page):
                raise DocumentError("DOCUMENT_EMPTY")
            pages.append(f"--- Sayfa {len(pages) + 1} ---\n{text}")
        if not any(part.split("\n", 1)[1].strip() for part in pages):
            raise DocumentError("DOCUMENT_EMPTY")
        return "\n\n".join(pages), len(pages)
    from markitdown import MarkItDown, StreamInfo
    converter = MarkItDown(enable_plugins=False)
    return converter.convert_stream(io.BytesIO(data), stream_info=StreamInfo(extension=suffix)).text_content.strip(), None


def docling(data: bytes, suffix: str) -> tuple[str, int]:
    # Provision models explicitly during setup, never download while processing a private file.
    models = os.environ.get("WIQO_DOCUMENT_MODELS")
    if not models or not Path(models).is_dir():
        raise DocumentError("DOCUMENT_MODELS_MISSING")
    from docling.datamodel.base_models import DocumentStream, InputFormat
    from docling.datamodel.pipeline_options import PdfPipelineOptions, TesseractCliOcrOptions
    from docling.document_converter import DocumentConverter, PdfFormatOption
    options = PdfPipelineOptions(artifacts_path=Path(models), enable_remote_services=False)
    options.do_ocr = True
    options.do_table_structure = True
    options.ocr_options = TesseractCliOcrOptions(lang=["tur", "eng"], path=str(Path(models).parent / "tessdata"))
    # Docling's language discovery invokes --list-langs without --tessdata-dir.
    # Scope the environment to this dedicated worker conversion as well as options.path.
    previous_tessdata = os.environ.get("TESSDATA_PREFIX")
    os.environ["TESSDATA_PREFIX"] = str(Path(models).parent / "tessdata")
    try:
        converter = DocumentConverter(allowed_formats=[InputFormat.PDF], format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=options)})
        converted = converter.convert(DocumentStream(name="source" + suffix, stream=io.BytesIO(data)), max_num_pages=MAX_PAGES, max_file_size=MAX_BYTES)
    finally:
        if previous_tessdata is None:
            os.environ.pop("TESSDATA_PREFIX", None)
        else:
            os.environ["TESSDATA_PREFIX"] = previous_tessdata
    if str(converted.status.value) != "success":
        raise DocumentError("DOCUMENT_PARSE_FAILED")
    document = converted.document
    pages = sorted(document.pages)
    text = "\n\n".join(f"--- Sayfa {page} ---\n{document.export_to_markdown(page_no=page)}" for page in pages)
    return text.strip(), len(pages)


def useful(text: str) -> bool:
    visible = [char for char in text if not char.isspace()]
    return bool(visible) and sum(char == "\ufffd" for char in visible) / len(visible) < 0.02


def extract(request: dict) -> dict:
    data, suffix = snapshot(str(request.get("path", "")))
    ceiling = max(1, min(int(request.get("maxChars", MAX_TEXT)), MAX_TEXT))
    installed = dependencies()
    errors = []
    # Auto: cheap extraction first; layout explicitly requests the structured PDF reader.
    engines = ["docling", "markitdown"] if request.get("quality") == "layout" and suffix == ".pdf" else ["markitdown", "docling"]
    for engine in engines:
        if engine == "docling" and suffix != ".pdf":
            continue
        if not installed[engine]:
            errors.append("DEPENDENCY_MISSING")
            continue
        try:
            with offline():
                text, pages = docling(data, suffix) if engine == "docling" else markitdown(data, suffix)
            if not useful(text):
                errors.append("DOCUMENT_EMPTY")
                continue
            warnings = list(dict.fromkeys(errors))
            if request.get("quality") == "layout" and engine != "docling":
                warnings.append("LAYOUT_FALLBACK")
            return {"ok": True, "available": True, "adapter": engine, "text": text[:ceiling],
                    "truncated": len(text) > ceiling, "pageCount": pages,
                    "sha256": hashlib.sha256(data).hexdigest(), "warnings": warnings}
        except DocumentError as error:
            errors.append(error.code)
        except Exception:
            errors.append("DOCUMENT_PARSE_FAILED")
    raise DocumentError(next((code for code in errors if code != "DEPENDENCY_MISSING"), "DEPENDENCY_MISSING"))


def handle(request: dict) -> dict:
    try:
        if request.get("action") == "dependencyStatus":
            return {"ok": True, "available": True, "adapter": "document", "dependencies": dependencies()}
        if request.get("action") != "extractDocument":
            raise DocumentError("DOCUMENT_UNSUPPORTED")
        return extract(request)
    except DocumentError as error:
        return {"ok": False, "available": error.code != "DEPENDENCY_MISSING", "errorCode": error.code, "errorMessage": MESSAGES[error.code]}
    except Exception:
        return {"ok": False, "errorCode": "DOCUMENT_PARSE_FAILED", "errorMessage": MESSAGES["DOCUMENT_PARSE_FAILED"]}


if __name__ == "__main__":
    import base64
    logging.disable(logging.CRITICAL)
    # Libraries may print progress. Do not leak content or break the JSON response.
    with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        try:
            request = json.loads(base64.b64decode(sys.argv[1]))
            response = handle(request)
        except Exception:
            response = {"ok": False, "errorCode": "DOCUMENT_PARSE_FAILED", "errorMessage": MESSAGES["DOCUMENT_PARSE_FAILED"]}
    sys.stdout.write(json.dumps(response, ensure_ascii=False))
