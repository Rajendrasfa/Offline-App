# AskMe Android native host (NativeAOT/JNI spike)

This project is the first same-process hosting slice for the Flutter Android app.
It publishes the C# backend as an Android-Bionic shared library and exposes a
small stable C ABI. A C JNI shim lets Kotlin call that ABI from the existing
Flutter Activity without a local HTTP server, second APK, or cloud connection.

## Why this route

A normal `.NET 10` class library targeting `net10.0` is not loaded by Android
ART. A .NET Android AAR also expects the .NET Android runtime/packaging model;
it cannot simply be dropped into a regular Flutter APK. This spike instead
uses the documented NativeAOT Bionic target and explicit JNI exports.

Official .NET runtime guidance currently limits this path to
`linux-bionic-arm64` and `linux-bionic-x64`, with manual JNI interop. The
initial Android integration targets arm64-v8a only. The C# Android-Bionic
support and NativeAOT dependency compatibility must be validated in CI and on
a physical device before this becomes the production runtime.

## Build

Install .NET 10 SDK and Android NDK. Put the NDK LLVM toolchain first in PATH,
then run:

```bash
dotnet publish DotNetBackend/AskMe.AndroidHost/AskMe.AndroidHost.csproj \
  -c Release -r linux-bionic-arm64 \
  -p:DisableUnsupportedError=true \
  -p:PublishAotUsingRuntimePack=true
```

Copy the resulting `libaskme_android_host.so` into
`FlutterApp/android/app/src/main/jniLibs/arm64-v8a/` before building Flutter.

The Android app's CMake JNI shim links this library and exposes a runtime
handshake to Flutter through the existing `askme/offline_model` channel.

## Export contract

- `askme_backend_api_version()`: ABI version.
- `askme_backend_initialize()`: initializes the native backend boundary.
- `askme_backend_validate_question(ptr, length)`: validates UTF-8 request input.
- `askme_backend_start_request()` / `askme_backend_cancel_request(id)`:
  request coordinator lifecycle.

The exported ABI intentionally uses primitive C types only. Do not pass managed
object references, Kotlin objects, or Dart handles across this boundary.

## Current scope

This is a hosting/interop foundation, not a claim that the full question
pipeline is already executing inside NativeAOT. The next integration step is
to route document streams, local inference calls, history persistence, and
cancellation through this ABI. PDF/OpenXML package compatibility with NativeAOT
must be confirmed before those dependencies are moved into this host.
