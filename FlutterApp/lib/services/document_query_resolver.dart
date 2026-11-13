import 'secure_document_store.dart';

enum AskScopeMode {
  /// Default Gemini/ChatGPT-style mode + smart local vault lookup:
  /// matches document names/@mentions first, then topic relevance across all
  /// saved documents, and falls back to general AI chat when unrelated.
  auto,

  /// Pure Gemini/ChatGPT-style general chat ignoring saved documents.
  generalOnly,

  /// Targets a single specifically selected document by ID/name.
  pinned,
}

enum DocumentMatchReason {
  general,
  pinned,
  byName,
  byRelevance,
}

class ResolvedDocuments {
  const ResolvedDocuments({
    required this.documents,
    required this.reason,
    required this.cleanedQuestion,
  });

  final List<SavedDocument> documents;
  final DocumentMatchReason reason;
  final String cleanedQuestion;
}

/// Resolves which saved document(s), if any, should supply context for a
/// question asked in the Ask tab.
class DocumentQueryResolver {
  static final RegExp _tokenSplit = RegExp(
    r'''[\s,.;:!?'"()\[\]{}/\\@#$%^&*+=<>|~`\-।]+''',
  );

  static const Set<String> _stopwords = {
    // English common words
    'the', 'is', 'am', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'shall',
    'should', 'can', 'could', 'may', 'might', 'must',
    'what', 'which', 'who', 'whom', 'whose', 'when', 'where', 'why', 'how',
    'this', 'that', 'these', 'those', 'there', 'here',
    'and', 'or', 'but', 'if', 'then', 'else', 'for', 'of', 'in', 'on', 'at',
    'to', 'from', 'by', 'with', 'about', 'into', 'over', 'after', 'before',
    'me', 'my', 'mine', 'you', 'your', 'we', 'our', 'they', 'their', 'it', 'its',
    'please', 'tell', 'explain', 'describe', 'summarize', 'summary', 'read',
    'give', 'show', 'find', 'check', 'write', 'make', 'create',
    // Hindi / Hinglish conversational words (excluding English words already listed above)
    'kya', 'hai', 'hain', 'ho', 'hun', 'tha', 'thi',
    'ka', 'ki', 'ke', 'ko', 'se', 'mein', 'pe', 'par', 'tak',
    'aur', 'ya', 'bhi', 'hi', 'toh', 'nahi', 'na',
    'batao', 'bataiye', 'bata', 'btaiye', 'samjhao', 'samjhaiye', 'likho',
    'padho', 'dikhao', 'nikalo', 'dena', 'karo', 'kare', 'karen',
    'mujhe', 'mera', 'meri', 'mere', 'apna', 'apni', 'apne', 'iske', 'isme',
    'kuch', 'koi', 'sab', 'ye', 'yeh', 'wo', 'woh', 'kaise', 'kab', 'kahan',
    'kyu', 'kyon', 'kitna', 'kitni', 'kitne', 'kaun', 'kiska', 'kiski',
    'document', 'doc', 'file', 'page', 'scan', 'bare', 'baare',
  };

  static const Set<String> _documentInquiryKeywords = {
    'company', 'website', 'site', 'url', 'address', 'pata', 'name', 'naam',
    'date', 'tarikh', 'dinank', 'year', 'saal', 'time', 'samay', 'amount',
    'total', 'bill', 'consumer', 'meter', 'reading', 'payment', 'paid', 'due',
    'number', 'no', 'id', 'phone', 'mobile', 'email', 'contact', 'sampark',
    'details', 'detail', 'summary', 'content', 'text', 'likha', 'kiska',
    'kiski', 'kiske', 'kisne', 'invoice', 'receipt', 'certificate',
    'document', 'doc', 'file', 'page', 'scan', 'report',
    'organisation', 'organization', 'office', 'headquarters', 'branch',
  };

