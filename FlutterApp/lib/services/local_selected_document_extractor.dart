import 'dart:io';

import 'package:doc_text_extractor/doc_text_extractor.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Extracts text from bytes supplied by the user. The temporary working copy
/// is deleted in a finally block; the selected original is never modified.
class LocalSelectedDocumentExtractor {
  static const _maxBytes = 25 * 1024 * 1024;

  Future<String> extract({
    required String fileName,
    required List<int> bytes,
    required Future<void> cancelled,
  }) async {
    if (bytes.isEmpty) throw const FormatException('The selected file is empty.');
    if (bytes.length > _maxBytes) {
      throw const FormatException('Documents larger than 25 MB are not supported yet.');
    }
    await _throwIfCancelled(cancelled);

    final extension = p.extension(fileName).toLowerCase();
    if (!const {'.pdf', '.docx', '.txt', '.md', '.csv', '.json'}.contains(extension)) {
      throw const FormatException('Supported formats: PDF, DOCX, TXT, MD, CSV and JSON.');
    }

    final directory = await getTemporaryDirectory();
    final tempFile = File(p.join(
      directory.path,
      'askme-${DateTime.now().microsecondsSinceEpoch}$extension',
    ));

    try {
      await tempFile.writeAsBytes(bytes, flush: true);
      await _throwIfCancelled(cancelled);

      String text;
      if (extension == '.txt' || extension == '.md' ||
          extension == '.csv' || extension == '.json') {
        text = await tempFile.readAsString();
      } else {
        // Local path only: do not call TextExtractor with a URL.
        final result = await TextExtractor().extractText(
          tempFile.path,
          isUrl: false,
        );
        text = (result['text'] as String?) ?? '';
      }

      await _throwIfCancelled(cancelled);
      final normalized = text.replaceAll('\u0000', '').trim();
      if (normalized.isEmpty) {
        throw const FormatException(
          'No selectable text was found. Scanned/image-only PDFs need OCR, which is not included yet.',
        );
      }
      return normalized;
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Future<void> _throwIfCancelled(Future<void> cancelled) async {
    final wasCancelled = await Future.any<bool>([
      cancelled.then((_) => true),
      Future<void>.delayed(Duration.zero).then((_) => false),
    ]);
    if (wasCancelled) throw const DocumentExtractionCancelled();
  }
}

class DocumentExtractionCancelled implements Exception {
  const DocumentExtractionCancelled();

  @override
  String toString() => 'DOCUMENT_EXTRACTION_CANCELLED';
}
