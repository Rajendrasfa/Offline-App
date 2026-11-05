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

class OfflineBackendHost {
  static const MethodChannel _channel = MethodChannel('askme/offline_model');

  Future<int?> startRequest() => _channel.invokeMethod<int>('backendStartRequest');

  Future<bool> cancelRequest(int requestId) async =>
      await _channel.invokeMethod<bool>('backendCancelRequest', {'requestId': requestId}) ?? false;

  Future<bool> completeRequest(int requestId) async =>
      await _channel.invokeMethod<bool>('backendCompleteRequest', {'requestId': requestId}) ?? false;

  Future<OfflineBackendRuntimeInfo> inspect() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'backendRuntimeInfo',
    );
    if (result == null) {
      throw const FormatException('Native backend returned no runtime information.');
    }
    return OfflineBackendRuntimeInfo.fromMap(result);
  }
}
