using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using AskMe.Core;

namespace AskMe.AndroidHost;

/// <summary>
/// Stable C ABI used by the tiny JNI shim in the Flutter Android application.
/// Keep exported signatures blittable and do not expose managed objects across JNI.
/// </summary>
public static unsafe class NativeExports
{
    private static readonly QuestionRequestCoordinator Coordinator = new();

    [UnmanagedCallersOnly(EntryPoint = "askme_backend_api_version", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int ApiVersion() => 1;

    [UnmanagedCallersOnly(EntryPoint = "askme_backend_initialize", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int Initialize() => 0;

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

    [UnmanagedCallersOnly(EntryPoint = "askme_backend_start_request", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static long StartRequest()
    {
        try
        {
            return Coordinator.Start().RequestId;
        }
        catch
        {
            return 0;
        }
    }

    [UnmanagedCallersOnly(EntryPoint = "askme_backend_cancel_request", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int CancelRequest(long requestId) =>
        Coordinator.Cancel(requestId) ? 1 : 0;

    [UnmanagedCallersOnly(EntryPoint = "askme_backend_complete_request", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int CompleteRequest(long requestId) =>
        Coordinator.Complete(requestId) ? 1 : 0;
}
