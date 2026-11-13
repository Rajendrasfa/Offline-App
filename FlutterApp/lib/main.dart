import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'services/askme_engine.dart';
import 'services/document_query_resolver.dart';
import 'services/local_selected_document_extractor.dart';
import 'services/offline_backend_host.dart';
import 'services/offline_model_store.dart';
import 'services/offline_speech_service.dart';
import 'services/request_cancellation.dart';
import 'services/secure_document_store.dart';
import 'services/secure_history_store.dart';

void main() => runApp(const AskMeApp());

class AskMeApp extends StatelessWidget {
  const AskMeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AskMe',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF087CF0)),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFF5F8FC),
        ),
        home: const AskMeHomePage(),
      );
}

class AskMeHomePage extends StatefulWidget {
  const AskMeHomePage({super.key});

  @override
  State<AskMeHomePage> createState() => _AskMeHomePageState();
}

class _AskMeHomePageState extends State<AskMeHomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
    initialIndex: 0, // Default tab: Ask
  );

  final _question = TextEditingController();
  final _history = SecureHistoryStore();
  final _documentStore = SecureDocumentStore();
  final _cancellation = RequestCancellation();
  final _modelStore = OfflineModelStore();
  final _documentExtractor = LocalSelectedDocumentExtractor();
  final _speech = OfflineSpeechService();
  final _backendHost = OfflineBackendHost();
  late final AskMeEngine _engine = AndroidLlamaOfflineEngine(
    backendHost: _backendHost,
  );

  OfflineBackendRuntimeInfo? _backendRuntimeInfo;
  ImportedModelInfo? _modelInfo;
  Map<dynamic, dynamic>? _deviceProfile;

  final List<AskMeHistoryItem> _records = [];
  final List<SavedDocument> _documents = [];

  bool _isSelectionMode = false;
  final Set<String> _selectedRequestIds = <String>{};

  AskScopeMode _scopeMode = AskScopeMode.auto;
  String? _pinnedDocumentId;
  String _mentionFilter = '';
  bool _showMentionBar = false;

  bool _listening = false;
  bool _modelBusy = false;
  bool _busy = false;
  bool _documentBusy = false;
  Completer<void>? _documentCancel;
  String? _activeRequestId;
  String _status = 'Offline mode';
  String _activeStatus = 'Thinking locally…';

  String _formatTime(DateTime dt) {
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  @override
  void initState() {
    super.initState();
    _question.addListener(_onQuestionChanged);
    _loadHistory();
    _loadDocuments();
    _loadModelInfo();
    _loadBackendRuntimeInfo();
  }

  void _onQuestionChanged() {
    final text = _question.text;
    final selection = _question.selection;
    final cursor =
        selection.isValid ? selection.baseOffset : text.length;
    final prefix = text.substring(0, cursor.clamp(0, text.length));
    final atIndex = prefix.lastIndexOf('@');

    final shouldShow = atIndex >= 0 &&
        (atIndex == 0 || prefix[atIndex - 1].trim().isEmpty) &&
        !prefix.substring(atIndex).contains('\n') &&
        _documents.isNotEmpty;

    final filter = shouldShow ? prefix.substring(atIndex + 1).toLowerCase() : '';
    if (shouldShow != _showMentionBar || filter != _mentionFilter) {
      setState(() {
        _showMentionBar = shouldShow;
        _mentionFilter = filter;
      });
    }
  }

  void _insertDocumentMention(SavedDocument doc) {
    final text = _question.text;
    final selection = _question.selection;
    final cursor = selection.isValid ? selection.baseOffset : text.length;
    final safeCursor = cursor.clamp(0, text.length);
    final prefix = text.substring(0, safeCursor);
    final suffix = text.substring(safeCursor);
    final atIndex = prefix.lastIndexOf('@');
    final beforeAt = atIndex >= 0 ? prefix.substring(0, atIndex) : prefix;
    final insertion = '@${doc.name} ';
    final updated = '$beforeAt$insertion$suffix';

    _question.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: beforeAt.length + insertion.length,
      ),
    );
    setState(() {
      _showMentionBar = false;
      _mentionFilter = '';
    });
  }

  Future<void> _loadBackendRuntimeInfo() async {
    try {
      final info = await _backendHost.inspect();
      if (mounted) {
        setState(() => _backendRuntimeInfo = info);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _backendRuntimeInfo = OfflineBackendRuntimeInfo(
            available: false,
            apiVersion: 0,
            error: error.toString(),
          );
        });
      }
    }
  }

  Future<void> _loadModelInfo() async {
    try {
      final profile = await const MethodChannel('askme/offline_model')
          .invokeMethod<Map<dynamic, dynamic>>('deviceProfile');
      if (mounted) {
        setState(() => _deviceProfile = profile);
      }
    } catch (_) {}

    try {
      final map = await _modelStore.getInfo();
      if (!mounted) {
        return;
      }
      setState(() {
        _modelInfo = map == null ? null : ImportedModelInfo.fromMap(map);
      });
    } on MissingPluginException {
      // Expected in host widget test environments without Android plugins.
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'Model status unavailable: $e');
      }
    }
  }

  Future<void> _importModel() async {
    if (_modelBusy || _busy) {
      return;
    }
    setState(() {
      _modelBusy = true;
      _status = 'Selecting model…';
    });
    try {
      final imported = await _modelStore.importModel();
      if (!mounted) {
        return;
      }
      if (imported == null) {
        setState(() => _status = 'Import cancelled');
        return;
      }
      setState(() => _modelInfo = imported);
      _message(
        'Model imported. GGUF compatibility will be checked when loaded.',
      );
    } on PlatformException catch (e) {
      _message('Model import failed (${e.code}): ${e.message ?? ''}');
    } catch (e) {
      _message('Model import failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _modelBusy = false;
          _status = 'Offline mode';
        });
      }
    }
  }

  Future<void> _removeModel() async {
    if (_modelBusy || _busy) {
      return;
    }
    setState(() => _modelBusy = true);
    try {
      final removed = await _modelStore.removeModel();
      if (!mounted) {
        return;
      }
      if (removed) {
        setState(() => _modelInfo = null);
        _message('Imported model removed from app storage.');
      } else {
        _message('Could not remove imported model.');
      }
    } catch (e) {
      _message('Remove failed: $e');
    } finally {
      if (mounted) {
        setState(() => _modelBusy = false);
      }
    }
  }

  Future<void> _loadHistory() async {
    try {
      final items = await _history.readAll();
      if (!mounted) {
        return;
      }
      setState(() {
        _records
          ..clear()
          ..addAll(items);
        _status = 'Offline mode';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _status = 'History could not be decrypted');
    }
  }

  Future<void> _loadDocuments() async {
    try {
      final docs = await _documentStore.readAll();
      if (!mounted) {
        return;
      }
      setState(() {
        _documents
          ..clear()
          ..addAll(docs);
        if (_pinnedDocumentId != null &&
            !_documents.any((d) => d.id == _pinnedDocumentId)) {
          _pinnedDocumentId = null;
          if (_scopeMode == AskScopeMode.pinned) {
            _scopeMode = AskScopeMode.auto;
          }
        }
      });
    } on MissingPluginException {
      // Expected in host widget test environments without Android plugins.
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Encrypted documents could not be decrypted');
      }
    }
  }

  Future<void> _uploadDocument() async {
    if (_documentBusy || _busy) {
      return;
    }
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'pdf',
          'docx',
          'txt',
          'md',
          'csv',
          'json',
          'jpg',
          'jpeg',
          'png',
          'webp',
          'bmp',
        ],
        allowMultiple: false,
        withData: true,
      );
      if (!mounted || result == null || result.files.isEmpty) {
        return;
      }
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        throw StateError('Selected file bytes are unavailable.');
      }
      await _extractAndSaveNamedDocument(
        originalFileName: file.name,
        bytes: bytes,
        isCameraScan: false,
      );
    } catch (e) {
      if (mounted) {
        _message('Could not read selected file: $e');
      }
    }
  }

  Future<void> _scanWithCamera() async {
    if (_documentBusy || _busy) {
      return;
    }
    try {
      setState(() => _status = 'Opening camera…');
      final bytes = await _documentExtractor.captureCameraImage();
      if (!mounted || bytes == null || bytes.isEmpty) {
        setState(() => _status = 'Offline mode');
        return;
      }
      final now = DateTime.now();
      final stamp =
          '${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}';
      await _extractAndSaveNamedDocument(
        originalFileName: 'scan_$stamp.jpg',
        bytes: bytes,
        isCameraScan: true,
      );
    } on PlatformException catch (e) {
      if (mounted) {
        _message(e.message ?? 'Camera scan is unavailable on this device.');
      }
    } catch (e) {
      if (mounted) {
        _message('Camera scan failed: $e');
      }
    } finally {
      if (mounted && !_documentBusy) {
        setState(() => _status = 'Offline mode');
      }
    }
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  Future<void> _extractAndSaveNamedDocument({
    required String originalFileName,
    required List<int> bytes,
    required bool isCameraScan,
  }) async {
    final cancellation = Completer<void>();
    _documentCancel = cancellation;
    setState(() {
      _documentBusy = true;
      _status = isCameraScan
          ? 'Reading scanned image offline…'
          : 'Extracting selected document locally…';
    });

    try {
      final extractedText = await _documentExtractor.extract(
        fileName: originalFileName,
        bytes: bytes,
        cancelled: cancellation.future,
      );
      if (!mounted || cancellation.isCompleted) {
        return;
      }

      setState(() {
        _documentBusy = false;
        _status = 'Offline mode';
      });
      _documentCancel = null;

      final defaultName = _defaultDocumentName(
        originalFileName: originalFileName,
        isCameraScan: isCameraScan,
      );
      final chosenName = await _promptForDocumentName(
        title: isCameraScan ? 'Name Scanned Document' : 'Name Uploaded Document',
        initialName: defaultName,
        previewText: extractedText,
      );
      if (!mounted || chosenName == null) {
        return;
      }

      final doc = SavedDocument(
        id: 'doc-${DateTime.now().microsecondsSinceEpoch}',
        name: _deduplicateName(chosenName),
        originalFileName: originalFileName,
        sourceType: SavedDocument.inferSourceType(
          originalFileName,
          isCameraScan: isCameraScan,
        ),
        extractedText: extractedText,
        createdAt: DateTime.now(),
      );
      await _documentStore.upsert(doc);
      if (!mounted) {
        return;
      }
      setState(() {
        _documents.insert(0, doc);
      });
      _message(
        'Saved "${doc.name}". Now you can ask about it in the Ask tab.',
      );
    } on DocumentExtractionCancelled {
      if (mounted) {
        _message('Document reading cancelled.');
      }
    } catch (e) {
      if (mounted) {
        _message('Could not extract text: $e');
      }
    } finally {
      _documentCancel = null;
      if (mounted) {
        setState(() {
          _documentBusy = false;
          _status = 'Offline mode';
        });
      }
    }
  }

  String _defaultDocumentName({
    required String originalFileName,
    required bool isCameraScan,
  }) {
    if (isCameraScan) {
      final now = DateTime.now();
      return 'Scan ${_two(now.day)}-${_two(now.month)} ${_two(now.hour)}:${_two(now.minute)}';
    }
    final base = p.basenameWithoutExtension(originalFileName).trim();
    return base.isEmpty ? 'Document' : base;
  }

  String _deduplicateName(String desiredName, {String? ignoreId}) {
    final base = desiredName.trim();
    final existingLower = _documents
        .where((d) => d.id != ignoreId)
        .map((d) => d.name.toLowerCase())
        .toSet();
    if (!existingLower.contains(base.toLowerCase())) {
      return base;
    }
    var suffix = 2;
    while (existingLower.contains('$base ($suffix)'.toLowerCase())) {
      suffix++;
    }
    return '$base ($suffix)';
  }

  Future<String?> _promptForDocumentName({
    required String title,
    required String initialName,
    String? previewText,
  }) async {
    final controller = TextEditingController(text: initialName);
    String? errorText;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: 'Document name',
                    hintText: 'e.g. Bijli Bill, Resume, Notes',
                    border: const OutlineInputBorder(),
                    errorText: errorText,
                  ),
                ),
                if (previewText != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Extracted text preview (${previewText.length} chars):',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.blueGrey,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 110),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F6FB),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        previewText,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final val = controller.text.trim();
                if (val.isEmpty) {
                  setDialogState(
                    () => errorText = 'Please enter a document name.',
                  );
                  return;
                }
                Navigator.of(dialogContext).pop(val);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _renameDocument(SavedDocument doc) async {
    final newName = await _promptForDocumentName(
      title: 'Rename Document',
      initialName: doc.name,
    );
    if (!mounted || newName == null || newName.trim() == doc.name) {
      return;
    }
    final uniqueName = _deduplicateName(newName, ignoreId: doc.id);
    await _documentStore.rename(doc.id, uniqueName);
    if (!mounted) {
      return;
    }
    setState(() {
      final idx = _documents.indexWhere((d) => d.id == doc.id);
      if (idx >= 0) {
        _documents[idx] = _documents[idx].copyWith(name: uniqueName);
      }
    });
    _message('Renamed to "$uniqueName".');
  }

  Future<void> _deleteDocument(SavedDocument doc) async {
    await _documentStore.delete(doc.id);
    if (!mounted) {
      return;
    }
    setState(() {
      _documents.removeWhere((d) => d.id == doc.id);
      if (_pinnedDocumentId == doc.id) {
        _pinnedDocumentId = null;
        if (_scopeMode == AskScopeMode.pinned) {
          _scopeMode = AskScopeMode.auto;
        }
      }
    });
    _message('Removed "${doc.name}".');
  }

  void _askAboutDocument(SavedDocument doc) {
    setState(() {
      _scopeMode = AskScopeMode.pinned;
      _pinnedDocumentId = doc.id;
    });
    _tabController.animateTo(0);
  }

  void _showDocumentPreview(SavedDocument doc) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(doc.name),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'File: ${doc.originalFileName} • ${doc.extractedText.length} chars',
                  style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
                ),
                const Divider(height: 16),
                SelectableText(
                  doc.extractedText,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _renameDocument(doc);
            },
            child: const Text('Rename'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _askAboutDocument(doc);
            },
            icon: const Icon(Icons.chat_outlined, size: 18),
            label: const Text('Ask Question'),
          ),
        ],
      ),
    );
  }

  Future<void> _listen(String language) async {
    if (_busy || _documentBusy || _listening) {
      return;
    }
    setState(() {
      _listening = true;
      _status = 'Listening offline…';
    });
    try {
      final recognized = await _speech.listen(language: language);
      if (mounted && recognized.trim().isNotEmpty) {
        _question.text = recognized.trim();
        _question.selection =
            TextSelection.collapsed(offset: _question.text.length);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        _message(e.message ?? 'Offline speech recognition is unavailable.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _listening = false;
          _status = 'Offline mode';
        });
      }
    }
  }

  Future<void> _speak(String text) async {
    final language =
        RegExp(r'[\u0900-\u097F]').hasMatch(text) ? 'hi-IN' : 'en-US';
    try {
      await _speech.speak(text: text, language: language);
    } on PlatformException catch (e) {
      if (mounted) {
        _message(e.message ?? 'Offline voice is unavailable on this device.');
      }
    }
  }

  Future<void> _ask([String? overrideQuestion]) async {
    if (_documentBusy) {
      return;
    }
    final rawText = (overrideQuestion ?? _question.text).trim();
    if (rawText.isEmpty) {
      return;
    }

    await _cancel(showMessage: false);
    final lease = _cancellation.start();

    final resolved = DocumentQueryResolver.resolve(
      question: rawText,
      savedDocuments: _documents,
      mode: _scopeMode,
      pinnedDocumentId: _pinnedDocumentId,
    );
    final selectedDocs = resolved.documents
        .map(
          (doc) => AskMeDocument(
            name: doc.name,
            bytes: const [],
            extractedText: doc.extractedText,
          ),
        )
        .toList();
    final sourceNames = resolved.documents.map((d) => d.name).toList();

    final id = '${DateTime.now().microsecondsSinceEpoch}-${lease.id}';
    final item = AskMeHistoryItem(
      requestId: id,
      question: rawText,
      status: 'Pending',
      createdAt: DateTime.now(),
      sources: sourceNames,
    );

    if (overrideQuestion == null) {
      _question.clear();
    }
    setState(() {
      _records.insert(0, item);
      _busy = true;
      _activeRequestId = id;
      _showMentionBar = false;
      _activeStatus = selectedDocs.isEmpty
          ? 'Thinking locally…'
          : 'Reading ${sourceNames.join(", ")}…';
      _status = _activeStatus;
    });
    await _persist(item);

    try {
      final result = await _engine.answer(
        question: resolved.cleanedQuestion,
        documents: selectedDocs,
        cancelled: lease.cancelled,
      );
      if (!mounted ||
          !_cancellation.isCurrent(lease.id) ||
          _activeRequestId != id) {
        return;
      }
      final completed = AskMeHistoryItem(
        requestId: id,
        question: rawText,
        status: 'Completed',
        createdAt: item.createdAt,
        answer: result.text,
        sources: result.sources.isNotEmpty ? result.sources : sourceNames,
        answeredAt: DateTime.now(),
      );
      await _replace(completed);
    } on OfflineEngineUnavailable {
      if (!mounted || !_cancellation.isCurrent(lease.id)) {
        return;
      }
      final failed = AskMeHistoryItem(
        requestId: id,
        question: rawText,
        status: 'Setup required — offline model missing',
        createdAt: item.createdAt,
        sources: sourceNames,
        answeredAt: DateTime.now(),
      );
      await _replace(failed);
      _message(
        'Offline AI model/runtime is not installed yet. Tap the model icon at the top to import a GGUF model.',
      );
    } on PlatformException catch (e) {
      if (!mounted || !_cancellation.isCurrent(lease.id)) {
        return;
      }
      await _replace(
        AskMeHistoryItem(
          requestId: id,
          question: rawText,
          status: 'Failed: ${e.code}',
          createdAt: item.createdAt,
          sources: sourceNames,
          answeredAt: DateTime.now(),
        ),
      );
    } catch (e) {
      if (!mounted || !_cancellation.isCurrent(lease.id)) {
        return;
      }
      await _replace(
        AskMeHistoryItem(
          requestId: id,
          question: rawText,
          status: 'Failed: $e',
          createdAt: item.createdAt,
          sources: sourceNames,
          answeredAt: DateTime.now(),
        ),
      );
    } finally {
      _cancellation.complete(lease.id);
      if (mounted && _activeRequestId == id) {
        setState(() {
          _activeRequestId = null;
          _busy = false;
          _status = 'Offline mode';
        });
      }
    }
  }

  Future<void> _cancel({bool showMessage = true}) async {
    if (_listening && _activeRequestId == null) {
      await _speech.stopListening();
      if (mounted) {
        setState(() {
          _listening = false;
          _status = 'Offline mode';
        });
      }
      if (showMessage) {
        _message('Voice input cancelled.');
      }
      return;
    }
    if (_documentBusy && _activeRequestId == null) {
      final signal = _documentCancel;
      if (signal != null && !signal.isCompleted) {
        signal.complete();
      }
      if (mounted) {
        setState(() => _status = 'Cancelling document reading…');
      }
      return;
    }
    final id = _activeRequestId;
    if (id == null) {
      return;
    }
    _cancellation.cancelActive();
    await _speech.stopListening();
    await _speech.stopSpeaking();
    await _engine.stopAudio();
    final old = _records.firstWhere((x) => x.requestId == id);
    await _replace(
      AskMeHistoryItem(
        requestId: id,
        question: old.question,
        status: 'Cancelled',
        createdAt: old.createdAt,
        sources: old.sources,
        answeredAt: DateTime.now(),
      ),
    );
    if (mounted) {
      setState(() {
        _activeRequestId = null;
        _busy = false;
        _status = 'Cancelled';
      });
    }
    if (showMessage) {
      _message('Request cancelled.');
    }
  }

  void _enterSelectionMode([String? initialRequestId]) {
    setState(() {
      _isSelectionMode = true;
      _selectedRequestIds.clear();
      if (initialRequestId != null) {
        _selectedRequestIds.add(initialRequestId);
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedRequestIds.clear();
    });
  }

  void _toggleSelectTurn(String requestId) {
    setState(() {
      if (_selectedRequestIds.contains(requestId)) {
        _selectedRequestIds.remove(requestId);
      } else {
        _selectedRequestIds.add(requestId);
      }
    });
  }

  void _selectAllForDeletion() {
    setState(() {
      if (_selectedRequestIds.length == _records.length) {
        _selectedRequestIds.clear();
      } else {
        _selectedRequestIds.addAll(_records.map((r) => r.requestId));
      }
    });
  }

  Future<void> _deleteTurn(String requestId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Question?'),
        content: const Text(
          'This question and its answer will be permanently removed from offline history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    try {
      await _history.delete(requestId);
    } catch (_) {}

    if (mounted) {
      setState(() {
        _records.removeWhere((r) => r.requestId == requestId);
        _selectedRequestIds.remove(requestId);
        if (_records.isEmpty) {
          _isSelectionMode = false;
        }
      });
      _message('Question deleted.');
    }
  }

  Future<void> _confirmDeleteSelected() async {
    if (_selectedRequestIds.isEmpty) {
      return;
    }
    final count = _selectedRequestIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $count Question${count > 1 ? 's' : ''}?'),
        content: Text(
          'Selected $count question${count > 1 ? 's and their answers' : ' and answer'} will be removed from history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    final toDelete = Set<String>.from(_selectedRequestIds);
    try {
      await _history.deleteMany(toDelete);
    } catch (_) {}

    if (mounted) {
      setState(() {
        _records.removeWhere((r) => toDelete.contains(r.requestId));
        _selectedRequestIds.clear();
        _isSelectionMode = false;
      });
      _message('$count question${count > 1 ? 's' : ''} deleted.');
    }
  }

  Future<void> _clearHistory() async {
    if (_busy) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All Conversations?'),
        content: const Text(
          'All saved questions and answers in offline chat history will be permanently erased.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _history.clearAll();
    if (!mounted) {
      return;
    }
    setState(() {
      _records.clear();
      _selectedRequestIds.clear();
      _isSelectionMode = false;
    });
    _message('Conversation cleared.');
  }

  Future<void> _replace(AskMeHistoryItem item) async {
    final index = _records.indexWhere((x) => x.requestId == item.requestId);
    if (index >= 0 && mounted) {
      setState(() => _records[index] = item);
    }
    await _persist(item);
  }

  Future<void> _persist(AskMeHistoryItem item) async {
    try {
      await _history.upsert(item);
    } catch (_) {
      if (mounted) {
        _message('Encrypted history could not be saved.');
      }
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> _openExternalDownloadUrl(String url) async {
    try {
      await const MethodChannel('askme/offline_model').invokeMethod<bool>(
        'openExternalUrl',
        {'url': url},
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        _message('URL copied. Open it in your browser to download the GGUF file.');
      }
    }
  }

  Widget _buildModelDownloadOption({
    required BuildContext sheetContext,
    required String title,
    required String subtitle,
    required String url,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE0E7F1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
          ),
          const SizedBox(height: 4),
          SelectableText(
            url,
            style: const TextStyle(fontSize: 10, color: Color(0xFF063B91)),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: url));
                    Navigator.of(sheetContext).pop();
                    _message('Download URL copied to clipboard.');
                  },
                  icon: const Icon(Icons.copy_outlined, size: 15),
                  label: const Text('Copy URL', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () async {
                    Navigator.of(sheetContext).pop();
                    await _openExternalDownloadUrl(url);
                  },
                  icon: const Icon(Icons.open_in_browser, size: 15),
                  label: const Text('Download', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openModelSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.memory, color: Color(0xFF087CF0)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Offline AI Model & Runtime',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _backendRuntimeInfo?.available == true
                        ? Icons.check_circle
                        : Icons.error_outline,
                    color: _backendRuntimeInfo?.available == true
                        ? Colors.green
                        : Colors.deepOrange,
                  ),
                  title: const Text('C# Android Backend'),
                  subtitle: Text(
                    _backendRuntimeInfo == null
                        ? 'Checking…'
                        : (_backendRuntimeInfo!.available
                            ? 'Connected • ABI ${_backendRuntimeInfo!.apiVersion}'
                            : (_backendRuntimeInfo!.error.isNotEmpty
                                ? _backendRuntimeInfo!.error
                                : 'Not connected')),
                  ),
                ),
                if (_deviceProfile != null) ...[
                  Text(
                    "Device: ${_deviceProfile!['deviceTier']} • ${_deviceProfile!['cpuCores']} CPU cores • ${((_deviceProfile!['totalRamBytes'] as num) / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB RAM",
                    style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
                  ),
                  Text(
                    "CPU ABI: ${(_deviceProfile!['supportedAbis'] as List).join(', ')}",
                    style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
                  ),
                  const SizedBox(height: 8),
                ],
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Local GGUF Model',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            Text(
                              _modelInfo == null ? 'Not imported' : 'Imported',
                              style: TextStyle(
                                fontSize: 12,
                                color: _modelInfo == null
                                    ? Colors.deepOrange
                                    : Colors.green,
                              ),
                            ),
                          ],
                        ),
                        if (_modelInfo != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            '${_modelInfo!.storedName} • ${(_modelInfo!.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                          ),
                          Text(
                            'SHA-256: ${_modelInfo!.sha256}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10),
                          ),
                          if (_modelInfo!.message != null)
                            Text(
                              _modelInfo!.message!,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.blueGrey,
                              ),
                            ),
                        ] else ...[
                          const SizedBox(height: 4),
                          const Text(
                            'Import a local .gguf model file to run Gemini/ChatGPT style Q&A completely offline.',
                            style:
                                TextStyle(fontSize: 12, color: Colors.blueGrey),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: (_busy || _modelBusy)
                                    ? null
                                    : () async {
                                        Navigator.of(sheetContext).pop();
                                        await _importModel();
                                      },
                                icon: const Icon(Icons.file_open),
                                label: Text(
                                  _modelBusy
                                      ? 'Please wait…'
                                      : (_modelInfo == null
                                          ? 'Import Model'
                                          : 'Replace Model'),
                                ),
                              ),
                            ),
                            if (_modelInfo != null) ...[
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Remove model',
                                onPressed: (_busy || _modelBusy)
                                    ? null
                                    : () async {
                                        Navigator.of(sheetContext).pop();
                                        await _removeModel();
                                      },
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  color: const Color(0xFFF3F6FB),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Download Offline Model (Option 2 Setup)',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Download any Qwen2.5-1.5B GGUF file in your browser (saves to Downloads), then tap Import Model above.',
                          style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                        ),
                        _buildModelDownloadOption(
                          sheetContext: sheetContext,
                          title: 'Qwen2.5-1.5B-Instruct Q4_K_M (Recommended)',
                          subtitle: '~1.04 GB • Best Hindi + English accuracy',
                          url:
                              'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf',
                        ),
                        _buildModelDownloadOption(
                          sheetContext: sheetContext,
                          title: 'Qwen2.5-1.5B-Instruct Q3_K_M',
                          subtitle: '~786 MiB • Balanced smaller size',
                          url:
                              'https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q3_K_M.gguf',
                        ),
                        _buildModelDownloadOption(
                          sheetContext: sheetContext,
                          title: 'Qwen2.5-1.5B-Instruct Q3_K_S',
                          subtitle: '~726 MiB • Compact size',
                          url:
                              'https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q3_K_S.gguf',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    );
  }

  @override
  void dispose() {
    _question.removeListener(_onQuestionChanged);
    _tabController.dispose();
    _cancellation.cancelActive();
    _speech.stopListening();
    _speech.stopSpeaking();
    _engine.stopAudio();
    _engine.dispose();
    _question.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final modelReady = _modelInfo != null;
    return Scaffold(
      appBar: AppBar(
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Cancel selection',
                onPressed: _exitSelectionMode,
              )
            : null,
        title: Text(
          _isSelectionMode
              ? '${_selectedRequestIds.length} Selected'
              : 'AskMe',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_isSelectionMode) ...[
            IconButton(
              tooltip: _selectedRequestIds.length == _records.length
                  ? 'Deselect all'
                  : 'Select all',
              onPressed: _selectAllForDeletion,
              icon: Icon(
                _selectedRequestIds.length == _records.length
                    ? Icons.deselect
                    : Icons.select_all,
              ),
            ),
            IconButton(
              tooltip: 'Delete selected',
              onPressed: _selectedRequestIds.isEmpty ? null : _confirmDeleteSelected,
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            ),
          ] else ...[
            TextButton.icon(
              onPressed: _openModelSettingsSheet,
              icon: Icon(
                modelReady ? Icons.check_circle_outline : Icons.memory,
                size: 18,
                color: modelReady ? Colors.green : Colors.deepOrange,
              ),
              label: Text(
                modelReady ? 'Model Ready' : 'Import Model',
                style: TextStyle(
                  fontSize: 12,
                  color: modelReady ? Colors.green.shade700 : Colors.deepOrange,
                ),
              ),
            ),
            if (_records.isNotEmpty) ...[
              IconButton(
                tooltip: 'Select questions',
                onPressed: _busy ? null : () => _enterSelectionMode(),
                icon: const Icon(Icons.checklist_outlined),
              ),
              IconButton(
                tooltip: 'Clear conversation',
                onPressed: _busy ? null : _clearHistory,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ],
            IconButton(
              tooltip: 'Privacy and status',
              onPressed: () => showAboutDialog(
                context: context,
                applicationName: 'AskMe',
                applicationVersion: '0.3.0',
                children: const [
                  Text(
                    '100% on-device offline AI assistant. No cloud fallback or internet permission is used. Scanned/uploaded documents and chat history are AES-256-GCM encrypted locally.',
                  ),
                ],
              ),
              icon: const Icon(Icons.privacy_tip_outlined),
            ),
          ],
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            const Tab(
              icon: Icon(Icons.auto_awesome),
              text: 'Ask',
            ),
            Tab(
              icon: const Icon(Icons.document_scanner_outlined),
              text: _documents.isEmpty
                  ? 'Scan'
                  : 'Scan (${_documents.length})',
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildAskTab(),
            _buildScanTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildAskTab() {
    final orderedRecords = _records.reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_modelBusy)
          const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Text(
                  'Importing & validating GGUF model locally… Please wait.',
                  style: TextStyle(fontSize: 12, color: Colors.blueGrey),
                ),
              ),
            ],
          )
        else if (_modelInfo == null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: const Color(0xFFFFF3E0),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 16,
                  color: Colors.deepOrange,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Offline AI model missing.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: _openModelSettingsSheet,
                  child: const Text('Get URL'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: _importModel,
                  child: const Text('Import'),
                ),
              ],
            ),
          ),
        _buildScopeSelectorBar(),
        Expanded(
          child: orderedRecords.isEmpty
              ? _buildWelcomeView()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  itemCount: orderedRecords.length,
                  itemBuilder: (_, index) => _buildChatTurn(orderedRecords[index]),
                ),
        ),
        if (_showMentionBar) _buildMentionSuggestions(),
        _buildComposer(),
      ],
    );
  }

  Widget _buildScopeSelectorBar() {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          ChoiceChip(
            label: const Text('Auto'),
            avatar: const Icon(Icons.auto_awesome, size: 16),
            selected: _scopeMode == AskScopeMode.auto,
            onSelected: (_) {
              setState(() {
                _scopeMode = AskScopeMode.auto;
                _pinnedDocumentId = null;
              });
            },
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('General AI'),
            avatar: const Icon(Icons.chat_outlined, size: 16),
            selected: _scopeMode == AskScopeMode.generalOnly,
            onSelected: (_) {
              setState(() {
                _scopeMode = AskScopeMode.generalOnly;
                _pinnedDocumentId = null;
              });
            },
          ),
          for (final doc in _documents) ...[
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text(doc.name),
              avatar: const Icon(Icons.description_outlined, size: 16),
              selected: _scopeMode == AskScopeMode.pinned &&
                  _pinnedDocumentId == doc.id,
              onSelected: (_) {
                setState(() {
                  _scopeMode = AskScopeMode.pinned;
                  _pinnedDocumentId = doc.id;
                });
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWelcomeView() {
    final quickPrompts = <String>[
      'Explain how photosynthesis works simply',
      'Write a polite leave application email',
      if (_documents.isNotEmpty)
        '@${_documents.first.name} ka summary batao',
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF063B91), Color(0xFF087CF0)],
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AskMe Private Offline AI',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Chat like Gemini/ChatGPT, or ask about your scanned & uploaded documents using @DocumentName or topic.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Try asking:',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.blueGrey,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final prompt in quickPrompts)
                ActionChip(
                  label: Text(prompt),
                  onPressed: _busy ? null : () => _ask(prompt),
                ),
            ],
          ),
          if (_documents.isEmpty) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _tabController.animateTo(1),
              icon: const Icon(Icons.document_scanner_outlined),
              label: const Text('Go to Scan tab to upload or scan documents'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChatTurn(AskMeHistoryItem item) {
    final isPending = item.status == 'Pending';
    final isCompleted = item.status == 'Completed' && item.answer != null;
    final isSelected = _selectedRequestIds.contains(item.requestId);

    final turnWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(left: 48, top: 6, bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF087CF0),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SelectableText(
                  item.question,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatTime(item.createdAt),
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: item.question));
                        _message('Question copied to clipboard.');
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.copy_outlined, size: 14, color: Colors.white70),
                            SizedBox(width: 4),
                            Text(
                              'Copy',
                              style: TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: isPending && _busy
                          ? null
                          : () => _deleteTurn(item.requestId),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.delete_outline, size: 14, color: Colors.white70),
                            SizedBox(width: 4),
                            Text(
                              'Delete',
                              style: TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(right: 32, bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
              border: Border.all(color: const Color(0xFFE0E7F1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.sources.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final src in item.sources)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          avatar: const Icon(Icons.description_outlined, size: 14),
                          label: Text(
                            src,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
                if (isPending)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _activeRequestId == item.requestId
                            ? _activeStatus
                            : (item.sources.isNotEmpty
                                ? 'Reading ${item.sources.join(", ")}…'
                                : 'Thinking locally…'),
                        style: const TextStyle(
                          color: Colors.blueGrey,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  )
                else if (isCompleted) ...[
                  SelectableText(
                    item.answer!,
                    style: const TextStyle(fontSize: 15, height: 1.4),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(item.answeredAt ?? item.createdAt),
                        style: TextStyle(
                          color: Colors.blueGrey.shade400,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Copy answer',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: item.answer!));
                          _message('Answer copied to clipboard.');
                        },
                        icon: const Icon(Icons.copy_outlined, size: 18),
                      ),
                      IconButton(
                        tooltip: 'Speak offline',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _speak(item.answer!),
                        icon: const Icon(Icons.volume_up_outlined, size: 18),
                      ),
                      IconButton(
                        tooltip: 'Delete question & answer',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _deleteTurn(item.requestId),
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: Colors.blueGrey,
                        ),
                      ),
                    ],
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.status,
                              style: const TextStyle(
                                color: Colors.deepOrange,
                                fontSize: 13,
                              ),
                            ),
                            if (item.answeredAt != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                _formatTime(item.answeredAt!),
                                style: TextStyle(
                                  color: Colors.blueGrey.shade400,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Delete turn',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _deleteTurn(item.requestId),
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: Colors.blueGrey,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (_isSelectionMode) {
      return InkWell(
        onTap: () => _toggleSelectTurn(item.requestId),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: isSelected,
                onChanged: (_) => _toggleSelectTurn(item.requestId),
              ),
              Expanded(child: turnWidget),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onLongPress: () => _enterSelectionMode(item.requestId),
      child: turnWidget,
    );
  }

  Widget _buildMentionSuggestions() {
    final matching = _documents
        .where((d) => d.name.toLowerCase().contains(_mentionFilter))
        .toList();
    if (matching.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      height: 44,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final doc in matching) ...[
            ActionChip(
              avatar: const Icon(Icons.alternate_email, size: 15),
              label: Text(doc.name),
              onPressed: () => _insertDocumentMention(doc),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildComposer() {
    final pinnedName = _scopeMode == AskScopeMode.pinned
        ? _documents
            .where((d) => d.id == _pinnedDocumentId)
            .map((d) => d.name)
            .firstOrNull
        : null;

    final hint = pinnedName != null
        ? 'Ask about "$pinnedName"…'
        : (_scopeMode == AskScopeMode.generalOnly
            ? 'Ask anything offline (General AI)…'
            : 'Ask anything or use @DocName…');

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE0E7F1))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'Hindi voice input offline',
            onPressed: (_busy || _documentBusy || _listening)
                ? null
                : () => _listen('hi-IN'),
            icon: Icon(_listening ? Icons.hearing : Icons.mic),
          ),
          IconButton(
            tooltip: 'English voice input offline',
            onPressed: (_busy || _documentBusy || _listening)
                ? null
                : () => _listen('en-US'),
            icon: const Icon(Icons.mic_none),
          ),
          Expanded(
            child: TextField(
              controller: _question,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _ask(),
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (_busy || _listening)
            IconButton.filled(
              tooltip: 'Stop',
              style: IconButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: _cancel,
              icon: const Icon(Icons.stop),
            )
          else
            IconButton.filled(
              tooltip: 'Ask',
              onPressed: _documentBusy ? null : () => _ask(),
              icon: const Icon(Icons.send),
            ),
        ],
      ),
    );
  }

  Widget _buildScanTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Scan or Upload Named Documents',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Every uploaded file (PDF, DOCX, TXT, Images) or camera scan is processed offline, saved with your custom name, and searchable by name or topic in the Ask tab.',
                    style: TextStyle(fontSize: 12, color: Colors.blueGrey),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              (_busy || _documentBusy) ? null : _scanWithCamera,
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('Scan Camera'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              (_busy || _documentBusy) ? null : _uploadDocument,
                          icon: const Icon(Icons.upload_file_outlined),
                          label: const Text('Upload File'),
                        ),
                      ),
                    ],
                  ),
                  if (_documentBusy) ...[
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _status,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.blueGrey,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _cancel,
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Saved Documents (${_documents.length})',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _documents.isEmpty
              ? const SingleChildScrollView(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'No documents scanned or uploaded yet.\nUse "Scan Camera" or "Upload File" above and give each document a name.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.blueGrey),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                  itemCount: _documents.length,
                  itemBuilder: (_, index) {
                    final doc = _documents[index];
                    return Card(
                      child: ListTile(
                        onTap: () => _showDocumentPreview(doc),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFE7F0FD),
                          child: Icon(
                            _iconForSourceType(doc.sourceType),
                            color: const Color(0xFF087CF0),
                          ),
                        ),
                        title: Text(
                          doc.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          '${doc.originalFileName} • ${doc.extractedText.length} chars',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () => _askAboutDocument(doc),
                              child: const Text('Ask'),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (action) {
                                if (action == 'view') {
                                  _showDocumentPreview(doc);
                                } else if (action == 'rename') {
                                  _renameDocument(doc);
                                } else if (action == 'delete') {
                                  _deleteDocument(doc);
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'view',
                                  child: Text('View text'),
                                ),
                                PopupMenuItem(
                                  value: 'rename',
                                  child: Text('Rename'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  IconData _iconForSourceType(String sourceType) {
    switch (sourceType) {
      case 'scan':
        return Icons.document_scanner_outlined;
      case 'image':
        return Icons.image_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'docx':
        return Icons.article_outlined;
      default:
        return Icons.description_outlined;
    }
  }
}