  static ResolvedDocuments resolve({
    required String question,
    required List<SavedDocument> savedDocuments,
    required AskScopeMode mode,
    String? pinnedDocumentId,
  }) {
    final trimmed = question.trim();
    if (trimmed.isEmpty ||
        mode == AskScopeMode.generalOnly ||
        savedDocuments.isEmpty) {
      return ResolvedDocuments(
        documents: const [],
        reason: DocumentMatchReason.general,
        cleanedQuestion: trimmed,
      );
    }

    if (mode == AskScopeMode.pinned && pinnedDocumentId != null) {
      for (final doc in savedDocuments) {
        if (doc.id == pinnedDocumentId) {
          return ResolvedDocuments(
            documents: [doc],
            reason: DocumentMatchReason.pinned,
            cleanedQuestion: trimmed,
          );
        }
      }
    }

    // Step A: Detect explicit @DocName or natural document name mentions.
    final byName = _matchByName(trimmed, savedDocuments);
    if (byName != null) {
      return byName;
    }

    // Step B: Score relevance across all saved documents for topic queries.
    final byRelevance = _matchByRelevance(trimmed, savedDocuments);
    if (byRelevance.isNotEmpty) {
      return ResolvedDocuments(
        documents: byRelevance,
        reason: DocumentMatchReason.byRelevance,
        cleanedQuestion: trimmed,
      );
    }

    // Step C: If there is only 1 document in the vault and the user asks a document-related
    // question (e.g. "what is company name", "website address"), target that document.
    final terms = _extractTerms(trimmed);
    final hasInquiryIntent = terms.any(_documentInquiryKeywords.contains);
    if (savedDocuments.length == 1 && hasInquiryIntent) {
      return ResolvedDocuments(
        documents: [savedDocuments.first],
        reason: DocumentMatchReason.byRelevance,
        cleanedQuestion: trimmed,
      );
    }

    // Step D: Unrelated to saved docs -> Gemini/ChatGPT style general response.
    return ResolvedDocuments(
      documents: const [],
      reason: DocumentMatchReason.general,
      cleanedQuestion: trimmed,
    );
  }

  static ResolvedDocuments? _matchByName(
    String question,
    List<SavedDocument> savedDocuments,
  ) {
    final sorted = [...savedDocuments]
      ..sort((a, b) => b.name.trim().length.compareTo(a.name.trim().length));

    final matched = <SavedDocument>[];
    var cleaned = question;

    for (final doc in sorted) {
      final rawName = doc.name.trim();
      if (rawName.length < 2) {
        continue;
      }
      final underscoreVariant = rawName.replaceAll(RegExp(r'\s+'), '_');
      final candidates = {rawName, underscoreVariant};

      var hit = false;
      for (final variant in candidates) {
        final escaped = RegExp.escape(variant);
        final atPattern = RegExp(
          '(^|\\s)@$escaped(?=\$|\\s|[,.;:!?)])',
          caseSensitive: false,
        );
        if (atPattern.hasMatch(cleaned)) {
          cleaned = cleaned.replaceAllMapped(
            atPattern,
            (m) => '${m.group(1) ?? ''}$rawName',
          );
          hit = true;
          break;
        }

        final boundaryPattern = RegExp(
          '''(^|[\\s,.;:!?'"()\\[\\]/\\-])($escaped)(?=\$|[\\s,.;:!?'"()\\[\\]/\\-])''',
          caseSensitive: false,
        );
        if (boundaryPattern.hasMatch(cleaned)) {
          hit = true;
          break;
        }
      }

      if (hit && !matched.any((d) => d.id == doc.id)) {
        matched.add(doc);
      }
    }

    if (matched.isEmpty) {
      return null;
    }
    return ResolvedDocuments(
      documents: matched.take(3).toList(),
      reason: DocumentMatchReason.byName,
      cleanedQuestion: cleaned.trim(),
    );
  }

  static List<SavedDocument> _matchByRelevance(
    String question,
    List<SavedDocument> savedDocuments,
  ) {
    final terms = _extractTerms(question);
    if (terms.isEmpty) {
      return const [];
    }

    final hasWebsiteIntent = terms.any((t) => t == 'website' || t == 'site' || t == 'url' || t == 'link');
    final hasCompanyIntent = terms.any((t) => t == 'company' || t == 'org' || t == 'organization' || t == 'firm' || t == 'business');

    final minHitsRequired = (terms.length / 2).ceil();
    final scored = <({SavedDocument doc, int score})>[];

    for (final doc in savedDocuments) {
      final haystack =
          '${doc.name.toLowerCase()}\n${doc.extractedText.toLowerCase()}';
      var hits = 0;
      for (final term in terms) {
        if (haystack.contains(term)) {
          hits++;
        }
      }

      if (hasWebsiteIntent &&
          (haystack.contains('www.') ||
              haystack.contains('.com') ||
              haystack.contains('http') ||
              haystack.contains('.in') ||
              haystack.contains('.org'))) {
        hits += 2;
      }
      if (hasCompanyIntent &&
          (haystack.contains('pvt') ||
              haystack.contains('ltd') ||
              haystack.contains('inc') ||
              haystack.contains('corp') ||
              haystack.contains('group') ||
              haystack.contains('technologies') ||
              haystack.contains('sfa') ||
              haystack.contains('the sfa'))) {
        hits += 2;
      }

      if (hits >= minHitsRequired) {
        scored.add((doc: doc, score: hits));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(2).map((e) => e.doc).toList();
  }

  static List<String> _extractTerms(String question) {
    final tokens = question
        .split(_tokenSplit)
        .map((t) => t.trim().toLowerCase())
        .where((t) => t.length >= 2 && !_stopwords.contains(t))
        .toSet()
        .toList();
    return tokens;
  }
}
