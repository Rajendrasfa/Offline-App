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

  test('Auto mode matches single scanned document for company name or website query', () {
    final singleScan = [
      SavedDocument(
        id: 'scan-1',
        name: 'Scan 13-11 10:35',
        originalFileName: 'scan_20261113_1035.jpg',
        sourceType: 'scan',
        extractedText:
            'Sta\nCMMI-3 DEVY IVAT\nThe SFA\nA Special 10th Anniversary Edition\nwww.sfatechgroup.com\nYears 2015-2025',
        createdAt: DateTime(2026, 11, 13),
      ),
    ];

    final resolvedWebsite = DocumentQueryResolver.resolve(
      question: 'company website address',
      savedDocuments: singleScan,
      mode: AskScopeMode.auto,
    );
    expect(resolvedWebsite.documents.map((d) => d.id), ['scan-1']);

    final resolvedCompany = DocumentQueryResolver.resolve(
      question: 'what is company name',
      savedDocuments: singleScan,
      mode: AskScopeMode.auto,
    );
    expect(resolvedCompany.documents.map((d) => d.id), ['scan-1']);
  });

  test('Auto mode correctly discriminates between 10th Anniversary Notebook and 2026 Calendar', () {
    final userScans = [
      SavedDocument(
        id: 'scan-anniv',
        name: 'Scan 13-11 10:35',
        originalFileName: 'scan_20261113_1035.jpg',
        sourceType: 'scan',
        extractedText:
            'Sta\nCMMI-3 DEVY IVAT\nThe SFA\nA Special 10th Anniversary Edition\nwww.sfatechgroup.com\n10 Years\nCelebrating A Decade of Our Successful Journey\n2015-2025',
        createdAt: DateTime(2026, 11, 13, 10, 35),
      ),
      SavedDocument(
        id: 'scan-calendar',
        name: 'Scan 13-11 14:39',
        originalFileName: 'scan_20261113_1439.jpg',
        sourceType: 'scan',
        extractedText:
            'sfa Technologies Pvt. Ltd.\nCMMI-3 DEV | VRT\n2026 CALENDAR\nHolidays:\n26 Jan, Mon - Republic Day\n04 Mar, Wed - Holi\n20 Mar, Fri - Idul fitr\n15 Aug, Sat - Independence Day\n28 Aug, Fri - Raksha Bandhan\n02 Oct, Fri - Gandhi Jayanti\n20 Oct, Tue - Dussehra\n08 Nov, Sun - Diwali\n09 Nov, Mon - Post Diwali\n10 Nov, Tue - Bhai-Duj\n25 Dec, Fri - Christmas\nwww.sfatechgroup.com',
        createdAt: DateTime(2026, 11, 13, 14, 39),
      ),
    ];

    // Query 1: Hindi query asking how many years sfatechgroup has completed
    final resolvedYears = DocumentQueryResolver.resolve(
      question: 'sfatechgroup ko kitane sal ho gaye hai',
      savedDocuments: userScans,
      mode: AskScopeMode.auto,
    );
    expect(resolvedYears.documents.first.id, 'scan-anniv');

    // Query 2: English query with slight typo ('aniversary' with single n)
    final resolvedAniv = DocumentQueryResolver.resolve(
      question: 'what is number of aniversary of SFATECHGROUP',
      savedDocuments: userScans,
      mode: AskScopeMode.auto,
    );
    expect(resolvedAniv.documents.first.id, 'scan-anniv');

    // Query 3: Calendar holiday query
    final resolvedHoliday = DocumentQueryResolver.resolve(
      question: 'Diwali holiday kab hai in 2026 calendar',
      savedDocuments: userScans,
      mode: AskScopeMode.auto,
    );
    expect(resolvedHoliday.documents.first.id, 'scan-calendar');

    // Query 4: Unrelated general question -> general mode
    final resolvedGeneral = DocumentQueryResolver.resolve(
      question: 'Explain how photosynthesis works in green plants',
      savedDocuments: userScans,
      mode: AskScopeMode.auto,
    );
    expect(resolvedGeneral.documents, isEmpty);
    expect(resolvedGeneral.reason, DocumentMatchReason.general);
  });
}
