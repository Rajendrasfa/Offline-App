import 'package:askme/services/document_query_resolver.dart';
import 'package:askme/services/secure_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sampleDocs = [
    SavedDocument(
      id: 'doc-1',
      name: 'Bijli Bill',
      originalFileName: 'scan_bill.jpg',
      sourceType: 'scan',
      extractedText:
          'Electricity Bill November 2026. Consumer No 88421. Total amount due Rs 1450 before 25 November. Meter reading 3412 kWh.',
      createdAt: DateTime(2026, 11, 1),
    ),
    SavedDocument(
      id: 'doc-2',
      name: 'Resume',
      originalFileName: 'resume.pdf',
      sourceType: 'pdf',
      extractedText:
          'Rajendra Saket. Software Engineer with 5 years of Flutter and .NET Android offline AI experience.',
      createdAt: DateTime(2026, 11, 2),
    ),
    SavedDocument(
      id: 'doc-3',
      name: 'आधार कार्ड',
      originalFileName: 'aadhaar.png',
      sourceType: 'image',
      extractedText: 'नाम: राजेंद्र साकेत, पता: भोपाल, मध्य प्रदेश।',
      createdAt: DateTime(2026, 11, 3),
    ),
  ];

  test('Auto mode answers general questions without selecting unrelated documents', () {
    final resolved = DocumentQueryResolver.resolve(
      question: 'Explain how photosynthesis works in green plants',
      savedDocuments: sampleDocs,
      mode: AskScopeMode.auto,
    );

    expect(resolved.reason, DocumentMatchReason.general);
    expect(resolved.documents, isEmpty);
  });

  test('Auto mode matches document mentioned with @DocName', () {
    final resolved = DocumentQueryResolver.resolve(
      question: '@Bijli Bill kitna amount hai?',
      savedDocuments: sampleDocs,
      mode: AskScopeMode.auto,
    );

    expect(resolved.reason, DocumentMatchReason.byName);
    expect(resolved.documents.map((d) => d.name), ['Bijli Bill']);
    expect(resolved.cleanedQuestion, 'Bijli Bill kitna amount hai?');
  });

  test('Auto mode matches document mentioned naturally without @', () {
    final resolved = DocumentQueryResolver.resolve(
      question: 'Resume me mera experience kitne saal ka hai?',
      savedDocuments: sampleDocs,
      mode: AskScopeMode.auto,
    );

    expect(resolved.reason, DocumentMatchReason.byName);
    expect(resolved.documents.map((d) => d.name), ['Resume']);
  });

  test('Auto mode matches Hindi named document cleanly', () {
    final resolved = DocumentQueryResolver.resolve(
      question: 'आधार कार्ड में पता क्या है?',
      savedDocuments: sampleDocs,
      mode: AskScopeMode.auto,
    );

    expect(resolved.reason, DocumentMatchReason.byName);
    expect(resolved.documents.map((d) => d.name), ['आधार कार्ड']);
  });

  test('Auto mode finds relevant document even when name is omitted', () {
    final resolved = DocumentQueryResolver.resolve(
      question: 'Meter reading aur consumer number kya hai?',
      savedDocuments: sampleDocs,
      mode: AskScopeMode.auto,
    );

    expect(resolved.reason, DocumentMatchReason.byRelevance);
    expect(resolved.documents.map((d) => d.name), contains('Bijli Bill'));
  });

  test('General AI mode ignores all documents even if name is mentioned', () {
    final resolved = DocumentQueryResolver.resolve(
      question: '@Resume format suggestions',
      savedDocuments: sampleDocs,
      mode: AskScopeMode.generalOnly,
    );

    expect(resolved.reason, DocumentMatchReason.general);
    expect(resolved.documents, isEmpty);
  });

  test('Pinned mode targets only the pinned document', () {
    final resolved = DocumentQueryResolver.resolve(
      question: 'Summarize this',
      savedDocuments: sampleDocs,
      mode: AskScopeMode.pinned,
      pinnedDocumentId: 'doc-2',
    );

    expect(resolved.reason, DocumentMatchReason.pinned);
    expect(resolved.documents.map((d) => d.id), ['doc-2']);
  });
}
