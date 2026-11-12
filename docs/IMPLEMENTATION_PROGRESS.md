# Implementation status

## Implemented in source

### Flutter UI & Services Layer
- **Two-Tab Navigation (`Ask` | `Scan`)** — `Ask` tab is selected by default.
- **`Ask` Tab (Gemini/ChatGPT-style offline chat + Document Q&A):**
  - Conversational chat thread with user/assistant bubbles, source document chips, copy, offline TTS playback, and Hindi/English offline STT voice input.
  - Supports **General AI mode** (answers general questions without requiring a document), **Named Document mode** (`@DocName` autocomplete or natural name mention, plus 1-tap pinned document chips), and **Auto Smart mode** (automatically resolves matching named documents or topic-relevant documents across the vault, falling back to general AI chat when unrelated).
  - Compact Model & Runtime bottom sheet accessible from the top bar for importing/replacing/removing local `.gguf` models and inspecting device/backend info.
- **`Scan` Tab (Named Document Vault — Camera Scan + File Upload):**
  - **Camera Scan** (`captureCameraImage` via `MediaStore.ACTION_IMAGE_CAPTURE` + `FileProvider`) captures full-resolution photos offline and extracts Hindi/English text via on-device ML Kit Devanagari OCR.
  - **File Upload** supports PDF, DOCX, TXT, MD, CSV, JSON and Images (`JPG`, `JPEG`, `PNG`, `WEBP`, `BMP`) via Android SAF + `FilePicker`.
  - Prompts user to assign a **unique name** to every uploaded/scanned document, with preview, rename, delete, and 1-tap `Ask` shortcut.
- **AES-256-GCM Encrypted Persistence** (`EncryptedJsonFileStore`):
  - `SecureHistoryStore` & `SecureDocumentStore` encrypt both conversation history and named scanned/uploaded documents at rest using Android Keystore-backed `flutter_secure_storage`, with serialized write queues.
- UI never silently falls back to a cloud/network model — `INTERNET` permission is stripped with `tools:node="remove"` in `AndroidManifest.xml`.

### C# NativeAOT Backend (`AskMe.AndroidHost`)
- **`askme_backend_api_version`** — returns ABI version 2.
- **`askme_backend_initialize`** — initializes shared state.
- **`askme_backend_validate_question`** — UTF-8 validation, 32 KiB limit.
- **`askme_backend_start_request`** — allocates serialized request lease.
- **`askme_backend_cancel_request`** — cancels active request, evicts chunk cache.
- **`askme_backend_complete_request`** — completes active request, evicts chunk cache.
- **`askme_backend_process_document`** — receives raw document or extracted text bytes from JNI, runs `LocalDocumentExtractor`, stores extracted chunks in per-request cache. Max 25 MB.
- **`askme_backend_retrieve_chunks`** — keyword RAG over cached chunks with punctuation normalization; returns UTF-8 context string; falls back to first 4 chunks when no keyword match.

### C# Core (`AskMe.Core`)
- `LocalDocumentExtractor` — PDF page-level + DOCX paragraph extraction + text/image-OCR chunks (1200-char overlapping).
- `KeywordChunkRetriever` — punctuation-tolerant keyword scoring, top-8, Hindi + English queries supported.
- `QuestionPipeline` — orchestrates retrieval + answerer + history with cancellation.
- `QuestionRequestCoordinator` — serializes active requests.
- **C# tests: 39/39 PASS** (includes extraction, pipeline, retrieval, image format, and punctuation-tolerant query tests).

### JNI Bridge (`askme_jni_bridge.c`) & Android Kotlin (`MainActivity.kt`)
- Full JNI wrappers for all 7 native exports, built strictly for `arm64-v8a`.
- MethodChannel handlers for NativeAOT backend calls, GGUF SAF import/validation, device profile (`minSdk = 26`), on-device ML Kit OCR (`InputImage.fromFilePath` with automatic EXIF orientation handling), native camera scan (`captureCameraImage`), and offline STT/TTS.

## Distribution decision
- AI model weights distributed separately from the APK — user imports via SAF.
- APK does not embed model weights or auto-download them.
- `INTERNET` permission is stripped from merged `AndroidManifest.xml`.
- Only user-selected files and explicit camera scans are accessed.
- See `MODEL_DISTRIBUTION.md` for validation requirements.

## Remaining before production release
1. **Verify CI APK build** with the updated 2-tab Ask/Scan + Camera OCR feature.
2. **Full device test** on a physical ARM64 Android device in airplane mode (test general Ask, camera Scan + naming, `@DocName` queries, and cross-document topic queries).
3. **APK signing & Application ID** — replace debug keystore and `com.example.askme` before Play Store / production distribution.

## Test status
| Suite | Count | Status |
|---|---|---|
| C# Core + Retrieval + Images | 39 | ✅ PASS (verified locally) |
| Flutter Unit & Widget Tests | 9 (7 resolver + 2 widget) | Verified via GitHub Actions CI (`flutter analyze` + `flutter test`) |
| Android Device Tests | 0 | Pending — requires physical ARM64 device |
