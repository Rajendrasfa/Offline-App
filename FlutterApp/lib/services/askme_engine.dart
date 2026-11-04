import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

class AskMeDocument {
  const AskMeDocument({required this.name, required this.bytes, this.extractedText});
  final String name;
  final List<int> bytes;
  final String? extractedText;
}

class AskMeAnswer {
  const AskMeAnswer({required this.text, this.sources = const []});
  final String text;
  final List<String> sources;
}

abstract interface class AskMeEngine {
  Future<AskMeAnswer> answer({
    required String question,
    AskMeDocument? document,
    required Future<void> cancelled,
  });
  Future<void> stopAudio();
  Future<void> dispose();
}

/// On-device llama.cpp adapter. No HTTP client or network fallback is used.
/// This adapter currently targets Android API 26+ ARM64 builds supported by
/// llama_flutter_android; unsupported ABIs fail closed instead of faking output.
class AndroidLlamaOfflineEngine implements AskMeEngine {
  static const _channel = MethodChannel('askme/offline_model');
  final LlamaController _controller = LlamaController();
  bool _loaded = false;
  bool _disposed = false;
  Future<void>? _loading;
  StreamSubscription<String>? _generation;
  Completer<void>? _generationDone;

  Future<void> _ensureLoaded() async {
    if (_disposed) throw StateError('Offline engine has been disposed.');
    if (_loaded) return;
    if (_loading != null) return _loading!;
    _loading = () async {
      final profile = await _channel.invokeMethod<Map<dynamic, dynamic>>('deviceProfile');
      final sdk = (profile?['sdkInt'] as num?)?.toInt() ?? 0;
      final abis = (profile?['supportedAbis'] as List?)?.cast<String>() ?? const <String>[];
      if (sdk < 26 || !abis.contains('arm64-v8a')) {
        throw UnsupportedError('This inference runtime requires Android 8.0+ and arm64-v8a. This device is not supported by the current runtime build.');
      }
      final modelPath = await _channel.invokeMethod<String>('modelPath');
      if (modelPath == null || modelPath.isEmpty) {
        throw const OfflineEngineUnavailable('Import a compatible GGUF model first.');
      }
      final totalRam = (profile?['totalRamBytes'] as num?)?.toInt() ?? 0;
      final cores = (profile?['cpuCores'] as num?)?.toInt() ?? 2;
      final context = totalRam >= 6 * 1024 * 1024 * 1024 ? 4096 : 2048;
      await _controller.loadModel(
        modelPath: modelPath,
        threads: cores.clamp(2, 6).toInt(),
        contextSize: context,
      );
      _loaded = true;
    }();
    try {
      await _loading;
    } finally {
      _loading = null;
    }
  }

  @override
  Future<AskMeAnswer> answer({
    required String question,
    AskMeDocument? document,
    required Future<void> cancelled,
  }) async {
    await _ensureLoaded();
    final docText = document == null
        ? ''
        : (document.extractedText ?? utf8.decode(document.bytes, allowMalformed: true));
    final prompt = StringBuffer()
      ..writeln('You are AskMe, a private offline assistant. Reply in the language used by the user.')
      ..writeln('Use only the supplied document when answering document questions. If the answer is absent, say so.')
      ..writeln();
    if (docText.isNotEmpty) {
      prompt.writeln('DOCUMENT [${document!.name}]:');
      prompt.writeln(docText.substring(0, docText.length > 24000 ? 24000 : docText.length));
      prompt.writeln('END DOCUMENT');
    }
    prompt.writeln('USER: $question');
    prompt.write('ASSISTANT:');

    final done = Completer<void>();
    final output = StringBuffer();
    _generationDone = done;
    _generation = _controller.generate(
      prompt: prompt.toString(),
      maxTokens: 768,
      temperature: 0.3,
      topP: 0.9,
    ).listen(
      output.write,
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    var cancellationRequested = false;
    final cancelSub = cancelled.asStream().listen((_) async {
      cancellationRequested = true;
      // Stop the native llama.cpp generation before allowing the request to
      // settle. The caller's request lease prevents a cancelled result from
      // being written to history even if native shutdown takes a moment.
      await _controller.stop();
      await _generation?.cancel();
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future;
      if (cancellationRequested) throw const OfflineRequestCancelled();
      final answer = output.toString().trim();
      if (answer.isEmpty) throw StateError('The local model returned an empty response.');
      return AskMeAnswer(text: answer);
    } finally {
      await cancelSub.cancel();
      await _generation?.cancel();
      _generation = null;
      _generationDone = null;
    }
  }

  @override
  Future<void> stopAudio() async {
    await _controller.stop();
    await _generation?.cancel();
    final done = _generationDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopAudio();
    await _controller.dispose();
    _loaded = false;
  }
}

/// Raised when the active request is cancelled while native inference is running.
class OfflineRequestCancelled implements Exception {
  const OfflineRequestCancelled();

  @override
  String toString() => 'OFFLINE_REQUEST_CANCELLED';
}

class OfflineEngineUnavailable implements Exception {
  const OfflineEngineUnavailable([this.message = 'OFFLINE_MODEL_NOT_INSTALLED']);
  final String message;
  @override
  String toString() => message;
}
