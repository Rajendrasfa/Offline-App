import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

class AskMeHistoryItem {
  const AskMeHistoryItem({required this.requestId, required this.question,
    required this.status, required this.createdAt, this.answer});
  final String requestId;
  final String question;
  final String status; // Pending, Completed, Cancelled, Failed
  final DateTime createdAt;
  final String? answer;

  Map<String, Object?> toJson() => {'id': requestId, 'question': question,
    'status': status, 'createdAt': createdAt.toIso8601String(), 'answer': answer};
  factory AskMeHistoryItem.fromJson(Map<String, dynamic> j) => AskMeHistoryItem(
    requestId: j['id'] as String, question: j['question'] as String,
    status: j['status'] as String, createdAt: DateTime.parse(j['createdAt'] as String),
    answer: j['answer'] as String?);
}

/// AES-256-GCM encrypted history. The key is stored using Android Keystore-backed
/// flutter_secure_storage; plaintext history is never written to disk.
class SecureHistoryStore {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'askme_history_key_v1';
  static const _fileName = 'askme_history_v1.bin';
  final _cipher = AesGcm.with256bits();
  Future<void> _writeQueue = Future<void>.value();

  Future<SecretKey> _key() async {
    var encoded = await _storage.read(key: _keyName);
    if (encoded == null) {
      final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      encoded = base64Encode(bytes);
      await _storage.write(key: _keyName, value: encoded);
    }
    return SecretKey(base64Decode(encoded));
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<List<AskMeHistoryItem>> readAll() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final raw = await file.readAsBytes();
    if (raw.length < 12 + 16) throw const FormatException('Encrypted history is invalid.');
    final box = SecretBox(raw.sublist(12, raw.length - 16),
      nonce: raw.sublist(0, 12), mac: Mac(raw.sublist(raw.length - 16)));
    final clear = await _cipher.decrypt(box, secretKey: await _key());
    final list = jsonDecode(utf8.decode(clear)) as List<dynamic>;
    return list.map((e) => AskMeHistoryItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> writeAll(List<AskMeHistoryItem> items) async {
    final nonce = _cipher.newNonce();
    final box = await _cipher.encrypt(utf8.encode(jsonEncode(items.map((e) => e.toJson()).toList())),
      secretKey: await _key(), nonce: nonce);
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes([...box.nonce, ...box.cipherText, ...box.mac.bytes], flush: true);
    await temp.rename(file.path);
  }

  Future<void> upsert(AskMeHistoryItem item) {
    // Serialize read-modify-write operations so fast successive requests cannot
    // overwrite one another's history entries.
    final operation = _writeQueue.then((_) async {
      final items = await readAll();
      final index = items.indexWhere((e) => e.requestId == item.requestId);
      if (index < 0) { items.insert(0, item); } else { items[index] = item; }
      await writeAll(items);
    });
    _writeQueue = operation.catchError((_) {});
    return operation;
  }
}
