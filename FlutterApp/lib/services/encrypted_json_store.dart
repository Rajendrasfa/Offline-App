import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Shared AES-256-GCM encrypted JSON list persistence backed by Android Keystore.
/// Plaintext records are never written to disk, and write operations are serialized
/// so rapid updates cannot overwrite each other.
class EncryptedJsonFileStore {
  EncryptedJsonFileStore({
    required this.keyName,
    required this.fileName,
  });

  final String keyName;
  final String fileName;

  static const _storage = FlutterSecureStorage();
  final _cipher = AesGcm.with256bits();
  Future<void> _writeQueue = Future<void>.value();

  Future<SecretKey> _key() async {
    var encoded = await _storage.read(key: keyName);
    if (encoded == null) {
      final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      encoded = base64Encode(bytes);
      await _storage.write(key: keyName, value: encoded);
    }
    return SecretKey(base64Decode(encoded));
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }

  Future<List<dynamic>> readList() async {
    final file = await _file();
    if (!await file.exists()) {
      return [];
    }
    final raw = await file.readAsBytes();
    if (raw.length < 12 + 16) {
      throw const FormatException('Encrypted local store is invalid.');
    }
    final box = SecretBox(
      raw.sublist(12, raw.length - 16),
      nonce: raw.sublist(0, 12),
      mac: Mac(raw.sublist(raw.length - 16)),
    );
    final clear = await _cipher.decrypt(box, secretKey: await _key());
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! List<dynamic>) {
      return [];
    }
    return decoded;
  }

  Future<void> writeList(List<Object?> items) async {
    final nonce = _cipher.newNonce();
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(items)),
      secretKey: await _key(),
      nonce: nonce,
    );
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(
      [...box.nonce, ...box.cipherText, ...box.mac.bytes],
      flush: true,
    );
    await temp.rename(file.path);
  }

  Future<void> serialized(Future<void> Function() action) {
    final operation = _writeQueue.then((_) => action());
    _writeQueue = operation.catchError((_) {});
    return operation;
  }

  Future<void> clear() {
    return serialized(() async {
      final file = await _file();
      if (await file.exists()) {
        await file.delete();
      }
    });
  }
}
