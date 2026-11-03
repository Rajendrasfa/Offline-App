using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;
using UglyToad.PdfPig;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Wordprocessing;

namespace AskMe.Core;

/// <summary>Extracts text directly from a caller-owned stream; it never writes the original file.</summary>
public sealed class LocalDocumentExtractor : IDocumentExtractor
{
    private const int ChunkSize = 1200;
    private const int Overlap = 160;

    public async IAsyncEnumerable<ExtractedChunk> ExtractAsync(
        SelectedDocument document, Stream source,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(document);
        ArgumentNullException.ThrowIfNull(source);
        cancellationToken.ThrowIfCancellationRequested();
        var ext = Path.GetExtension(document.DisplayName).ToLowerInvariant();
        string text;
        if (ext == ".pdf") text = ReadPdf(source, cancellationToken);
        else if (ext == ".docx") text = ReadDocx(source, cancellationToken);
        else if (ext is ".txt" or ".md" or ".csv" or ".json") text = await ReadTextAsync(source, cancellationToken);
        else throw new NotSupportedException("Supported formats: PDF, DOCX, TXT, MD, CSV, JSON.");

        var chunks = Split(text);
        for (var i = 0; i < chunks.Count; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            yield return new ExtractedChunk(document.DocumentId, i + 1, chunks[i], null);
        }
    }

    private static string ReadPdf(Stream stream, CancellationToken ct)
    {
        using var pdf = PdfDocument.Open(stream);
        var sb = new StringBuilder();
        foreach (var page in pdf.GetPages())
        {
            ct.ThrowIfCancellationRequested();
            sb.AppendLine(page.Text);
        }
        return sb.ToString();
    }

    private static string ReadDocx(Stream stream, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        using var doc = WordprocessingDocument.Open(stream, false);
        return string.Join("\n", doc.MainDocumentPart?.Document.Body?
            .Descendants<Paragraph>().Select(p => p.InnerText) ?? Enumerable.Empty<string>());
    }

    private static async Task<string> ReadTextAsync(Stream stream, CancellationToken ct)
    {
        using var reader = new StreamReader(stream, Encoding.UTF8, true, 8192, leaveOpen: true);
        return await reader.ReadToEndAsync(ct);
    }

    private static List<string> Split(string input)
    {
        var normalized = Regex.Replace(input, @"\s+", " ").Trim();
        var result = new List<string>();
        for (var start = 0; start < normalized.Length; start += ChunkSize - Overlap)
        {
            var length = Math.Min(ChunkSize, normalized.Length - start);
            if (length > 0) result.Add(normalized.Substring(start, length));
            if (start + length >= normalized.Length) break;
        }
        return result;
    }
}
