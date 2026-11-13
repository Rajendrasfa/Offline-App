import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'offline_backend_host.dart';

class AskMeDocument {
  const AskMeDocument({
    required this.name,
    required this.bytes,
    this.extractedText,
  });

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
    List<AskMeDocument> documents = const [],
    required Future<void> cancelled,
  });
  Future<void> stopAudio();
  Future<void> dispose();
}

/// On-device llama.cpp adapter. No HTTP client or network fallback is used.
/// Targets Android API 26+ ARM64 builds supported by llama_flutter_android.
///
/// Supports both general Gemini/ChatGPT-style offline chat (when [documents]
/// is empty) and grounded multi-document Q&A backed by C# NativeAOT RAG.
class AndroidLlamaOfflineEngine implements AskMeEngine {
  AndroidLlamaOfflineEngine({OfflineBackendHost? backendHost})
      : _backendHost = backendHost ?? OfflineBackendHost();

  static const _channel = MethodChannel('askme/offline_model');
  static const int _maxTotalDocChars = 20000;
  static const List<String> _stopTokens = [
    '<|im_end|>',
    '<|endoftext|>',
    '<|im_start|>',
    '<|eot_id|>',
    '</s>',
    '\nUSER:',
    '\nUser:',
    '\nuser:',
    '\n\nUSER',
    '\n\nUser',
    '\n\nuser',
    '\nASSISTANT:',
    '\nAssistant:',
    '\nassistant:',
    '\nASSISBATOR:',
    '\nASSISBATION:',
    '\nQ:',
    '\nQuestion:',
    '\n\nQ:',
    '\n\nQuestion:',
  ];

  final LlamaController _controller = LlamaController();
  final OfflineBackendHost _backendHost;
  bool _loaded = false;
  bool _disposed = false;
  Future<void>? _loading;
  StreamSubscription<String>? _generation;
  Completer<void>? _generationDone;

