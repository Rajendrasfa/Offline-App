using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using AskMe.Core;

namespace AskMe.AndroidHost;

/// <summary>
/// Stable C ABI used by the JNI shim in the Flutter Android application.
/// All exported symbols are prefixed "askme_backend_" to avoid link-name collisions.
///
/// Threading contract:
///   - Every export is re-entrant-safe and stateless except where a request session
///     is explicitly opened with askme_backend_start_request.
///   - Native memory returned via out-pointer buffers is owned by the caller;
///     the native side writes only within the declared buffer bounds.
/// </summary>
public static unsafe class NativeExports
{
    // -------------------------------------------------------------------------
    // Shared infrastructure
    // -------------------------------------------------------------------------

    private static readonly QuestionRequestCoordinator Coordinator = new();
    private static readonly LocalDocumentExtractor Extractor = new();

    /// <summary>
    /// Per-request document chunk cache keyed by request-id.
    /// Entries are created by askme_backend_process_document and consumed by
    /// askme_backend_retrieve_chunks.  Entries are removed when the request is
    /// completed or cancelled.
    /// </summary>
    private static readonly ConcurrentDictionary<long, IReadOnlyList<ExtractedChunk>> ChunkCache = new();

    // -------------------------------------------------------------------------
    // Version / health
    // -------------------------------------------------------------------------

