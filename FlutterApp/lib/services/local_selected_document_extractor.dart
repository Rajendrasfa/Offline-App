import 'dart:async';
import 'dart:io';

import 'package:doc_text_extractor/doc_text_extractor.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Extracts only bytes explicitly supplied by the user.
/// The temporary copy is private to the app and deleted after parsing settles.
class LocalSelectedDocumentExtractor {
  static const _maxBytes = 25 * 1024 * 1024;

  Future<String> extract({
    required String fileName,
    required List<int> bytes,
    required Future<void> cancelled,
  }) async {
    if (bytes.isEmpty) throw const FormatException('The selected file is empty.');
    if (bytes.length > _maxBytes) {
      throw const FormatException('Documents larger than 25 MB are not supported.');
    }
    final extension = p.extension(fileName).toLowerCase();
    if (!const {'.pdf', '.docx', '.txt', '.md', '.csv', '.json'}.contains(extension)) {
      throw const FormatException('Supported formats: PDF, DOCX, TXT, MD, CSV and JSON.');
    }

    final directory = await getTemporaryDirectory();
    _throwIfAlreadyCancelled(cancelled);
    final tempFile = File(p.join(
      directory.path,
      'askme-${DateTime.now().microsecondsSinceEpoch}$extension',
    ));
    await tempFile.writeAsBytes(bytes, flush: true);

    final parse = _parseFile(tempFile, extension);
    // The package performs parsing in its own isolate for supported versions.
    // Dart cannot forcibly terminate that package's isolate, so cancellation
    // returns immediately while cleanup runs as soon as parsing settles.
    try {
      final text = await Future.any<String>([
        parse,
        cancelled.then<String>((_) => throw const DocumentExtractionCancelled()),
      ]);
      final normalized = text.replaceAll('\u0000', '').trim();
      if (normalized.isEmpty) {
        throw const FormatException(
          'No selectable text found. Scanned/image-only PDFs require OCR.',
        );
      }
      return normalized;
    } finally {
      unawaited(parse.then((_) async {
        if (await tempFile.exists()) await tempFile.delete();
      }, onError: (Object _) async {
        if (await tempFile.exists()) await tempFile.delete();
      }));
    }
  }

  Future<String> _parseFile(File file, String extension) async {
    if (extension == '.txt' || extension == '.md' ||
        extension == '.csv' || extension == '.json') {
      return file.readAsString();
    }
    final result = await TextExtractor().extractText(file.path, isUrl: false);
    return (result['text'] as String?) ?? '';
  }
}

class DocumentExtractionCancelled implements Exception {
  const DocumentExtractionCancelled();

  @override
  String toString() => 'DOCUMENT_EXTRACTION_CANCELLED';
}
