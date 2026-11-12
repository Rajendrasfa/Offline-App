import 'encrypted_json_store.dart';

/// A locally extracted or scanned document stored under a user-assigned name.
class SavedDocument {
  const SavedDocument({
    required this.id,
    required this.name,
    required this.originalFileName,
    required this.sourceType,
    required this.extractedText,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String originalFileName;
  final String sourceType; // 'scan', 'image', 'pdf', 'docx', 'text'
  final String extractedText;
  final DateTime createdAt;

  SavedDocument copyWith({
    String? name,
    String? originalFileName,
    String? sourceType,
    String? extractedText,
  }) =>
      SavedDocument(
        id: id,
        name: name ?? this.name,
        originalFileName: originalFileName ?? this.originalFileName,
        sourceType: sourceType ?? this.sourceType,
        extractedText: extractedText ?? this.extractedText,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'originalFileName': originalFileName,
        'sourceType': sourceType,
        'extractedText': extractedText,
        'createdAt': createdAt.toIso8601String(),
      };

  factory SavedDocument.fromJson(Map<String, dynamic> j) => SavedDocument(
        id: j['id'] as String,
        name: j['name'] as String,
        originalFileName: j['originalFileName'] as String,
        sourceType: (j['sourceType'] as String?) ?? 'text',
        extractedText: j['extractedText'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
      );

  static String inferSourceType(String fileName, {bool isCameraScan = false}) {
    if (isCameraScan) {
      return 'scan';
    }
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.pdf')) {
      return 'pdf';
    }
    if (lower.endsWith('.docx')) {
      return 'docx';
    }
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp')) {
      return 'image';
    }
    return 'text';
  }
}

/// AES-256-GCM encrypted vault of named scanned/uploaded documents.
class SecureDocumentStore {
  final _store = EncryptedJsonFileStore(
    keyName: 'askme_documents_key_v1',
    fileName: 'askme_documents_v1.bin',
  );

  Future<List<SavedDocument>> readAll() async {
    final list = await _store.readList();
    return list
        .map((e) => SavedDocument.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> writeAll(List<SavedDocument> docs) =>
      _store.writeList(docs.map((e) => e.toJson()).toList());

  Future<void> upsert(SavedDocument doc) {
    return _store.serialized(() async {
      final docs = await readAll();
      final index = docs.indexWhere((e) => e.id == doc.id);
      if (index < 0) {
        docs.insert(0, doc);
      } else {
        docs[index] = doc;
      }
      await writeAll(docs);
    });
  }

  Future<void> rename(String id, String newName) {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Document name cannot be empty.');
    }
    return _store.serialized(() async {
      final docs = await readAll();
      final index = docs.indexWhere((e) => e.id == id);
      if (index >= 0) {
        docs[index] = docs[index].copyWith(name: trimmed);
        await writeAll(docs);
      }
    });
  }

  Future<void> delete(String id) {
    return _store.serialized(() async {
      final docs = await readAll();
      docs.removeWhere((e) => e.id == id);
      await writeAll(docs);
    });
  }

  Future<void> clearAll() => _store.clear();
}
