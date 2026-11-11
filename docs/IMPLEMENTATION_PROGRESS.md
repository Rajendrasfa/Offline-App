# Implementation status

## Implemented in source

### Flutter UI Layer
- Flutter UI uses an offline engine abstraction (`AskMeEngine` → `AndroidLlamaOfflineEngine`).
- Encrypted history loaded at startup, updated for Pending, Completed, Cancelled and failure states.
- History read-modify-write operations are serialized via a write queue.
- File selection limited to PDF, DOCX, TXT, MD, CSV and JSON via Android SAF + `FilePicker`.
- UI does not silently fall back to a network model — produces clear setup-required state.
- Request cancellation and audio-stop hooks exposed through the engine contract.
- **RenderFlex overflow fixed** — `SingleChildScrollView` wraps the top section; `Expanded(ListView)` takes remaining space.
- Voice input (Hindi `hi-IN` / English `en-US`) uses Android on-device speech recognizer (Android 12+).
- Offline TTS uses Android system voices filtered for `!isNetworkConnectionRequired`.

### C# NativeAOT Backend (AskMe.AndroidHost)
- **`askme_backend_api_version`** — returns ABI version 2.
- **`askme_backend_initialize`** — initializes shared state.
- **`askme_backend_validate_question`** — UTF-8 validation, 32 KiB limit.
- **`askme_backend_start_request`** — allocates serialized request lease.
- **`askme_backend_cancel_request`** — cancels active request, evicts chunk cache.
- **`askme_backend_complete_request`** — completes active request, evicts chunk cache.
- **`askme_backend_process_document`** *(new)* — receives raw document bytes from JNI, runs `LocalDocumentExtractor` (PDF via PdfPig, DOCX via OpenXml, TXT/MD/CSV/JSON), stores extracted chunks in per-request cache. Max 25 MB.
- **`askme_backend_retrieve_chunks`** *(new)* — keyword RAG over cached chunks; returns UTF-8 context string; falls back to first 4 chunks when no keyword match.

### C# Core (AskMe.Core)
- `LocalDocumentExtractor` — PDF page-level + DOCX paragraph extraction with 1200-char overlapping chunks.
- `KeywordChunkRetriever` — keyword scoring, top-8, Hindi + English queries supported.
- `QuestionPipeline` — orchestrates retrieval + answerer + history with cancellation.
- `QuestionRequestCoordinator` — serializes active requests.
- **C# tests: 33/33 PASS** (26 original + 7 new `RetrievalTests`).

### JNI Bridge (C)
- `nativeBackendApiVersion`, `nativeBackendInitialize` — health check.
- `nativeBackendStartRequest`, `nativeBackendCancelRequest`, `nativeBackendCompleteRequest` — request lifecycle.
- **`nativeBackendProcessDocument`** *(new)* — JNI → `askme_backend_process_document`; returns `IntArray[returnCode, chunkCount]`.
- **`nativeBackendRetrieveChunks`** *(new)* — JNI → `askme_backend_retrieve_chunks`; returns `ByteArray` with 4-byte LE returnCode prefix + UTF-8 context.

### Android / Kotlin Layer (MainActivity.kt)
- Full MethodChannel handlers for all backend operations.
- **`backendProcessDocument`** *(new)* — passes document bytes from Flutter to native backend.
- **`backendRetrieveChunks`** *(new)* — retrieves RAG context from native backend; retries with 512 KiB buffer if initial 128 KiB is too small.
- `modelRuntimeReady` in `deviceProfile()` — now reflects actual model file + backend load state.
- GGUF model import via Android SAF — SHA-256 integrity, 8 GB limit, atomic rename.
- TTS with offline voice filter, STT with on-device recognizer.
- Device profile reporting (SDK, ABI, RAM, tier).

### Full Q&A Pipeline (End-to-End)
When a user asks a question with a document loaded:
1. Flutter `_ask()` → `_backendHost.startRequest()` (JNI → C#: allocate request)
2. `AndroidLlamaOfflineEngine.answer()` → `_backendHost.processDocument()` (JNI → C#: extract + chunk)
3. → `_backendHost.retrieveChunks()` (JNI → C#: keyword RAG → context string)
4. → `_backendHost.completeRequest()` (release lease)
5. Context injected into llama.cpp prompt via `llama_flutter_android`
6. Streamed response returned to Flutter UI

If the C# backend is unavailable (`.so` not loaded), the engine falls back to raw document bytes — no network call is ever made.

## Distribution decision
- AI model weights distributed separately from the APK — user imports via SAF.
- APK does not embed model weights or auto-download them.
- `INTERNET` permission is intentionally absent from `AndroidManifest.xml`.
- Only user-selected files are accessed (Android SAF scoped access).
- See `MODEL_DISTRIBUTION.md` for validation requirements.

## Remaining before production release
1. **Full device test** on a physical ARM64 Android device in airplane mode.
2. **APK signing** — replace debug keystore with production signing config.
3. **Application ID** — replace `com.example.askme` with production package name.
4. **Model runtime compatibility** — test with specific GGUF models (e.g. Gemma 2B Q4_K_M).
5. **Large document memory test** — validate 25 MB document does not cause OOM.
6. **GitHub Actions APK artifact** — confirm `.so` is bundled and APK downloads correctly.

## Test status
| Suite | Count | Status |
|---|---|---|
| C# Core + Retrieval | 33 | ✅ PASS |
| Flutter Widget Tests | 7 | Requires `flutter test` on host with Flutter installed |
| Android Device Tests | 0 | Pending — requires physical device |
