# Offline model distribution decision

## Decision
The AI model is kept separate from the Android APK. The APK contains the application, UI, local runtime integration and model-management workflow; it does not embed multi-gigabyte model weights.

## User experience
1. Install the AskMe APK without downloading a model.
2. Open **Settings → Offline AI Model**.
3. Choose **Import model file** and select a compatible model file using Android's Storage Access Framework (SAF), or use a separately published, verified model package when one is made available.
4. AskMe validates the selected file against the supported format, expected size range and SHA-256 checksum when a trusted checksum is available.
5. AskMe records model readiness only after validation and a runtime load test succeed. If no compatible model is installed, the app must clearly show **Model not installed** and must not return simulated answers or switch to a cloud service.

## Privacy and offline guarantees
- No automatic model download, background download, cloud inference, network fallback, telemetry or model discovery request.
- Import is initiated by the user and limited to the file explicitly selected through SAF.
- Do not request broad storage permissions.
- Keep imported model data in app-private storage; never overwrite or delete the user's source file.
- Provide an explicit remove-model action. Removal affects only AskMe's private imported copy.
- Do not mark a model as supported based only on its filename. Check format, architecture, quantization/runtime compatibility and available memory before loading.
- Model license and redistribution terms must be reviewed before publishing or bundling any model package.

## Runtime and device validation
The model/runtime combination remains unselected until a compatible Android runtime is integrated and tested. Validate on the target OnePlus Nord CE 3 Lite (8 GB RAM) for:
- successful load and inference without network access;
- Hindi and English prompt quality;
- peak memory, startup time, response latency and thermal behaviour;
- clean cancellation and release of native resources;
- model corruption, insufficient storage and unsupported-format errors.

## Implementation status
This document records the distribution decision; it does not claim that model import, inference or model management is implemented. Those features require the runtime adapter, SAF streaming, integrity validation and device tests.
