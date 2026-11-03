# AskMe — Offline AI Android App

This repository contains the current Flutter application and C# core source. The APK is deliberately deferred until native runtime integration and device validation are complete.

## Current implementation
- Flutter Material 3 application shell.
- Explicit document selection for PDF, DOCX, TXT, MD, CSV and JSON.
- Selected file bytes are held in memory for the active session; this code does not copy the source document into app storage.
- AES-256-GCM encrypted local conversation history, with key material stored through `flutter_secure_storage`.
- Serialized history updates to avoid concurrent read/modify/write loss.
- Request IDs, cancellation signal, cancellation history state, and an engine interface that can be implemented by native adapters.
- Fail-closed AI engine placeholder: it reports missing offline model/runtime and never sends data to a cloud endpoint.
- C# document extraction and question-pipeline contracts remain in `DotNetBackend/AskMe.Core`.

## Not yet complete / not represented as working
- Android JNI/native LLM runtime and bundled model weights.
- Actual C#-to-Flutter Android bridge.
- End-to-end PDF/DOCX extraction and retrieval wired into the UI.
- Offline speech recognition, Hindi/English speech synthesis, and audio playback adapters.
- Android manifest/dependency audit, automated tests, build and OnePlus device validation.

These are runtime-critical tasks. Do not describe the app as a complete offline AI assistant until they are implemented and verified. There is no network fallback in the current Flutter engine implementation.

## Build policy
Do not build or distribute an APK until the remaining integrations are complete and the merged Android manifest is verified to contain no `INTERNET` permission or analytics/cloud SDKs. Build and device-test later as explicitly requested.
