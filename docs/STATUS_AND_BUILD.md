# Status and build instructions

## Current status
This is a source scaffold/prototype, not a finished product. Flutter UI supports text entry, file-picker selection, demo cancellation, and in-memory cancelled history. C# includes a request cancellation coordinator foundation. The demo timer does not generate an answer.

Not implemented: actual offline STT/TTS/LLM, file extraction/indexing, encrypted persistent storage, Flutter/.NET Android bridge, audio interruption, robust background jobs, or security validation.

## Build APK (on a development computer)
1. Install Flutter stable, Android Studio/Android SDK, compatible Java/Gradle, and .NET 10 SDK.
2. From `FlutterApp`, run `flutter pub get`.
3. Run `flutter doctor` and resolve Android toolchain issues.
4. Run `flutter build apk --debug` for a UI prototype APK.
5. Validate the .NET Android hosting/interop bridge before connecting the C# project. A plain `net10.0` library is not automatically Android-loadable.

## Privacy and safety requirements
- Process only files explicitly selected by the user; avoid broad storage permissions.
- No cloud APIs, telemetry, analytics, or external data transmission.
- Do not permanently copy original files.
- Encrypt retained derived content/history; protect keys with Android Keystore.
- Test manifest permissions, network behavior, backups, temporary files, and storage cleanup.
- Validate all AI, STT and TTS models work offline after installation/model provisioning.
