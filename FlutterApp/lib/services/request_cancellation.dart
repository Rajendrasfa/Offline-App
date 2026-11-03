import 'dart:async';

/// A request-scoped cancellation primitive. Every native adapter (document
/// extraction, inference, STT, TTS and playback) must observe [cancelled].
class RequestCancellation {
  int _nextId = 0;
  int? _activeId;
  Completer<void>? _signal;

  ({int id, Future<void> cancelled}) start() {
    cancelActive();
    final id = ++_nextId;
    final signal = Completer<void>();
    _activeId = id;
    _signal = signal;
    return (id: id, cancelled: signal.future);
  }

  bool isCurrent(int id) => _activeId == id && !(_signal?.isCompleted ?? true);

  void cancelActive() {
    final signal = _signal;
    if (signal != null && !signal.isCompleted) signal.complete();
    _activeId = null;
    _signal = null;
  }

  void complete(int id) {
    if (_activeId == id) {
      _activeId = null;
      _signal = null;
    }
  }
}
