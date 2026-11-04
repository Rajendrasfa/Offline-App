import 'package:flutter/services.dart';

class ImportedModelInfo {
  const ImportedModelInfo({
    required this.storedName,
    required this.sizeBytes,
    required this.sha256,
    required this.validated,
    this.fileName,
    this.message,
  });

  final String storedName;
  final int sizeBytes;
  final String sha256;
  final bool validated;
  final String? fileName;
  final String? message;

  factory ImportedModelInfo.fromMap(Map<dynamic, dynamic> map) =>
      ImportedModelInfo(
        storedName: map['storedName'] as String,
        sizeBytes: (map['sizeBytes'] as num).toInt(),
        sha256: (map['sha256'] as String?) ?? '',
        validated: map['validated'] as bool? ?? false,
        fileName: map['fileName'] as String?,
        message: map['message'] as String?,
      );
}

/// Imports only a file explicitly selected by the user. The native layer
/// stores it in app-private storage and never uploads or auto-downloads it.
/// Import does NOT imply that the model is supported by an inference runtime.
class OfflineModelStore {
  static const _channel = MethodChannel('askme/offline_model');

  Future<ImportedModelInfo?> importModel() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>?>('importModel');
    if (result == null) return null;
    return ImportedModelInfo.fromMap(result);
  }

  Future<Map<dynamic, dynamic>?> getInfo() =>
      _channel.invokeMethod<Map<dynamic, dynamic>?>('modelInfo');

  Future<bool> removeModel() async =>
      await _channel.invokeMethod<bool>('removeModel') ?? false;
}
