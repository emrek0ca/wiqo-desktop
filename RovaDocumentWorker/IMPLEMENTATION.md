# Document and computer execution update

## Implementation

- Local optional MarkItDown adapter; PDF page checks; Docling layout and Turkish/English OCR; native Mac Vision fallback. Dedicated pinned environment, no startup imports/downloads, bounded child process and safe failures.
- Structure-aware backend retrieval retains headings, table headers, page and source offsets. Spreadsheet tables participate in document questions.
- Browser document downloads are standalone operations with public-address validation, bounded streaming, content checks and hash receipts. Authenticated downloads and blob URLs are not supported by this adapter.
- Mac cursor movement no longer reports failure on success. A non-activating Wiqo-labelled pointer follows movement and drag. It uses the system input pointer, not a second independent hardware cursor.
- Drag always releases its button; cancelled movement stops; scroll propagates movement failures. Sensitive drag targets are rejected. Text writes are read back; editors rejecting AX writes can use focused Unicode input without clipboard modification.
- Background terminal jobs inherit session directory/environment. Their output is available while running through the existing job snapshot. Completion always settles the job, including across reconnects; environment writeback is fenced against newer session state. Shell tracing is disabled before private export bookkeeping. Process cancellation terminates the process group when owned.
- Existing task grants, expiry, OS permissions and finite per-operation budgets remain. Longer tasks continue using existing repeated operations/background jobs.

## Changed files for this work

App repository (pre-existing unrelated dirty work preserved):

- RovaDocumentWorker/{pyproject.toml,uv.lock,setup.py,document_adapter.py,test_document_adapter.py,README.md,IMPLEMENTATION.md}
- Rova.xcodeproj/project.pbxproj
- RovaMac/{DocumentEngine.swift,MacSystem+Files.swift,MacSystem+Code.swift,MacSystem+UIControl.swift,MacBackendChannel.swift}
- RovaIOS/FileContentExtractor.swift
- RovaShared/Validation.swift
- RovaWindows/App/RovaWindows.App.csproj
- RovaWindows/Operations/LocalAnalysisOperations.cs
- RovaWindows/Core/WindowsValidation.cs
- RovaBrowserWorker/{index.mjs,downloads.mjs,downloads.test.mjs,README.md}

Backend repository:

- src/files/{passageIndex.ts,passageIndex.test.ts}
- src/tools/{fileTools.ts,compactPcTools.ts,compactPcTools.test.ts,semanticDeviceTools.ts,semanticDeviceTools.test.ts,deviceTools.ts}

## Local evidence

- Python adapter: 7 focused tests passed.
- Browser downloader: 5 focused tests passed.
- Backend passage/compact/semantic tools: 25 focused tests passed; typecheck passed.
- Real synthetic scanned PDF: Docling + Tesseract recovered Turkish text and document number, 1 page, no truncation/warnings, 8.89 seconds on this Mac (not a latency benchmark).
- Mac and iOS simulator builds passed during implementation. No production deployment or installed-phone verification is implied.
- Windows compile unavailable on this host (no dotnet); Windows remains unverified.

## Manual acceptance

1. Start an authorized desktop task, observe, move to an observed target, click/double-click/right-click. Confirm the Wiqo label follows the system pointer and does not intercept input.
2. Fill a normal text editor with Turkish text and emoji; check exact value. Password fields remain excluded. Change focus during a long fill: it must stop without continuing in the other field.
3. Drag an allowed item; cancel during drag and confirm the mouse button is released. Move the mouse manually between operations to verify takeover behavior.
4. Start a terminal job after exporting a harmless variable and changing directory; query output before completion, cancel a job, and reconnect during another job. Completed jobs must stop showing running; late jobs must not reset newer session state.
5. Read a text PDF, mixed scanned PDF and DOCX table with/without optional dependencies. Conversion failures must be explicit. Download a public PDF, then extract it through computer_files.

These physical computer interactions still require device verification; builds and adapter checks alone do not prove them.
