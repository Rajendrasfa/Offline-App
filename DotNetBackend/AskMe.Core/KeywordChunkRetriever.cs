namespace AskMe.Core;

/// <summary>Simple deterministic local retrieval baseline. No network or external service is used.</summary>
public sealed class KeywordChunkRetriever(IDocumentExtractor extractor, Func<SelectedDocument, CancellationToken, Task<Stream>> openSelectedStream)
    : IRelevantChunkRetriever
{
    public async Task<IReadOnlyList<ExtractedChunk>> RetrieveAsync(
        SelectedDocument document, string question, CancellationToken cancellationToken)
    {
        await using var stream = await openSelectedStream(document, cancellationToken).ConfigureAwait(false);
        var all = new List<ExtractedChunk>();
        await foreach (var chunk in extractor.ExtractAsync(document, stream, cancellationToken)
            .WithCancellation(cancellationToken).ConfigureAwait(false)) all.Add(chunk);

        char[] trimChars = ['.', ',', '?', '!', ':', ';', '"', '\'', '@', '#', '(', ')', '[', ']', '{', '}', '।', '-', '/'];
        var terms = question.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(x => x.Trim(trimChars).ToLowerInvariant()).Where(x => x.Length >= 2).Distinct().ToArray();
        return all.Select(c => new { Chunk = c, Score = terms.Count(t => c.Text.Contains(t, StringComparison.OrdinalIgnoreCase)) })
            .Where(x => x.Score > 0).OrderByDescending(x => x.Score).ThenBy(x => x.Chunk.ChunkNumber)
            .Take(8).Select(x => x.Chunk).ToArray();
    }
}
