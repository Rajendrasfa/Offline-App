using DocumentFormat.OpenXml;
using System.Text;
using AskMe.Core;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Wordprocessing;

namespace AskMe.Core.Tests;

public class DocumentExtractionTests
{
    private static SelectedDocument CreateDocument(string name)
    {
        return new SelectedDocument(
            "DOC-TEST",
            name,
            "application/octet-stream",
            0,
            "user-selected-stream");
    }

    private static async Task<List<ExtractedChunk>> ExtractAsync(
        string fileName,
        MemoryStream stream)
    {
        var extractor = new LocalDocumentExtractor();
        var result = new List<ExtractedChunk>();

        stream.Position = 0;

        await foreach (var chunk in extractor.ExtractAsync(
            CreateDocument(fileName), stream))
        {
            result.Add(chunk);
        }

        return result;
    }

    private static MemoryStream CreatePdf(params string[] pageTexts)
    {
        var stream = new MemoryStream();
        var pageCount = pageTexts.Length;
        var fontId = 3 + (pageCount * 2);
        var objectCount = fontId;

        var offsets = new long[objectCount + 1];

        void Write(string value)
        {
            var bytes = Encoding.ASCII.GetBytes(value);
            stream.Write(bytes);
        }

        void WriteObject(int number, string content)
        {
            offsets[number] = stream.Position;
            Write($"{number} 0 obj\n{content}\nendobj\n");
        }

        Write("%PDF-1.4\n");

        WriteObject(1, "<< /Type /Catalog /Pages 2 0 R >>");

        var kids = string.Join(
            " ",
            Enumerable.Range(0, pageCount)
                .Select(i => $"{3 + i} 0 R"));

        WriteObject(
            2,
            $"<< /Type /Pages /Kids [{kids}] /Count {pageCount} >>");

        for (var i = 0; i < pageCount; i++)
        {
            var pageId = 3 + i;
            var contentId = 3 + pageCount + i;

            WriteObject(
                pageId,
                $"<< /Type /Page /Parent 2 0 R " +
                "/MediaBox [0 0 612 792] " +
                $"/Resources << /Font << /F1 {fontId} 0 R >> >> " +
                $"/Contents {contentId} 0 R >>");

            var escapedText = pageTexts[i]
                .Replace("\\", "\\\\")
                .Replace("(", "\\(")
                .Replace(")", "\\)");

            var content =
                $"BT /F1 12 Tf 72 720 Td ({escapedText}) Tj ET";

            var contentBytes = Encoding.ASCII.GetBytes(content);

            offsets[contentId] = stream.Position;

            Write($"{contentId} 0 obj\n");
            Write($"<< /Length {contentBytes.Length} >>\nstream\n");
            stream.Write(contentBytes);
            Write("\nendstream\nendobj\n");
        }

        WriteObject(
            fontId,
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");

        var xrefPosition = stream.Position;

        Write($"xref\n0 {objectCount + 1}\n");
        Write("0000000000 65535 f \n");

        for (var i = 1; i <= objectCount; i++)
        {
            Write($"{offsets[i]:0000000000} 00000 n \n");
        }

        Write(
            $"trailer\n<< /Size {objectCount + 1} /Root 1 0 R >>\n");

        Write($"startxref\n{xrefPosition}\n%%EOF");

        stream.Position = 0;
        return stream;
    }

    private static MemoryStream CreateDocx()
    {
        var stream = new MemoryStream();

        using (var document = WordprocessingDocument.Create(
            stream,
            WordprocessingDocumentType.Document,
            true))
        {
            var mainPart = document.AddMainDocumentPart();

            mainPart.Document = new Document(
                new Body(
                    new Paragraph(
                        new Run(
                            new Text("AskMe DOCX extraction test")))));

            mainPart.Document.Save();
        }

        stream.Position = 0;
        return stream;
    }

    [Fact]
    public async Task ExtractAsync_RealPdf_ExtractsText()
    {
        using var pdf = CreatePdf("AskMe PDF extraction test");

        var chunks = await ExtractAsync("sample.pdf", pdf);

        Assert.NotEmpty(chunks);
        Assert.Contains(
            chunks,
            chunk => chunk.Text.Contains(
                "AskMe PDF extraction test",
                StringComparison.Ordinal));
    }

    [Fact]
    public async Task ExtractAsync_RealPdf_PreservesPageNumber()
    {
        using var pdf = CreatePdf("AskMe PDF extraction test");

        var chunks = await ExtractAsync("sample.pdf", pdf);

        Assert.NotEmpty(chunks);

        // Expected requirement: PDF source page reference must be preserved.
        Assert.Equal("1", chunks[0].PageOrTimestamp);
    }

    [Fact]
    public async Task ExtractAsync_MultiPagePdf_PreservesEachPageNumber()
    {
        using var pdf = CreatePdf(
            "First page content",
            "Second page content",
            "Third page content");

        var chunks = await ExtractAsync("multipage.pdf", pdf);

        Assert.Equal(3, chunks.Count);

        Assert.Equal("1", chunks[0].PageOrTimestamp);
        Assert.Equal("2", chunks[1].PageOrTimestamp);
        Assert.Equal("3", chunks[2].PageOrTimestamp);

        Assert.Equal(new[] { 1, 2, 3 },
            chunks.Select(x => x.ChunkNumber).ToArray());
    }

    [Fact]
    public async Task ExtractAsync_LongPdfPage_AllChunksKeepSamePageNumber()
    {
        var longText = string.Join(" ", Enumerable.Repeat("PageOne", 250));

        using var pdf = CreatePdf(longText);

        var chunks = await ExtractAsync("long-page.pdf", pdf);

        Assert.True(chunks.Count > 1);

        Assert.All(
            chunks,
            chunk => Assert.Equal("1", chunk.PageOrTimestamp));

        Assert.Equal(
            Enumerable.Range(1, chunks.Count),
            chunks.Select(chunk => chunk.ChunkNumber));
    }

    [Fact]
    public async Task ExtractAsync_EmptyPdfPage_DoesNotCreateChunk()
    {
        using var pdf = CreatePdf(
            "",
            "Second page has content");

        var chunks = await ExtractAsync("empty-page.pdf", pdf);

        Assert.Single(chunks);
        Assert.Equal("2", chunks[0].PageOrTimestamp);
        Assert.Contains("Second page", chunks[0].Text);
    }

    [Fact]
    public async Task ExtractAsync_MultiPagePdf_ChunkNumbersRemainContinuous()
    {
        using var pdf = CreatePdf(
            string.Join(" ", Enumerable.Repeat("FirstPage", 200)),
            "Second page content");

        var chunks = await ExtractAsync("continuous.pdf", pdf);

        Assert.True(chunks.Count > 2);

        Assert.Equal(
            Enumerable.Range(1, chunks.Count),
            chunks.Select(chunk => chunk.ChunkNumber));

        Assert.Contains(chunks, chunk => chunk.PageOrTimestamp == "1");
        Assert.Contains(chunks, chunk => chunk.PageOrTimestamp == "2");
    }

    [Fact]
    public async Task ExtractAsync_RealDocx_ExtractsParagraphText()
    {
        using var docx = CreateDocx();

        var chunks = await ExtractAsync("sample.docx", docx);

        Assert.NotEmpty(chunks);
        Assert.Contains(
            chunks,
            chunk => chunk.Text.Contains(
                "AskMe DOCX extraction test",
                StringComparison.Ordinal));
    }


    private static MemoryStream CreateDocxWithText(string text)
    {
        var stream = new MemoryStream();

        using (var document = WordprocessingDocument.Create(
            stream,
            WordprocessingDocumentType.Document,
            true))
        {
            var mainPart = document.AddMainDocumentPart();

            mainPart.Document = new Document(
                new Body(
                    new Paragraph(
                        new Run(
                            new Text(text)))));

            mainPart.Document.Save();
        }

        stream.Position = 0;
        return stream;
    }

    private static async Task<List<ExtractedChunk>> ExtractWithTokenAsync(
        string fileName,
        MemoryStream stream,
        CancellationToken cancellationToken)
    {
        var extractor = new LocalDocumentExtractor();
        var result = new List<ExtractedChunk>();

        stream.Position = 0;

        await foreach (var chunk in extractor.ExtractAsync(
            CreateDocument(fileName),
            stream,
            cancellationToken))
        {
            result.Add(chunk);
        }

        return result;
    }

    [Fact]
    public async Task ExtractAsync_HindiDocx_ExtractsHindiText()
    {
        const string hindiText = "नमस्ते, यह AskMe हिंदी दस्तावेज़ परीक्षण है।";
        using var docx = CreateDocxWithText(hindiText);

        var chunks = await ExtractAsync("hindi.docx", docx);

        Assert.NotEmpty(chunks);
        Assert.Contains(
            chunks,
            chunk => chunk.Text.Contains(hindiText, StringComparison.Ordinal));
    }

    [Fact]
    public async Task ExtractAsync_HindiTxt_ExtractsHindiText()
    {
        const string hindiText = "नमस्ते, यह AskMe हिंदी टेक्स्ट परीक्षण है।";
        using var txt = new MemoryStream(Encoding.UTF8.GetBytes(hindiText));

        var chunks = await ExtractAsync("hindi.txt", txt);

        Assert.NotEmpty(chunks);
        Assert.Contains(
            chunks,
            chunk => chunk.Text.Contains(hindiText, StringComparison.Ordinal));
    }

    [Fact]
    public async Task ExtractAsync_CorruptPdf_ThrowsException()
    {
        using var pdf = new MemoryStream(
            Encoding.UTF8.GetBytes("This is not a valid PDF file."));

        await Assert.ThrowsAnyAsync<Exception>(
            () => ExtractAsync("corrupt.pdf", pdf));
    }

    [Fact]
    public async Task ExtractAsync_CorruptDocx_ThrowsException()
    {
        using var docx = new MemoryStream(
            Encoding.UTF8.GetBytes("This is not a valid DOCX file."));

        await Assert.ThrowsAnyAsync<Exception>(
            () => ExtractAsync("corrupt.docx", docx));
    }

    [Fact]
    public async Task ExtractAsync_PreCancelledPdf_ThrowsOperationCanceledException()
    {
        using var pdf = CreatePdf("Cancellation test");
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => ExtractWithTokenAsync("cancel.pdf", pdf, cts.Token));
    }

