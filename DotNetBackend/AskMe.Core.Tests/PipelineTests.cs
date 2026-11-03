using System.Collections.Concurrent;
using AskMe.Core;

namespace AskMe.Core.Tests;

public class PipelineTests
{
    private sealed class RecordingHistory : IQuestionHistory
    {
        public ConcurrentDictionary<long, string> Statuses { get; } = new();

        public Task AddPendingAsync(
            QuestionInput input, CancellationToken cancellationToken)
        {
            Statuses[input.RequestId] = "Pending";
            return Task.CompletedTask;
        }

        public Task MarkCompletedAsync(
            long requestId, string answer, CancellationToken cancellationToken)
        {
            Statuses[requestId] = "Completed";
            return Task.CompletedTask;
        }

        public Task MarkCancelledAsync(
            long requestId, CancellationToken cancellationToken)
        {
            Statuses[requestId] = "Cancelled";
            return Task.CompletedTask;
        }

        public Task MarkFailedAsync(
            long requestId, string safeErrorCode, CancellationToken cancellationToken)
        {
            Statuses[requestId] = "Failed";
            return Task.CompletedTask;
        }
    }

    private sealed class UnusedRetriever : IRelevantChunkRetriever
    {
        public Task<IReadOnlyList<ExtractedChunk>> RetrieveAsync(
            SelectedDocument document,
            string question,
            CancellationToken cancellationToken)
        {
            throw new InvalidOperationException(
                "Retriever should not be called when no document is selected.");
        }
    }

    private sealed class DelegateAnswerer(
        Func<string, IReadOnlyList<ExtractedChunk>, CancellationToken, Task<string>> handler)
        : ILocalQuestionAnswerer
    {
        public Task<string> AnswerAsync(
            string question,
            IReadOnlyList<ExtractedChunk> relevantChunks,
            CancellationToken cancellationToken)
        {
            return handler(question, relevantChunks, cancellationToken);
        }
    }

    [Fact]
    public async Task RunAsync_SuccessfulAnswer_MarksHistoryCompleted()
    {
        using var coordinator = new QuestionRequestCoordinator();
        var history = new RecordingHistory();

        var answerer = new DelegateAnswerer(
            (_, _, _) => Task.FromResult("AskMe local answer"));

        var pipeline = new QuestionPipeline(
            coordinator,
            new UnusedRetriever(),
            answerer,
            history);

        var result = await pipeline.RunAsync("What is AskMe?", null);

        Assert.Equal("AskMe local answer", result.Answer);
        Assert.Equal("Completed", history.Statuses[result.RequestId]);
        Assert.False(coordinator.IsCurrent(result.RequestId));
    }

    [Fact]
    public async Task RunAsync_CancelledDuringInference_MarksHistoryCancelled()
    {
        using var coordinator = new QuestionRequestCoordinator();
        using var cts = new CancellationTokenSource();

        var history = new RecordingHistory();
        var inferenceStarted = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var answerer = new DelegateAnswerer(async (_, _, cancellationToken) =>
        {
            inferenceStarted.TrySetResult(true);

            await Task.Delay(
                Timeout.Infinite,
                cancellationToken);

            return "This answer should never be returned.";
        });

        var pipeline = new QuestionPipeline(
            coordinator,
            new UnusedRetriever(),
            answerer,
            history);

        var runTask = pipeline.RunAsync(
            "Test cancellation",
            null,
            cts.Token);

        await inferenceStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));

        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => runTask);

        var cancelledEntry = Assert.Single(history.Statuses);

        Assert.Equal("Cancelled", cancelledEntry.Value);
    }

    [Fact]
    public async Task RunAsync_AnswererFailure_MarksHistoryFailed()
    {
        using var coordinator = new QuestionRequestCoordinator();
        var history = new RecordingHistory();

        var answerer = new DelegateAnswerer(
            (_, _, _) => Task.FromException<string>(
                new InvalidOperationException("Simulated local inference failure")));

        var pipeline = new QuestionPipeline(
            coordinator,
            new UnusedRetriever(),
            answerer,
            history);

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => pipeline.RunAsync("Test failure", null));

        var failedEntry = Assert.Single(history.Statuses);

        Assert.Equal("Failed", failedEntry.Value);
    }
}
