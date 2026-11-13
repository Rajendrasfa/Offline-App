import 'encrypted_json_store.dart';

class AskMeHistoryItem {
  const AskMeHistoryItem({
    required this.requestId,
    required this.question,
    required this.status,
    required this.createdAt,
    this.answer,
    this.sources = const [],
  });

  final String requestId;
  final String question;
  final String status; // Pending, Completed, Cancelled, Failed
  final DateTime createdAt;
  final String? answer;
  final List<String> sources;

  Map<String, Object?> toJson() => {
        'id': requestId,
        'question': question,
        'status': status,
        'createdAt': createdAt.toIso8601String(),
        'answer': answer,
        if (sources.isNotEmpty) 'sources': sources,
      };

  factory AskMeHistoryItem.fromJson(Map<String, dynamic> j) => AskMeHistoryItem(
        requestId: j['id'] as String,
        question: j['question'] as String,
        status: j['status'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        answer: j['answer'] as String?,
        sources: (j['sources'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
      );
}

/// AES-256-GCM encrypted history. The key is stored using Android Keystore-backed
/// flutter_secure_storage; plaintext history is never written to disk.
class SecureHistoryStore {
  final _store = EncryptedJsonFileStore(
    keyName: 'askme_history_key_v1',
    fileName: 'askme_history_v1.bin',
  );

  Future<List<AskMeHistoryItem>> readAll() async {
    final list = await _store.readList();
    return list
        .map((e) => AskMeHistoryItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> writeAll(List<AskMeHistoryItem> items) =>
      _store.writeList(items.map((e) => e.toJson()).toList());

  Future<void> upsert(AskMeHistoryItem item) {
    // Serialize read-modify-write operations so fast successive requests cannot
    // overwrite one another's history entries.
    return _store.serialized(() async {
      final items = await readAll();
      final index = items.indexWhere((e) => e.requestId == item.requestId);
      if (index < 0) {
        items.insert(0, item);
      } else {
        items[index] = item;
      }
      await writeAll(items);
    });
  }

  Future<void> delete(String requestId) {
    return _store.serialized(() async {
      final items = await readAll();
      items.removeWhere((e) => e.requestId == requestId);
      await writeAll(items);
    });
  }

  Future<void> deleteMany(Set<String> requestIds) {
    return _store.serialized(() async {
      final items = await readAll();
      items.removeWhere((e) => requestIds.contains(e.requestId));
      await writeAll(items);
    });
  }

  Future<void> clearAll() => _store.clear();
}
