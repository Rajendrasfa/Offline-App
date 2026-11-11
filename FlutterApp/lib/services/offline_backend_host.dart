import 'dart:typed_data';
import 'package:flutter/services.dart';

class OfflineBackendRuntimeInfo {
  const OfflineBackendRuntimeInfo({
    required this.available,
    required this.apiVersion,
    this.error = '',
  });

  final bool available;
  final int apiVersion;
  final String error;

  factory OfflineBackendRuntimeInfo.fromMap(Map<dynamic, dynamic> value) {
    return OfflineBackendRuntimeInfo(
      available: value['available'] == true,
      apiVersion: (value['apiVersion'] as num?)?.toInt() ?? 0,
      error: value['error']?.toString() ?? '',
    );
  }
}

/// Result of askme_backend_process_document.
class BackendDocumentResult {
  const BackendDocumentResult({required this.returnCode, required this.chunkCount});
  final int returnCode;
  final int chunkCount;
  bool get ok => returnCode == 0;
}

/// Bridges Flutter to the C# NativeAOT backend via the Kotlin MethodChannel.
///
/// Call flow for a document Q&A request:
///   1. [startRequest]  — allocates a request lease, returns request-id.
///   2. [processDocument] — passes document bytes; C# extracts + chunks.
///   3. [retrieveChunks]  — keyword RAG; returns relevant context string.
///   4. Use context in the llama.cpp prompt (see AskMeEngine).
///   5. [completeRequest] or [cancelRequest] — releases the lease.
class OfflineBackendHost {
  static const MethodChannel _channel = MethodChannel('askme/offline_model');

  Future<OfflineBackendRuntimeInfo> inspect() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'backendRuntimeInfo',
    );
    if (result == null) {
      throw const FormatException('Native backend returned no runtime information.');
    }
    return OfflineBackendRuntimeInfo.fromMap(result);
  }

  Future<int?> startRequest() => _channel.invokeMethod<int>('backendStartRequest');

  Future<bool> cancelRequest(int requestId) async =>
      await _channel.invokeMethod<bool>('backendCancelRequest', {'requestId': requestId}) ?? false;

  Future<bool> completeRequest(int requestId) async =>
      await _channel.invokeMethod<bool>('backendCompleteRequest', {'requestId': requestId}) ?? false;

  /// Sends document bytes to the C# backend for extraction and chunking.
  ///
  /// [requestId] must be the value returned by [startRequest].
  /// [docBytes] are the raw file bytes selected via Android SAF.
  /// [fileName] must include the extension (e.g. "report.pdf").
  ///
  /// Returns [BackendDocumentResult.ok] == true on success.
  Future<BackendDocumentResult> processDocument({
    required int requestId,
    required List<int> docBytes,
    required String fileName,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'backendProcessDocument',
      {
        'requestId': requestId,
        'docBytes': Uint8List.fromList(docBytes),
        'fileName': fileName,
      },
    );
    if (result == null) {
      return const BackendDocumentResult(returnCode: 4, chunkCount: 0);
    }
    return BackendDocumentResult(
      returnCode: (result['returnCode'] as num?)?.toInt() ?? 4,
      chunkCount: (result['chunkCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// Retrieves the most relevant document chunks for [question] from the
  /// previously processed document.
  ///
  /// Returns the context string ready to include in a prompt, or null on error.
  Future<String?> retrieveChunks({
    required int requestId,
    required String question,
  }) async {
    try {
      final context = await _channel.invokeMethod<String>(
        'backendRetrieveChunks',
        {'requestId': requestId, 'question': question},
      );
      return context;
    } on PlatformException {
      return null;
    }
  }
}
