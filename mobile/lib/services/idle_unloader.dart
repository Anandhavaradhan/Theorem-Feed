/// Calls [onIdle] once nothing has used a resource for [timeout].
///
/// Wrap each use in [run]; the countdown only starts when no use is in
/// progress, and any new use cancels it.
library;

import 'dart:async';

class IdleUnloader {
  IdleUnloader({required this.timeout, required this.onIdle});

  final Duration timeout;
  final Future<void> Function() onIdle;
  int _busy = 0;
  Timer? _timer;

  bool get isBusy => _busy > 0;
  bool get countdownActive => _timer?.isActive ?? false;

  Future<T> run<T>(Future<T> Function() body) async {
    _timer?.cancel();
    _busy++;
    try {
      return await body();
    } finally {
      _busy--;
      if (_busy == 0) arm();
    }
  }

  /// (Re)starts the countdown, e.g. right after the resource is loaded.
  void arm() {
    _timer?.cancel();
    _timer = Timer(timeout, () {
      if (_busy == 0) onIdle();
    });
  }

  void cancel() => _timer?.cancel();
}
