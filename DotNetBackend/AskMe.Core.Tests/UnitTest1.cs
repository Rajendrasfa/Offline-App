using System.Text;
using AskMe.Core;

namespace AskMe.Core.Tests;

public class UnitTest1
{
    private static SelectedDocument CreateDocument(
        string name,
        string id = "DOC-001")
    {
        return new SelectedDocument(
            id,
            name,
            "text/plain",
            0,
            "user-selected-stream");
    }

    private static async Task<List<ExtractedChunk>> ReadAllAsync(
        IDocumentExtractor extractor,
        SelectedDocument document,
        Stream stream,
        CancellationToken cancellationToken = default)
    {
        var result = new List<ExtractedChunk>();

        await foreach (var chunk in extractor.ExtractAsync(
            document, stream, cancellationToken))
        {
            result.Add(chunk);
        }

        return result;
    }

    [Fact]
    public async Task ExtractAsync_TxtFile_ReturnsDocumentText()
    {
        var extractor = new LocalDocumentExtractor();
        var document = CreateDocument("sample.txt");
        var content = "AskMe offline document testing.";

        using var stream = new MemoryStream(Encoding.UTF8.GetBytes(content));

        var chunks = await ReadAllAsync(extractor, document, stream);

        Assert.Single(chunks);
        Assert.Equal(content, chunks[0].Text);
        Assert.Equal("DOC-001", chunks[0].DocumentId);
        Assert.Equal(1, chunks[0].ChunkNumber);
    }

    [Fact]
    public async Task ExtractAsync_LargeText_CreatesOverlappingChunks()
    {
        var extractor = new LocalDocumentExtractor();
        var document = CreateDocument("large.txt");
        var content = new string('A', 1500);

        using var stream = new MemoryStream(Encoding.UTF8.GetBytes(content));

        var chunks = await ReadAllAsync(extractor, document, stream);

        Assert.Equal(2, chunks.Count);
        Assert.Equal(1200, chunks[0].Text.Length);
        Assert.Equal(460, chunks[1].Text.Length);

        Assert.Equal(
            chunks[0].Text.Substring(1040),
            chunks[1].Text.Substring(0, 160));
    }

    [Fact]
    public async Task ExtractAsync_UnsupportedFile_ThrowsException()
    {
        var extractor = new LocalDocumentExtractor();
        var document = CreateDocument("sample.exe");

        using var stream = new MemoryStream();

        await Assert.ThrowsAsync<NotSupportedException>(
            () => ReadAllAsync(extractor, document, stream));
    }

    [Fact]
    public async Task ExtractAsync_PreCancelledToken_ThrowsCancellation()
    {
        var extractor = new LocalDocumentExtractor();
        var document = CreateDocument("sample.txt");

        using var stream = new MemoryStream(
            Encoding.UTF8.GetBytes("Test document"));

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => ReadAllAsync(extractor, document, stream, cts.Token));
    }

    [Fact]
    public async Task RetrieveAsync_HindiQuestion_FindsMatchingChunk()
    {
        var extractor = new LocalDocumentExtractor();
        var document = CreateDocument("hindi.txt");

        const string content =
            "विद्यालय में विद्यार्थियों की उपस्थिति अनिवार्य है।";

        var retriever = new KeywordChunkRetriever(
            extractor,
            (_, _) => Task.FromResult<Stream>(
                new MemoryStream(Encoding.UTF8.GetBytes(content))));

        var result = await retriever.RetrieveAsync(
            document, "विद्यालय", CancellationToken.None);

        Assert.NotEmpty(result);
        Assert.Contains(result, x => x.Text.Contains("विद्यालय"));
    }

    [Fact]
    public async Task RetrieveAsync_EnglishQuestion_FindsMatchingChunk()
    {
        var extractor = new LocalDocumentExtractor();
        var document = CreateDocument("english.txt");

        const string content =
            "Student attendance is mandatory in every school.";

        var retriever = new KeywordChunkRetriever(
            extractor,
            (_, _) => Task.FromResult<Stream>(
                new MemoryStream(Encoding.UTF8.GetBytes(content))));

        var result = await retriever.RetrieveAsync(
            document, "student attendance", CancellationToken.None);

        Assert.NotEmpty(result);
        Assert.Contains(result, x => x.Text.Contains("Student"));
    }

    [Fact]
    public void Coordinator_StartNewRequest_CancelsPreviousRequest()
    {
        using var coordinator = new QuestionRequestCoordinator();

        var first = coordinator.Start();
        var second = coordinator.Start();

        Assert.True(first.CancellationToken.IsCancellationRequested);
        Assert.False(coordinator.IsCurrent(first.RequestId));
        Assert.True(coordinator.IsCurrent(second.RequestId));

        Assert.False(coordinator.Complete(first.RequestId));
        Assert.True(coordinator.Complete(second.RequestId));
    }

    [Fact]
    public void Coordinator_CancelRequest_CancelsOnlyActiveRequest()
    {
        using var coordinator = new QuestionRequestCoordinator();

        var lease = coordinator.Start();

        Assert.True(coordinator.Cancel(lease.RequestId));
        Assert.True(lease.CancellationToken.IsCancellationRequested);
        Assert.False(coordinator.IsCurrent(lease.RequestId));
    }
}
