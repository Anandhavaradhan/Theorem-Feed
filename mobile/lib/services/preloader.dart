/// Shorts preload (Phase F): resolve the next few shorts' streams in the
/// background so swiping starts playback immediately. One at a time, each
/// video once per session; failures are ignored (the page retries on its own).
library;

class Preloader {
  Preloader(this._resolve, {this.ahead = 3});

  final Future<void> Function(String videoId) _resolve;
  final int ahead;
  final _done = <String>{};
  Future<void> _queue = Future.value();

  /// Preloads items after [current] in [videoIds].
  void around(List<String> videoIds, int current) {
    for (var i = current + 1; i <= current + ahead && i < videoIds.length; i++) {
      final id = videoIds[i];
      if (!_done.add(id)) continue;
      _queue = _queue.then((_) => _resolve(id)).catchError((Object _) {});
    }
  }

  /// Completes when everything queued so far has been attempted (for tests).
  Future<void> get idle => _queue;
}
