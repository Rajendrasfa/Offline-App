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

  static final RegExp _yearRangePattern = RegExp(r'\b20\d\d\s*-\s*20\d\d\b');

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
    'kyu', 'kyon', 'kitna', 'kitni', 'kitne', 'kitane', 'kaun', 'kiska', 'kiski',
    'document', 'doc', 'file', 'page', 'scan', 'bare', 'baare',
    'gaye', 'gaya', 'gayi', 'hua', 'hue', 'hui', 'huye',
    'raha', 'rahe', 'rahi', 'hota', 'hote', 'hoti',
    'wala', 'wali', 'wale', 'karna', 'karta', 'karti', 'karte',
  };

  static const Set<String> _documentInquiryKeywords = {
    'company', 'website', 'site', 'url', 'address', 'pata', 'name', 'naam',
    'date', 'tarikh', 'dinank', 'year', 'years', 'saal', 'sal', 'varsh',
    'time', 'samay', 'amount', 'total', 'bill', 'consumer', 'meter',
    'reading', 'payment', 'paid', 'due', 'number', 'no', 'id', 'phone',
    'mobile', 'email', 'contact', 'sampark', 'details', 'detail', 'summary',
    'content', 'text', 'likha', 'kiska', 'kiski', 'kiske', 'kisne',
    'invoice', 'receipt', 'certificate', 'document', 'doc', 'file', 'page',
    'scan', 'report', 'organisation', 'organization', 'office',
    'headquarters', 'branch', 'anniversary', 'aniversary', 'anniv', 'decade',
    'holiday', 'holidays', 'chhutti', 'chhuttiya', 'tyohar', 'calendar',
    'month', 'mahina', 'sfa', 'sfatechgroup', 'techgroup', 'celebrating',
    'journey', 'edition',
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

    // Step C: Fallback for document inquiry intent (e.g. "what is company name", "website address", "sfatechgroup ko kitane sal ho gaye")
    final terms = _extractTerms(trimmed);
    final hasInquiryIntent = terms.any(_documentInquiryKeywords.contains);
    if (savedDocuments.isNotEmpty && hasInquiryIntent) {
      final scoredFallback = <({SavedDocument doc, int score})>[];
      for (final doc in savedDocuments) {
        final haystack =
            '${doc.name.toLowerCase()}\n${doc.extractedText.toLowerCase()}';
        var score = 0;
        for (final term in terms) {
          if (haystack.contains(term)) score += 2;
        }
        if (haystack.contains('www.') || haystack.contains('.com')) score += 1;
        if (haystack.contains('pvt') ||
            haystack.contains('ltd') ||
            haystack.contains('sfa')) score += 1;
        scoredFallback.add((doc: doc, score: score));
      }
      scoredFallback.sort((a, b) => b.score.compareTo(a.score));
      return ResolvedDocuments(
        documents: [scoredFallback.first.doc],
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

    final hasWebsiteIntent = terms.any(
      (t) => t == 'website' || t == 'site' || t == 'url' || t == 'link',
    );
    final hasCompanyIntent = terms.any(
      (t) =>
          t == 'company' ||
          t == 'org' ||
          t == 'organization' ||
          t == 'firm' ||
          t == 'business',
    );
    final hasAnniversaryIntent = terms.any(
      (t) =>
          t.contains('anivers') ||
          t.contains('annivers') ||
          t == 'sal' ||
          t == 'saal' ||
          t == 'year' ||
          t == 'years' ||
          t == 'decade' ||
          t == 'varsh',
    );
    final hasCalendarIntent = terms.any(
      (t) =>
          t.contains('calendar') ||
          t.contains('holiday') ||
          t == 'chhutti' ||
          t == 'chhuttiya' ||
          t == 'tyohar' ||
          t == 'january' ||
          t == 'february' ||
          t == 'march' ||
          t == 'april' ||
          t == 'may' ||
          t == 'june' ||
          t == 'july' ||
          t == 'august' ||
          t == 'september' ||
          t == 'october' ||
          t == 'november' ||
          t == 'december' ||
          t == 'diwali' ||
          t == 'holi' ||
          t == 'dussehra' ||
          t == 'eid',
    );
    final hasEntityIntent = terms.any(
      (t) => t == 'sfa' || t.contains('sfatech') || t.contains('sfatechgroup'),
    );

    final scored = <({SavedDocument doc, int score})>[];

    for (final doc in savedDocuments) {
      final haystack =
          '${doc.name.toLowerCase()}\n${doc.extractedText.toLowerCase()}';
      var hits = 0;
      for (final term in terms) {
        if (haystack.contains(term)) {
          hits += (term.length >= 5) ? 3 : 2;
        } else {
          // Typo / Stem tolerances
          if (term.contains('anivers') && haystack.contains('annivers')) {
            hits += 3;
          }
          if ((term == 'sal' || term == 'saal') &&
              (haystack.contains('year') ||
                  haystack.contains('years') ||
                  haystack.contains('decade') ||
                  _yearRangePattern.hasMatch(haystack))) {
            hits += 3;
          }
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
      if (hasAnniversaryIntent &&
          (haystack.contains('anniversary') ||
              haystack.contains('decade') ||
              haystack.contains('years') ||
              haystack.contains('10th') ||
              haystack.contains('edition'))) {
        hits += 3;
      }
      if (hasCalendarIntent &&
          (haystack.contains('calendar') ||
              haystack.contains('holiday') ||
              haystack.contains('holidays') ||
              haystack.contains('january') ||
              haystack.contains('diwali') ||
              haystack.contains('2026'))) {
        hits += 3;
      }
      if (hasEntityIntent &&
          (haystack.contains('sfa') || haystack.contains('sfatechgroup'))) {
        hits += 3;
      }

      if (hits >= 2) {
        scored.add((doc: doc, score: hits));
      }
    }

    if (scored.isEmpty) {
      return const [];
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
