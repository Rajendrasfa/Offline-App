import 'dart:async';
import 'dart:io';

import 'package:doc_text_extractor/doc_text_extractor.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Extracts only bytes explicitly supplied by the user.
/// Supports documents (PDF, DOCX, TXT, MD, CSV, JSON) and images
/// (JPG, JPEG, PNG, WEBP, BMP) using local offline extraction and on-device OCR.
/// Temporary copies stay private to the app and are deleted as soon as parsing settles.
class LocalSelectedDocumentExtractor {
  static const _maxBytes = 25 * 1024 * 1024;
  static const MethodChannel _channel = MethodChannel('askme/offline_model');

  static const _imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
  };

  static const _supportedExtensions = {
    '.pdf',
    '.docx',
    '.txt',
    '.md',
    '.csv',
    '.json',
    ..._imageExtensions,
  };

  /// Opens the device camera via Android MediaStore capture intent and returns
  /// the captured JPEG bytes, or null if the user cancelled.
  Future<Uint8List?> captureCameraImage() async {
    return _channel.invokeMethod<Uint8List>('captureCameraImage');
  }

  Future<String> extract({
    required String fileName,
    required List<int> bytes,
    required Future<void> cancelled,
  }) async {
    if (bytes.isEmpty) {
      throw const FormatException('The selected file is empty.');
    }
    if (bytes.length > _maxBytes) {
      throw const FormatException('Documents larger than 25 MB are not supported.');
    }
    final extension = p.extension(fileName).toLowerCase();
    if (!_supportedExtensions.contains(extension)) {
      throw const FormatException(
        'Supported formats: PDF, DOCX, TXT, MD, CSV, JSON and Images (JPG, JPEG, PNG, WEBP, BMP).',
      );
    }

    if (_imageExtensions.contains(extension)) {
      final parse = _extractFromImage(bytes);
      final text = await Future.any<String>([
        parse,
        cancelled.then<String>((_) => throw const DocumentExtractionCancelled()),
      ]);
      final normalized = text.replaceAll('\u0000', '').trim();
      if (normalized.isEmpty) {
        throw const FormatException(
          'No readable text was detected in the selected image.',
        );
      }
      return normalized;
    }

    final directory = await getTemporaryDirectory();
    final tempFile = File(p.join(
      directory.path,
      'askme-${DateTime.now().microsecondsSinceEpoch}$extension',
    ));
    await tempFile.writeAsBytes(bytes, flush: true);

    final parse = _parseDocumentFile(tempFile, extension);
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
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }, onError: (Object _) async {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }));
    }
  }

  Future<String> _parseDocumentFile(File file, String extension) async {
    if (extension == '.txt' ||
        extension == '.md' ||
        extension == '.csv' ||
        extension == '.json') {
      return file.readAsString();
    }
    final result = await TextExtractor().extractText(file.path, isUrl: false);
    return result.text;
  }

  Future<String> _extractFromImage(List<int> bytes) async {
    try {
      final text = await _channel.invokeMethod<String>(
        'extractTextFromImage',
        {'bytes': Uint8List.fromList(bytes)},
      );
      return text ?? '';
    } on PlatformException catch (e) {
      throw FormatException(e.message ?? 'Image text recognition failed.');
    }
  }
}

class DocumentExtractionCancelled implements Exception {
  const DocumentExtractionCancelled();

  @override
  String toString() => 'DOCUMENT_EXTRACTION_CANCELLED';
}
