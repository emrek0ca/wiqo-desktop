# Optional local document reader

One adapter behind the existing document and local-analysis capabilities. The Mac and Windows companions authorize the request before invoking it. No server or phone-to-engine connection is introduced. iPhone keeps PDFKit/Vision and local Office parsing; private original files are not uploaded for conversion.

## Engines

- **MarkItDown 0.1.8** for Office/HTML/text to Markdown: headings and tables survive extraction. Only document format extras are selected; plugins and remote conversion APIs are disabled.
- **PDFMiner**, supplied by MarkItDown's PDF extra, reads and checks each PDF page on the cheap path. A partially scanned document cannot pass as a complete text extraction.
- **Docling 2.138.0** for PDF layout/tables/OCR when requested or the cheap path is incomplete. Tesseract is the OCR adapter, with Turkish and English language data. Docling model files must already be present; processing never downloads models.
- Existing native readers remain the fallback. Missing OCR or partial extraction yields an actionable error rather than fabricated successful conversion.

The adapter returns JSON with text, source digest, page count where available, explicit truncation/warnings and safe errors. Native clients impose a 45-second deadline. Limits: 25 MB source, 200 PDF pages, 500k characters; archives also have expanded-size limits. Dependencies lazy-load on calls. This is document extraction, not a guarantee of pixel-identical PDF-to-Word conversion.

## Explicit setup

Install `uv`, then run from the app resources or checkout:

```sh
python3 RovaDocumentWorker/setup.py
# Optional structured PDF/OCR (requires a local Tesseract executable; pinned tur/eng data is installed privately):
python3 RovaDocumentWorker/setup.py --layout
```

Setup uses `uv sync --frozen`, never the global Python environment. Package versions and transitive hashes are in `uv.lock`. Environments live under the current user's platform application-data directory (`Wiqo/Documents`); no user-specific path is baked into production code. On Linux the standalone adapter uses the same protocol; a new Linux companion is not added here.

Run `dependencyStatus` through existing local analysis to inspect the document environment. Mac native readers work if the optional environment is absent. Setup is explicit and never runs during UI startup or private document parsing. To remove the optional environment, delete only its `Wiqo/Documents/.venv` and `models` directories; native readers remain usable.

## Verification

```sh
# Run with the document environment's Python executable:
python -B -m unittest discover -s RovaDocumentWorker -p 'test_*.py'
```

Tests include real Turkish DOCX/table and text conversion plus missing dependencies, limits and offline behavior. The desktop build must bundle this folder; Windows publishes it as `DocumentWorker`. Validate a real scanned PDF on each target after installing OCR/models. Documents, page contents and raw exception traces are not logged.