    [Fact]
    public async Task ExtractAsync_PreCancelledDocx_ThrowsOperationCanceledException()
    {
        using var docx = CreateDocx();
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => ExtractWithTokenAsync("cancel.docx", docx, cts.Token));
    }



    [Fact]
    public async Task ExtractAsync_LargeTxt_ExtractsAllContentInOrderedChunks()
    {
        const string repeatedText = "AskMeLargeFileContent ";
        var largeText = string.Concat(
            Enumerable.Repeat(repeatedText, 250_000));

        using var txt = new MemoryStream(
            Encoding.UTF8.GetBytes(largeText));

        var chunks = await ExtractAsync("large-file.txt", txt);

        Assert.NotEmpty(chunks);
        Assert.True(chunks.Count > 100);

        Assert.Equal(
            Enumerable.Range(1, chunks.Count),
            chunks.Select(chunk => chunk.ChunkNumber));

        Assert.All(chunks, chunk =>
        {
            Assert.NotEmpty(chunk.Text);
            Assert.True(chunk.Text.Length <= 1200);
        });

        var extractedText = string.Concat(
            chunks.Select((chunk, index) =>
                index == 0
                    ? chunk.Text
                    : chunk.Text.Substring(
                        Math.Min(160, chunk.Text.Length))));

        Assert.Contains("AskMeLargeFileContent", extractedText);
    }



    [Fact]
    public async Task ExtractAsync_LargeTxt_ReportsManagedMemory()
    {
        var filePath = Path.Combine(
            Path.GetTempPath(),
            $"askme-memory-{Guid.NewGuid():N}.txt");

        try
        {
            const string repeatedText = "AskMeMemoryDiagnosticContent ";
            const int repetitions = 250_000;

            await using (var writer = new StreamWriter(
                filePath, false, Encoding.UTF8))
            {
                for (var i = 0; i < repetitions; i++)
                    await writer.WriteAsync(repeatedText);
            }

            var fileInfo = new FileInfo(filePath);

            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();

            var heapBefore = GC.GetTotalMemory(true);
            var allocatedBefore = GC.GetTotalAllocatedBytes(true);

            var document = new SelectedDocument(
                "DOC-MEMORY",
                "large-memory.txt",
                "text/plain",
                fileInfo.Length,
                "user-selected-stream");

            var chunkCount = 0;
            string? firstChunk = null;
            var extractor = new LocalDocumentExtractor();

            await using (var source = new FileStream(
                filePath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                await foreach (var chunk in extractor.ExtractAsync(
                    document, source))
                {
                    firstChunk ??= chunk.Text;
                    chunkCount++;
                }
            }

            var allocatedAfter = GC.GetTotalAllocatedBytes(true);
            var heapAfter = GC.GetTotalMemory(true);

            Console.WriteLine(
                $"Input file size: {fileInfo.Length / 1024.0 / 1024.0:F2} MB");

            Console.WriteLine(
                $"Managed bytes allocated: {(allocatedAfter - allocatedBefore) / 1024.0 / 1024.0:F2} MB");

            Console.WriteLine(
                $"Managed heap retained after extraction: {(heapAfter - heapBefore) / 1024.0 / 1024.0:F2} MB");

            Console.WriteLine($"Extracted chunks: {chunkCount}");

            Assert.True(chunkCount > 0);
            Assert.Contains("AskMeMemoryDiagnosticContent", firstChunk);
        }
        finally
        {
            if (File.Exists(filePath))
                File.Delete(filePath);
        }
    }

}