  Future<void> _ensureLoaded() async {
    if (_disposed) {
      throw StateError('Offline engine has been disposed.');
    }
    if (_loaded) {
      return;
    }
    if (_loading != null) {
      return _loading!;
    }
    _loading = () async {
      final profile =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('deviceProfile');
      final sdk = (profile?['sdkInt'] as num?)?.toInt() ?? 0;
      final abis =
          (profile?['supportedAbis'] as List?)?.cast<String>() ?? const <String>[];
      if (sdk < 26 || !abis.contains('arm64-v8a')) {
        throw UnsupportedError(
          'This inference runtime requires Android 8.0+ and arm64-v8a. '
          'This device is not supported by the current runtime build.',
        );
      }
      final modelPath = await _channel.invokeMethod<String>('modelPath');
      if (modelPath == null || modelPath.isEmpty) {
        throw const OfflineEngineUnavailable(
          'Import a compatible GGUF model first.',
        );
      }
      final cores = (profile?['cpuCores'] as num?)?.toInt() ?? 2;
      // Clamp to 2-4 threads on mobile to avoid thread synchronization bottlenecks
      // and severe thermal throttling across big/little cores (e.g. Snapdragon 695).
      // Keep contextSize at 2048 for optimal prompt evaluation latency and low RAM footprint.
      const context = 2048;
      await _controller.loadModel(
        modelPath: modelPath,
        threads: cores.clamp(2, 4).toInt(),
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

  Future<String> _retrieveContextForDocument(
    AskMeDocument document,
    String question,
    int index,
  ) async {
    String? backendContext;
    try {
      final reqId = await _backendHost.startRequest();
      if (reqId != null && reqId > 0) {
        final hasExtractedText =
            document.extractedText != null && document.extractedText!.trim().isNotEmpty;
        final docBytesToSend = hasExtractedText
            ? utf8.encode(document.extractedText!)
            : document.bytes;
        final fileNameToSend = hasExtractedText
            ? 'doc_$index.txt'
            : document.name;

        final docResult = await _backendHost.processDocument(
          requestId: reqId,
          docBytes: docBytesToSend,
          fileName: fileNameToSend,
        );
        if (docResult.ok) {
          backendContext = await _backendHost.retrieveChunks(
            requestId: reqId,
            question: question,
          );
        }
        await _backendHost.completeRequest(reqId);
      }
    } catch (_) {
      // Backend unavailable — fall back cleanly to extracted text below.
    }

    if (backendContext != null && backendContext.isNotEmpty) {
      return backendContext;
    }
    return document.extractedText ??
        utf8.decode(document.bytes, allowMalformed: true);
  }

  @override
  Future<AskMeAnswer> answer({
    required String question,
    List<AskMeDocument> documents = const [],
    required Future<void> cancelled,
  }) async {
    var cancellationRequested = false;
    final cancelSub = cancelled.asStream().listen((_) async {
      cancellationRequested = true;
      await _controller.stop();
      await _generation?.cancel();
      final done = _generationDone;
      if (done != null && !done.isCompleted) {
        done.complete();
      }
    });

    try {
      await _ensureLoaded();
      if (cancellationRequested) {
        throw const OfflineRequestCancelled();
      }

      final docSections = <({String name, String text})>[];
      final usedSources = <String>[];

      if (documents.isNotEmpty) {
        final perDocBudget =
            (_maxTotalDocChars / documents.length).floor().clamp(3000, 16000);
        for (var i = 0; i < documents.length; i++) {
          if (cancellationRequested) {
            throw const OfflineRequestCancelled();
          }
          final doc = documents[i];
          final context = await _retrieveContextForDocument(doc, question, i);
          if (context.trim().isNotEmpty) {
            final clipped = context.length > perDocBudget
                ? context.substring(0, perDocBudget)
                : context;
            docSections.add((name: doc.name, text: clipped));
            usedSources.add(doc.name);
          }
        }
      }

      final prompt = StringBuffer();
      if (docSections.isEmpty) {
        prompt
          ..write('<|im_start|>system\n')
          ..writeln(
            'You are AskMe, a helpful, precise, and concise offline AI assistant (similar to Gemini and ChatGPT).',
          )
          ..writeln(
            'Strict Rules:\n'
            '1. Give a direct, concise, and helpful answer (1 to 3 sentences).\n'
            '2. Reply in the same language used by the user (Hindi, Hinglish, or English).\n'
            '3. Stop immediately after answering. Never simulate fake follow-up dialogues, user questions, or extra text.',
          )
          ..write('<|im_end|>\n')
          ..write('<|im_start|>user\n')
          ..writeln(question)
          ..write('<|im_end|>\n')
          ..write('<|im_start|>assistant\n');
      } else {
        prompt
          ..write('<|im_start|>system\n')
          ..writeln(
            'You are AskMe, a private offline document AI assistant. Reply in the language used by the user (Hindi, Hinglish, or English).',
          )
          ..writeln(
            'Strict Rules:\n'
            '1. Answer ONLY from the provided named document(s) below in 1 or 2 concise sentences.\n'
            '2. Mention the document name when helpful.\n'
            '3. If the requested detail is not found in the documents, state clearly: "This information is not mentioned in the document."\n'
            '4. Stop immediately after answering. Never generate fake follow-up questions, simulated dialogue, or extra conversation.',
          )
          ..write('<|im_end|>\n')
          ..write('<|im_start|>user\n');
        for (final section in docSections) {
          prompt
            ..writeln('DOCUMENT [${section.name}]:')
            ..writeln(section.text)
            ..writeln('END DOCUMENT [${section.name}]\n');
        }
        prompt
          ..writeln('Question: $question')
          ..write('<|im_end|>\n')
          ..write('<|im_start|>assistant\n');
      }

      final done = Completer<void>();
      final output = StringBuffer();
      _generationDone = done;
      _generation = _controller
          .generate(
            prompt: prompt.toString(),
            maxTokens: 256,
            temperature: docSections.isEmpty ? 0.4 : 0.1,
            topP: 0.9,
          )
          .listen(
            (chunk) {
              output.write(chunk);
              final currentText = output.toString();
              for (final stopToken in _stopTokens) {
                final idx = currentText.indexOf(stopToken);
                if (idx >= 0) {
                  final trimmed = currentText.substring(0, idx).trim();
                  output.clear();
                  output.write(trimmed);
                  unawaited(_controller.stop());
                  unawaited(_generation?.cancel());
                  if (!done.isCompleted) {
                    done.complete();
                  }
                  break;
                }
              }
            },
            onError: (Object error, StackTrace stack) {
              if (!done.isCompleted) {
                done.completeError(error, stack);
              }
            },
            onDone: () {
              if (!done.isCompleted) {
                done.complete();
              }
            },
            cancelOnError: true,
          );

      await done.future;
      if (cancellationRequested) {
        throw const OfflineRequestCancelled();
      }
      var answerText = output.toString().trim();
      for (final stopToken in _stopTokens) {
        final idx = answerText.indexOf(stopToken);
        if (idx >= 0) {
          answerText = answerText.substring(0, idx).trim();
        }
      }
      if (answerText.isEmpty) {
        throw StateError('The local model returned an empty response.');
      }
      return AskMeAnswer(text: answerText, sources: usedSources);
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
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
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
