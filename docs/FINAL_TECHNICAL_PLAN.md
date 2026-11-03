# AskMe — Final Technical Plan (decisions locked)

## Confirmed product decisions
- Question input: text and voice.
- Answer output: text and audio.
- Languages: Hindi and English.
- Voice interruption: when a new spoken question arrives, stop the previous audio and switch to the new question.
- Question cancellation history: KEEP the cancelled question with status `Cancelled`.
- Cancellation scope: ALL — stop speech recognition, AI generation, text-to-speech, audio playback, retrieval/file search and any active document-processing work belonging to that request.

## Cancellation contract
1. Assign a monotonically increasing request ID to every question.
2. Maintain one active request cancellation source/token.
3. Propagate cancellation through STT, retrieval, LLM and TTS APIs.
4. Stop audio playback immediately on cancellation.
5. Check request ID and cancellation state before every UI/history response update; stale responses must be discarded.
6. Persist the question and terminal status `Cancelled` in encrypted local history.
7. Permit a new question immediately after cancellation.

## Architecture
- Flutter Android UI.
- C#/.NET core orchestration and document contracts; Android hosting/bridge must be selected and validated before integration (a plain `net10.0` class library is not automatically an Android backend).
- On-device Hindi/English STT, LLM and TTS only; verify that selected models run without network access on the target phone.
- User-mediated Storage Access Framework/file picker; no broad media/storage permission.
- Encrypted local metadata/index/history with keys protected by Android Keystore.
- Do not persist original selected files; retain only encrypted derived chunks/index needed for Q&A, subject to explicit retention controls.

## Prototype status — important
The current Flutter screen demonstrates text entry, file selection UI, cancellation, and keeping a cancelled question in in-memory history. The short processing timer is a UI demonstration only; it is NOT an AI engine. The C# coordinator is a cancellation foundation, not a connected Android service.

Not implemented yet: real document extraction, encrypted persistent history/index, local embeddings, local LLM inference, Hindi/English offline STT, offline TTS, audio interruption, Flutter/.NET Android bridge, background processing, and end-to-end privacy/security tests. Do not describe this package as a complete offline AI app.

## APK build status
No APK is included. This build environment does not have Flutter SDK, Android SDK/Gradle toolchain, or .NET SDK installed, so a valid installable APK cannot be compiled or verified here. Build and test on a configured Android development machine before distributing an APK.
