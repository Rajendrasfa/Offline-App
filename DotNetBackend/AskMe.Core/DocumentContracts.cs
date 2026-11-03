namespace AskMe.Core;

/// <summary>Metadata/reference only. The original document is never copied into this model.</summary>
public sealed record SelectedDocument(
    string DocumentId,
    string DisplayName,
    string ContentType,
    long Length,
    string SourceReference);

public sealed record ExtractedChunk(
    string DocumentId,
    int ChunkNumber,
    string Text,
    string? PageOrTimestamp);

public interface IDocumentExtractor
{
    IAsyncEnumerable<ExtractedChunk> ExtractAsync(
        SelectedDocument document, Stream source,
        CancellationToken cancellationToken = default);
}

public interface ILocalQuestionAnswerer
{
    Task<string> AnswerAsync(
        string question, IReadOnlyList<ExtractedChunk> relevantChunks,
        CancellationToken cancellationToken = default);
}
