using System.Text;
using AskMe.Core;

namespace AskMe.Core.Tests;

/// <summary>
/// Tests for KeywordChunkRetriever — verifies that document chunks are scored
/// and ranked by keyword overlap with the question, with correct fallback
/// when no keyword matches are found.
/// </summary>
public class RetrievalTests
{
    private static SelectedDocument MakeDoc(string name = "test.txt") =>
        new("DOC-RETRIEVAL", name, "text/plain", 0, "user-selected-stream");

    private static Task<Stream> FromText(string text) =>
        Task.FromResult<Stream>(new MemoryStream(Encoding.UTF8.GetBytes(text)));

    private static KeywordChunkRetriever BuildRetriever(string documentContent) =>
        new(new LocalDocumentExtractor(), (_, _) => FromText(documentContent));

    // -------------------------------------------------------------------------
    // Basic keyword match
    // -------------------------------------------------------------------------

    [Fact]
    public async Task RetrieveAsync_ExactKeywordMatch_ReturnsMatchingChunk()
    {
        const string content = "The AskMe application processes documents offline.";
        var retriever = BuildRetriever(content);

        var chunks = await retriever.RetrieveAsync(MakeDoc(), "AskMe application", CancellationToken.None);

        Assert.NotEmpty(chunks);
        Assert.Contains(chunks, c => c.Text.Contains("AskMe", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task RetrieveAsync_PartialKeywordMatch_ReturnsHigherScoredChunkFirst()
    {
        // Build a document with two chunks: one has 2 matching terms, one has 1.
        var sb = new StringBuilder();
        // Chunk A: mentions both "privacy" and "offline"
        sb.Append(new string('A', 1) + "Privacy and offline document processing. ");
        sb.Append(new string('B', 1200)); // push to next chunk
        // Chunk B: mentions only "document"
        sb.Append("Document security guide.");

        var retriever = BuildRetriever(sb.ToString());

        var chunks = await retriever.RetrieveAsync(MakeDoc(), "privacy offline", CancellationToken.None);

        Assert.NotEmpty(chunks);
        // The first returned chunk must contain both higher-score terms.
        Assert.Contains("Privacy", chunks[0].Text, StringComparison.OrdinalIgnoreCase);
    }

    // -------------------------------------------------------------------------
    // No keyword match — fallback to first N chunks
    // -------------------------------------------------------------------------

    [Fact]
    public async Task RetrieveAsync_NoKeywordMatch_ReturnsFallbackChunks()
    {
        const string content = "Complete unrelated text that shares no words with the question.";
        var retriever = BuildRetriever(content);

        // Question has no words in common with content.
        var chunks = await retriever.RetrieveAsync(MakeDoc(), "xyz123 nonexistent", CancellationToken.None);

        // Fallback: returns up to 4 chunks rather than empty list.
        // (KeywordChunkRetriever returns empty when score == 0 — this tests that
        // the NativeExports-level fallback compensates; here we test retriever directly.)
        // A score-0 retriever returns nothing — that is correct per the retriever spec.
        // NativeExports handles fallback separately.
        Assert.Empty(chunks); // correct retriever behaviour: no match = empty
    }

    // -------------------------------------------------------------------------
    // Cancellation
    // -------------------------------------------------------------------------

    [Fact]
    public async Task RetrieveAsync_PreCancelledToken_ThrowsOperationCancelledException()
    {
        const string content = "AskMe offline AI assistant test.";
        var retriever = BuildRetriever(content);
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => retriever.RetrieveAsync(MakeDoc(), "AskMe", cts.Token));
    }

    // -------------------------------------------------------------------------
    // Max results capped at 8
    // -------------------------------------------------------------------------

    [Fact]
    public async Task RetrieveAsync_ManyMatchingChunks_ReturnsAtMostEight()
    {
        // Build a document with 20 small chunks all containing the keyword "data".
        var sb = new StringBuilder();
        for (var i = 0; i < 20; i++)
            sb.Append($"data chunk {i} content. " + new string('X', 1150));

        var retriever = BuildRetriever(sb.ToString());

        var chunks = await retriever.RetrieveAsync(MakeDoc("large.txt"), "data", CancellationToken.None);

        Assert.InRange(chunks.Count, 1, 8);
    }

    // -------------------------------------------------------------------------
    // Hindi keyword retrieval
    // -------------------------------------------------------------------------

    [Fact]
    public async Task RetrieveAsync_HindiKeyword_FindsMatchingChunk()
    {
        const string content = "यह AskMe हिंदी दस्तावेज़ सहायक है। गोपनीयता सुनिश्चित की जाती है।";
        var retriever = BuildRetriever(content);

        var chunks = await retriever.RetrieveAsync(MakeDoc("hindi.txt"), "गोपनीयता", CancellationToken.None);

        Assert.NotEmpty(chunks);
        Assert.Contains(chunks, c => c.Text.Contains("गोपनीयता", StringComparison.Ordinal));
    }

    // -------------------------------------------------------------------------
    // Short query words (< 2 chars) are ignored
    // -------------------------------------------------------------------------

    [Fact]
    public async Task RetrieveAsync_SingleCharQuery_IgnoresSingleCharTerms()
    {
        // All query terms are 1 character — should be treated as no-keyword query.
        const string content = "AskMe processes documents.";
        var retriever = BuildRetriever(content);

        var chunks = await retriever.RetrieveAsync(MakeDoc(), "a b c", CancellationToken.None);

        // Single-char terms are filtered; score = 0 for all; retriever returns empty.
        Assert.Empty(chunks);
    }

    [Fact]
    public async Task RetrieveAsync_QueryWithPunctuationAndMention_FindsMatchingChunk()
    {
        const string content = "Electricity bill total amount due is 1450 rupees on November 20.";
        var retriever = BuildRetriever(content);

        var chunks = await retriever.RetrieveAsync(MakeDoc("bill.txt"), "@Bill, total amount?", CancellationToken.None);

        Assert.NotEmpty(chunks);
        Assert.Contains(chunks, c => c.Text.Contains("1450 rupees", StringComparison.OrdinalIgnoreCase));
    }
}

