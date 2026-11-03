import 'dart:async';
import 'dart:typed_data';

class AskMeDocument {
  const AskMeDocument({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

class AskMeAnswer {
  const AskMeAnswer({required this.text, this.sources = const []});
  final String text;
  final List<String> sources;
}

/// Platform implementation must be backed by a bundled local model/runtime.
/// It must never call an HTTP/cloud endpoint and must honour cancellation.
abstract interface class AskMeEngine {
  Future<AskMeAnswer> answer({
    required String question,
    AskMeDocument? document,
    required Future<void> cancelled,
  });
  Future<void> stopAudio();
  Future<void> dispose();
}

/// Fail-closed implementation: no simulated answers and no network fallback.
/// Replace with the Android JNI/native offline runtime before enabling Ask.
class OfflineEngineNotInstalled implements AskMeEngine {
  @override
  Future<AskMeAnswer> answer({required String question, AskMeDocument? document,
      required Future<void> cancelled}) async {
    await Future<void>.value();
    throw const OfflineEngineUnavailable();
  }
  @override
  Future<void> stopAudio() async {}
  @override
  Future<void> dispose() async {}
}

class OfflineEngineUnavailable implements Exception {
  const OfflineEngineUnavailable();
  @override
  String toString() => 'OFFLINE_MODEL_NOT_INSTALLED';
}
