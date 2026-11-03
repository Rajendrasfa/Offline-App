namespace AskMe.Core;

/// <summary>Serializes active requests and guarantees that only the current request can publish results.</summary>
public sealed class QuestionRequestCoordinator : IDisposable
{
    private readonly object _gate = new();
    private CancellationTokenSource? _active;
    private long _activeRequestId;
    private bool _disposed;

    public RequestLease Start()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            CancelAndDisposeActive();
            var cts = new CancellationTokenSource();
            _active = cts;
            var id = checked(++_activeRequestId);
            return new RequestLease(id, cts.Token);
        }
    }

    public bool IsCurrent(long requestId)
    {
        lock (_gate)
            return !_disposed && requestId == _activeRequestId &&
                   _active is { IsCancellationRequested: false };
    }

    public bool Cancel(long requestId)
    {
        lock (_gate)
        {
            if (_disposed || requestId != _activeRequestId || _active is null) return false;
            _active.Cancel();
            return true;
        }
    }

    public bool Complete(long requestId)
    {
        lock (_gate)
        {
            if (_disposed || requestId != _activeRequestId || _active is null) return false;
            _active.Dispose();
            _active = null;
            return true;
        }
    }

    private void CancelAndDisposeActive()
    {
        if (_active is null) return;
        try { _active.Cancel(); }
        finally { _active.Dispose(); _active = null; }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            CancelAndDisposeActive();
        }
    }
}

public readonly record struct RequestLease(long RequestId, CancellationToken CancellationToken);
