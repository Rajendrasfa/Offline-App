import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/askme_engine.dart';
import 'services/request_cancellation.dart';
import 'services/secure_history_store.dart';

void main() => runApp(const AskMeApp());

class AskMeApp extends StatelessWidget {
  const AskMeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AskMe', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF087CF0)), useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF5F8FC)),
    home: const AskMeHomePage());
}

class AskMeHomePage extends StatefulWidget {
  const AskMeHomePage({super.key});
  @override
  State<AskMeHomePage> createState() => _AskMeHomePageState();
}

class _AskMeHomePageState extends State<AskMeHomePage> {
  final _question = TextEditingController();
  final _history = SecureHistoryStore();
  final _cancellation = RequestCancellation();
  final AskMeEngine _engine = OfflineEngineNotInstalled();
  final List<AskMeHistoryItem> _records = [];
  AskMeDocument? _document;
  String _status = 'Loading encrypted history…';
  bool _busy = false;
  String? _activeRequestId;

  @override
  void initState() { super.initState(); _loadHistory(); }

  Future<void> _loadHistory() async {
    try {
      final items = await _history.readAll();
      if (!mounted) return;
      setState(() { _records..clear()..addAll(items); _status = 'Offline mode'; });
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = 'History could not be decrypted');
    }
  }

  Future<void> _chooseFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom,
        allowedExtensions: ['pdf', 'docx', 'txt', 'md', 'csv', 'json'],
        allowMultiple: false, withData: true);
      if (!mounted || result == null || result.files.isEmpty) return;
      final file = result.files.single;
      if (file.bytes == null) throw StateError('Selected file bytes are unavailable.');
      setState(() => _document = AskMeDocument(name: file.name, bytes: file.bytes!));
      _message('Selected file is held in memory for this session only.');
    } catch (e) { _message('Could not open file: $e'); }
  }

  Future<void> _ask() async {
    final text = _question.text.trim();
    if (text.isEmpty) return;
    await _cancel(showMessage: false);
    final lease = _cancellation.start();
    final id = '${DateTime.now().microsecondsSinceEpoch}-${lease.id}';
    final item = AskMeHistoryItem(requestId: id, question: text, status: 'Pending', createdAt: DateTime.now());
    setState(() { _records.insert(0, item); _busy = true; _activeRequestId = id; _status = 'Processing locally'; _question.clear(); });
    await _persist(item);
    try {
      final result = await _engine.answer(question: text, document: _document, cancelled: lease.cancelled);
      if (!mounted || !_cancellation.isCurrent(lease.id) || _activeRequestId != id) return;
      final completed = AskMeHistoryItem(requestId: id, question: text, status: 'Completed', createdAt: item.createdAt, answer: result.text);
      await _replace(completed);
    } on OfflineEngineUnavailable {
      if (!mounted || !_cancellation.isCurrent(lease.id)) return;
      final failed = AskMeHistoryItem(requestId: id, question: text, status: 'Setup required — offline model missing', createdAt: item.createdAt);
      await _replace(failed);
      _message('Offline AI model/runtime is not installed yet. No network fallback was attempted.');
    } on PlatformException catch (e) {
      if (!mounted || !_cancellation.isCurrent(lease.id)) return;
      await _replace(AskMeHistoryItem(requestId: id, question: text, status: 'Failed: ${e.code}', createdAt: item.createdAt));
    } catch (_) {
      if (!mounted || !_cancellation.isCurrent(lease.id)) return;
      await _replace(AskMeHistoryItem(requestId: id, question: text, status: 'Failed', createdAt: item.createdAt));
    } finally {
      _cancellation.complete(lease.id);
      if (mounted && _activeRequestId == id) setState(() { _activeRequestId = null; _busy = false; _status = 'Offline mode'; });
    }
  }

  Future<void> _cancel({bool showMessage = true}) async {
    final id = _activeRequestId;
    if (id == null) return;
    _cancellation.cancelActive();
    await _engine.stopAudio();
    final old = _records.firstWhere((x) => x.requestId == id);
    await _replace(AskMeHistoryItem(requestId: id, question: old.question, status: 'Cancelled', createdAt: old.createdAt));
    if (mounted) setState(() { _activeRequestId = null; _busy = false; _status = 'Cancelled'; });
    if (showMessage) _message('Request cancelled.');
  }

  Future<void> _replace(AskMeHistoryItem item) async {
    final index = _records.indexWhere((x) => x.requestId == item.requestId);
    if (index >= 0 && mounted) setState(() => _records[index] = item);
    await _persist(item);
  }

  Future<void> _persist(AskMeHistoryItem item) async {
    try { await _history.upsert(item); } catch (_) { if (mounted) _message('Encrypted history could not be saved.'); }
  }

  void _message(String value) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value))); }

  @override
  void dispose() { _cancellation.cancelActive(); _engine.stopAudio(); _engine.dispose(); _question.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AskMe', style: TextStyle(fontWeight: FontWeight.bold)), centerTitle: true,
      actions: [IconButton(tooltip: 'Privacy and status', onPressed: () => showAboutDialog(context: context, applicationName: 'AskMe', applicationVersion: '0.2.0', children: const [Text('Designed for on-device processing. No cloud fallback is configured. Only files explicitly selected in this session are supplied to the engine.')]), icon: const Icon(Icons.privacy_tip_outlined))]),
    body: SafeArea(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF063B91), Color(0xFF087CF0)]), borderRadius: BorderRadius.circular(20)), child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Your private AI document assistant', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)), SizedBox(height: 7),
        Text('Hindi + English • Selected files only', style: TextStyle(color: Colors.white70)), SizedBox(height: 8),
        Text('Local encrypted history • No cloud fallback', style: TextStyle(color: Colors.white)),
      ])),
      const SizedBox(height: 12),
      OutlinedButton.icon(onPressed: _busy ? null : _chooseFile, icon: const Icon(Icons.attach_file), label: Text(_document == null ? 'Select a document' : 'Change: ${_document!.name}')),
      const SizedBox(height: 8),
      Row(children: [const Expanded(child: Text('Conversation history', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17))), Text(_status, style: const TextStyle(fontSize: 11, color: Colors.blueGrey))]),
      const SizedBox(height: 8),
      Expanded(child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)), child: _records.isEmpty ? const Center(child: Text('Your questions will appear here.')) : ListView.builder(itemCount: _records.length, itemBuilder: (_, i) { final r = _records[i]; return Card(child: ListTile(isThreeLine: r.answer != null, title: Text(r.question), subtitle: Text('${r.status}${r.answer == null ? '' : '\n${r.answer}'}'), leading: const Icon(Icons.chat_bubble_outline))); }))),
      const SizedBox(height: 10),
      TextField(controller: _question, minLines: 1, maxLines: 4, onSubmitted: (_) => _ask(), decoration: const InputDecoration(hintText: 'Type your question… / अपना प्रश्न लिखें', border: OutlineInputBorder(), prefixIcon: Icon(Icons.edit))),
      const SizedBox(height: 8),
      Row(children: [Expanded(child: FilledButton.icon(onPressed: _busy ? null : _ask, icon: const Icon(Icons.send), label: const Text('Ask'))), const SizedBox(width: 8), Expanded(child: OutlinedButton.icon(onPressed: _busy ? _cancel : null, icon: const Icon(Icons.cancel_outlined), label: const Text('Cancel')))]),
      const SizedBox(height: 6),
      const Text('AI model and voice runtime integration is required before answers/voice can work. This app will not send questions or files to the internet.', style: TextStyle(fontSize: 11, color: Colors.blueGrey)),
    ]))),
  );
}
