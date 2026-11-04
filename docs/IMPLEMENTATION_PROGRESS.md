# Implementation status

## Implemented in source
- Flutter UI now uses an engine abstraction instead of a demo timer.
- Encrypted history is loaded at startup and updated for Pending, Completed, Cancelled and failure states.
- History read/modify/write operations are serialized.
- File selection is limited to PDF, DOCX, TXT, MD, CSV and JSON; selected bytes are kept in memory by this Flutter layer.
- The UI does not silently fall back to a network model. Until a local model adapter is installed, asking a question produces a clear setup-required state.
- Request cancellation and audio-stop hooks are exposed through the engine contract.

## Distribution decision
- AI model weights will be distributed separately from the APK.
- The APK must not embed multi-gigabyte model weights or automatically download them.
- The user will explicitly import a compatible model file through Android's Storage Access Framework. Only the selected file may be accessed; broad storage permissions are not permitted.
- AskMe must validate model compatibility and integrity before marking it ready. No cloud fallback or simulated answer is allowed.
- See [MODEL_DISTRIBUTION.md](MODEL_DISTRIBUTION.md) for the decision and validation requirements.

## Remaining before feature-complete
1. Select and integrate a compatible Android local LLM runtime; benchmark supported model formats and quantizations on the target phone.
2. Implement explicit model import/management, SAF streaming, integrity validation and safe app-private storage.
3. Implement Android platform channel/JNI adapters and connect Flutter to the C# core using a supported Android deployment model.
4. Connect SAF URI streaming and document extraction/retrieval end-to-end; avoid keeping whole large files in memory.
5. Implement offline Hindi/English STT and TTS models plus playback; ensure stop/cancel reaches native engines.
6. Add unit, integration, privacy and cancellation race tests.
7. Audit merged manifest and all transitive dependencies for network permissions/telemetry.
8. Build and validate on the target Android device. APK is intentionally deferred.

## Validation environment
The current work environment does not have Flutter, Dart, .NET SDK, Android SDK, Gradle or adb installed. Compilation and device testing have therefore not been performed. No successful build is claimed.
