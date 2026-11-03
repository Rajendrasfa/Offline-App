namespace AskMe.Core;

public sealed record QuestionInput(long RequestId, string Text, SelectedDocument? Document);
public sealed record QuestionResult(long RequestId, string Answer, IReadOnlyList<ExtractedChunk> Sources);

public interface IRelevantChunkRetriever
{
    Task<IReadOnlyList<ExtractedChunk>> RetrieveAsync(
        SelectedDocument document, string question, CancellationToken cancellationToken);
}

public interface IQuestionHistory
{
    Task AddPendingAsync(QuestionInput input, CancellationToken cancellationToken);
    Task MarkCompletedAsync(long requestId, string answer, CancellationToken cancellationToken);
    Task MarkCancelledAsync(long requestId, CancellationToken cancellationToken);
    Task MarkFailedAsync(long requestId, string safeErrorCode, CancellationToken cancellationToken);
}

/// <summary>
/// Orchestrates retrieval and local inference. Implementations supplied to this class
/// must be on-device; this core deliberately contains no HTTP/cloud client.
/// </summary>
public sealed class QuestionPipeline(
    QuestionRequestCoordinator coordinator,
    IRelevantChunkRetriever retriever,
    ILocalQuestionAnswerer answerer,
    IQuestionHistory history)
{
    public async Task<QuestionResult> RunAsync(
        string question,
        SelectedDocument? document,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(question))
            throw new ArgumentException("Question cannot be empty.", nameof(question));

        var lease = coordinator.Start();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            lease.CancellationToken, cancellationToken);
        var input = new QuestionInput(lease.RequestId, question.Trim(), document);
        try
        {
            await history.AddPendingAsync(input, linked.Token).ConfigureAwait(false);
            IReadOnlyList<ExtractedChunk> chunks = Array.Empty<ExtractedChunk>();
            if (document is not null)
                chunks = await retriever.RetrieveAsync(document, input.Text, linked.Token)
                    .ConfigureAwait(false);

            linked.Token.ThrowIfCancellationRequested();
            var answer = await answerer.AnswerAsync(input.Text, chunks, linked.Token)
                .ConfigureAwait(false);
            linked.Token.ThrowIfCancellationRequested();

            if (!coordinator.IsCurrent(lease.RequestId))
                throw new OperationCanceledException(linked.Token);

            await history.MarkCompletedAsync(lease.RequestId, answer, linked.Token)
                .ConfigureAwait(false);
            return new QuestionResult(lease.RequestId, answer, chunks);
        }
        catch (OperationCanceledException)
        {
            // Cancellation status is intentionally retained in history.
            await history.MarkCancelledAsync(lease.RequestId, CancellationToken.None)
                .ConfigureAwait(false);
            throw;
        }
        catch
        {
            await history.MarkFailedAsync(lease.RequestId, "QUESTION_PROCESSING_FAILED", CancellationToken.None)
                .ConfigureAwait(false);
            throw;
        }
        finally
        {
            coordinator.Complete(lease.RequestId);
        }
    }
}
