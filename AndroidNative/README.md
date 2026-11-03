# Android native integration — required work

The Flutter layer intentionally exposes an engine interface and fails closed when the local model adapter is absent. Implement the following Android-side pieces before claiming feature completion:

1. **Document access:** use Android Storage Access Framework (`ACTION_OPEN_DOCUMENT`) with MIME/extension allow-list. Read the selected `content://` URI via `ContentResolver.openInputStream`; do not request broad storage permissions. Persist URI grants only if the user explicitly opts to keep a document available across sessions. Do not copy original documents into app-private permanent storage.
2. **LLM:** bundle a supported local inference runtime (for example, llama.cpp through Android NDK/JNI) and a separately packaged, license-verified quantized model. The model must be local; no HTTP client or cloud fallback. Stream tokens and check cancellation between decode steps.
3. **C# boundary:** a `net10.0` class library is not automatically loadable by Flutter/Android. Select and prove a supported .NET for Android/native binding strategy before wiring the C# core. Do not use a localhost server as a substitute for an in-process offline bridge.
4. **Speech:** bundle offline Hindi/English STT and TTS model assets. Implement native cancellation for recognition, synthesis and playback. Do not rely on Android network speech services.
5. **Lifecycle:** use request UUIDs; a new request cancels all previous extraction, retrieval, inference, recognition, synthesis and playback. Native callbacks must discard stale request IDs.
6. **Security:** use Android Keystore-backed encryption; audit `AndroidManifest.xml` and merged manifest. No `INTERNET`, analytics, remote crash reporting, or remote model downloads in the released app.

The current repository does not yet contain these native implementations or model weights. APK build remains deferred.
