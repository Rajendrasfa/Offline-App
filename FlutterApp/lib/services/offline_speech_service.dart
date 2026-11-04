import 'package:flutter/services.dart';

/// Android system speech services are used only when an installed offline
/// recognizer/voice is available. This service never falls back to network APIs.
class OfflineSpeechService {
  static const MethodChannel _channel = MethodChannel('askme/offline_model');

  Future<String> listen({required String language}) async {
    final result = await _channel.invokeMethod<String>(
      'startOfflineSpeech',
      {'language': language},
    );
    return result ?? '';
  }

  Future<void> stopListening() async {
    await _channel.invokeMethod<bool>('stopOfflineSpeech');
  }

  Future<void> speak({required String text, required String language}) async {
    await _channel.invokeMethod<bool>(
      'speakOffline',
      {'text': text, 'language': language},
    );
  }

  Future<void> stopSpeaking() async {
    await _channel.invokeMethod<bool>('stopSpeaking');
  }
}