    /// <summary>Returns the ABI version of this native library (currently 2).</summary>
    [UnmanagedCallersOnly(EntryPoint = "askme_backend_api_version", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int ApiVersion() => 2;

    /// <summary>Initialises shared state. Returns 0 on success.</summary>
    [UnmanagedCallersOnly(EntryPoint = "askme_backend_initialize", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int Initialize() => 0;

    // -------------------------------------------------------------------------
    // Input validation
    // -------------------------------------------------------------------------

    /// <summary>
    /// Validates that <paramref name="utf8Text"/> is a non-empty, well-formed UTF-8
    /// question that is within the allowed length.
    /// Returns:
    ///   0 = valid
    ///   1 = null or empty
    ///   2 = exceeds 32 KiB limit
    ///   3 = invalid UTF-8
    /// </summary>
    [UnmanagedCallersOnly(EntryPoint = "askme_backend_validate_question", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int ValidateQuestion(byte* utf8Text, int length)
    {
        if (utf8Text is null || length <= 0)
            return 1;
        if (length > 32 * 1024)
            return 2;

        try
        {
            var question = new UTF8Encoding(false, true).GetString(new ReadOnlySpan<byte>(utf8Text, length));
            return string.IsNullOrWhiteSpace(question) ? 1 : 0;
        }
        catch (DecoderFallbackException)
        {
            return 3;
        }
    }

    // -------------------------------------------------------------------------
    // Request lifecycle
    // -------------------------------------------------------------------------

    /// <summary>
    /// Allocates a new request lease and returns its numeric id (> 0).
    /// Returns 0 on failure.  Any previously active request is cancelled.
    /// </summary>
    [UnmanagedCallersOnly(EntryPoint = "askme_backend_start_request", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static long StartRequest()
    {
        try
        {
            var lease = Coordinator.Start();
            return lease.RequestId;
        }
        catch
        {
            return 0;
        }
    }

    /// <summary>Cancels the active request.  Returns 1 if cancelled, 0 otherwise.</summary>
    [UnmanagedCallersOnly(EntryPoint = "askme_backend_cancel_request", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int CancelRequest(long requestId)
    {
        ChunkCache.TryRemove(requestId, out _);
        return Coordinator.Cancel(requestId) ? 1 : 0;
    }

    /// <summary>Marks the active request as completed.  Returns 1 if completed, 0 otherwise.</summary>
    [UnmanagedCallersOnly(EntryPoint = "askme_backend_complete_request", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int CompleteRequest(long requestId)
    {
        ChunkCache.TryRemove(requestId, out _);
        return Coordinator.Complete(requestId) ? 1 : 0;
    }

    // -------------------------------------------------------------------------
    // Document processing
    // -------------------------------------------------------------------------

    /// <summary>
    /// Extracts and chunks a document supplied as a raw byte buffer, then stores
    /// the resulting chunks in <see cref="ChunkCache"/> under <paramref name="requestId"/>.
    ///
    /// Parameters:
    ///   requestId   - Must be the id returned by askme_backend_start_request.
    ///   docBytes    - Pointer to the document bytes (PDF, DOCX, TXT, MD, CSV, JSON).
    ///   docLength   - Byte count of the document buffer.
    ///   fileNameUtf8 - UTF-8 file name including extension, used to select the parser.
    ///   fileNameLen  - Byte length of the file name string.
    ///   outChunkCount - Receives the number of chunks extracted on success.
    ///
    /// Returns:
    ///   0  = success (chunks stored; call askme_backend_retrieve_chunks next)
    ///   1  = invalid arguments
    ///   2  = request-id is not the active request
    ///   3  = unsupported document format
    ///   4  = extraction error (corrupt file, encoding failure, etc.)
    ///   5  = document exceeds 25 MB limit
    /// </summary>
    [UnmanagedCallersOnly(EntryPoint = "askme_backend_process_document", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int ProcessDocument(
        long requestId,
        byte* docBytes, int docLength,
        byte* fileNameUtf8, int fileNameLen,
        int* outChunkCount)
    {
        if (docBytes is null || docLength <= 0 || fileNameUtf8 is null || fileNameLen <= 0 || outChunkCount is null)
            return 1;
        if (!Coordinator.IsCurrent(requestId))
            return 2;
        if (docLength > 25 * 1024 * 1024)
            return 5;

        string fileName;
        try
        {
            fileName = new UTF8Encoding(false, true).GetString(new ReadOnlySpan<byte>(fileNameUtf8, fileNameLen));
        }
        catch
        {
            return 1;
        }

        var ext = Path.GetExtension(fileName).ToLowerInvariant();
        if (!new[] { ".pdf", ".docx", ".txt", ".md", ".csv", ".json", ".jpg", ".jpeg", ".png", ".webp", ".bmp" }.Contains(ext))
            return 3;

        try
        {
            var doc = new SelectedDocument(
                DocumentId: $"req-{requestId}",
                DisplayName: fileName,
                ContentType: MimeForExtension(ext),
                Length: docLength,
                SourceReference: "user-selected-saf");

            var docSpan = new ReadOnlySpan<byte>(docBytes, docLength);
            using var stream = new MemoryStream(docSpan.ToArray(), writable: false);

            var chunks = new List<ExtractedChunk>();
            // IAsyncEnumerable must be drained synchronously here because
            // UnmanagedCallersOnly functions cannot be async.
            var enumerator = Extractor.ExtractAsync(doc, stream).GetAsyncEnumerator();
            try
            {
                while (true)
                {
                    // GetResult() returns the bool result of MoveNextAsync directly.
                    bool hasNext = enumerator.MoveNextAsync().AsTask().GetAwaiter().GetResult();
                    if (!hasNext) break;
                    chunks.Add(enumerator.Current);
                }
            }
            finally
            {
                enumerator.DisposeAsync().AsTask().GetAwaiter().GetResult();
            }

            ChunkCache[requestId] = chunks;
            *outChunkCount = chunks.Count;
            return 0;
        }
        catch (NotSupportedException)
        {
            return 3;
        }
        catch
        {
            return 4;
        }
    }

    // -------------------------------------------------------------------------
    // Chunk retrieval (RAG)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Retrieves the most relevant chunks for <paramref name="questionUtf8"/> from the
    /// chunks stored by the previous <see cref="ProcessDocument"/> call and serialises
    /// them as a single UTF-8 context string into <paramref name="outBuffer"/>.
    ///
    /// The context string is formatted as:
    ///   [Chunk 1 (page P)]\n{text}\n\n[Chunk 2]\n{text}\n\n...
    ///
    /// Parameters:
    ///   requestId        - Active request id.
    ///   questionUtf8     - UTF-8 question bytes.
    ///   questionLen      - Byte count.
    ///   outBuffer        - Caller-allocated buffer that receives the UTF-8 context.
    ///   outBufferSize    - Capacity of outBuffer in bytes.
    ///   outWritten       - Receives the number of bytes written (excluding null terminator).
    ///
    /// Returns:
    ///   0  = success
    ///   1  = invalid arguments
    ///   2  = request-id is not the active request
    ///   3  = no document chunks cached for this request; call ProcessDocument first
    ///   6  = outBuffer too small; *outWritten contains the required size
    ///   7  = invalid UTF-8 in question
    /// </summary>
    [UnmanagedCallersOnly(EntryPoint = "askme_backend_retrieve_chunks", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int RetrieveChunks(
        long requestId,
        byte* questionUtf8, int questionLen,
        byte* outBuffer, int outBufferSize,
        int* outWritten)
    {
        if (questionUtf8 is null || questionLen <= 0 || outBuffer is null || outBufferSize <= 0 || outWritten is null)
            return 1;
        if (!Coordinator.IsCurrent(requestId))
            return 2;
        if (!ChunkCache.TryGetValue(requestId, out var allChunks))
            return 3;

        string question;
        try
        {
            question = new UTF8Encoding(false, true).GetString(new ReadOnlySpan<byte>(questionUtf8, questionLen));
        }
        catch (DecoderFallbackException)
        {
            return 7;
        }

        // Keyword-based retrieval — same logic as KeywordChunkRetriever but inline
        // to avoid async allocation in the native export.
        char[] trimChars = ['.', ',', '?', '!', ':', ';', '"', '\'', '@', '#', '(', ')', '[', ']', '{', '}', '।', '-', '/'];
        var terms = question.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(x => x.Trim(trimChars).ToLowerInvariant())
            .Where(x => x.Length >= 2)
            .Distinct()
            .ToArray();

        var scored = allChunks
            .Select(c => new
            {
                Chunk = c,
                Score = terms.Count(t => c.Text.Contains(t, StringComparison.OrdinalIgnoreCase))
            })
            .Where(x => x.Score > 0)
            .OrderByDescending(x => x.Score)
            .ThenBy(x => x.Chunk.ChunkNumber)
            .Take(8)
            .Select(x => x.Chunk)
            .ToArray();

        // Fall back to first 4 chunks when no keyword match (short queries, typos, etc.)
        var relevant = scored.Length > 0 ? scored : allChunks.Take(4).ToArray();

        var sb = new StringBuilder();
        foreach (var chunk in relevant)
        {
            var pageTag = chunk.PageOrTimestamp is not null ? $" (page {chunk.PageOrTimestamp})" : string.Empty;
            sb.Append($"[Chunk {chunk.ChunkNumber}{pageTag}]\n");
            sb.Append(chunk.Text);
            sb.Append("\n\n");
        }

        var contextText = sb.ToString().TrimEnd();
        var encoded = new UTF8Encoding(false).GetBytes(contextText);

        *outWritten = encoded.Length;
        if (encoded.Length >= outBufferSize)
            return 6; // buffer too small — caller should retry with larger buffer

        encoded.AsSpan().CopyTo(new Span<byte>(outBuffer, outBufferSize));
        outBuffer[encoded.Length] = 0; // null-terminate
        return 0;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private static string MimeForExtension(string ext) => ext switch
    {
        ".pdf"            => "application/pdf",
        ".docx"           => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".txt"            => "text/plain",
        ".md"             => "text/markdown",
        ".csv"            => "text/csv",
        ".json"           => "application/json",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".png"            => "image/png",
        ".webp"           => "image/webp",
        ".bmp"            => "image/bmp",
        _                 => "application/octet-stream",
    };
}
