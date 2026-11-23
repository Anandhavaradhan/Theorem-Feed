/// Makes a video start reliably.
///
/// YouTube streams sometimes don't play (an expired or throttled URL, a format
/// the device won't decode, a stream that just never starts). Instead of
/// trying once, playback goes through: the chosen quality → one lower quality
/// → the single-file (muxed) stream → the same again with streams fetched the
/// slower, thorough way. An attempt that hasn't started within [startTimeout]
/// counts as failed. Only when everything has failed is [onFailed] called.
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../models/resolved_video.dart';

class ReliablePlayback {
  ReliablePlayback({
    required this.player,
    required this.refetch,
    required this.onFailed,
    this.onOption,
    this.onStarted,
    this.startTimeout = const Duration(seconds: 12),
  }) {
    _subs
      ..add(player.stream.position.listen(_onPosition))
      ..add(player.stream.error.listen(_onError));
  }

  final Player player;

  /// Fresh streams the thorough way (cache skipped).
  final Future<ResolvedVideo> Function() refetch;
  final void Function() onFailed;
  final void Function(PlaybackOption option)? onOption;
  final void Function()? onStarted;
  final Duration startTimeout;

  final _subs = <StreamSubscription<Object?>>[];
  late ResolvedVideo _video;
  List<PlaybackOption> _queue = const [];
  int _i = 0;
  bool _thoroughTried = false;
  bool _started = false;
  bool _disposed = false;
  Duration _at = Duration.zero;
  Timer? _watchdog;
  int _attemptId = 0;
  double rate = 1.0;

  PlaybackOption? get current => _i < _queue.length ? _queue[_i] : null;
  bool get started => _started;

  /// Plays [first] from [at], falling back as needed.
  Future<void> start(ResolvedVideo video, PlaybackOption first, {Duration at = Duration.zero}) async {
    _video = video;
    _queue = video.fallbacksAfter(first);
    _i = 0;
    _at = at;
    await _attempt();
  }

  Future<void> _attempt() async {
    if (_disposed) return;
    final o = current;
    if (o == null) return _exhausted();
    final id = ++_attemptId;
    _started = false;
    onOption?.call(o);
    _watchdog?.cancel();
    _watchdog = Timer(startTimeout, () {
      if (id == _attemptId && !_started) _next();
    });
    try {
      await player.open(Media(o.videoUrl, start: _at), play: false);
      if (!o.isMuxed) {
        // Video-only stream + separate audio stream, combined on the device.
        await player.setAudioTrack(AudioTrack.uri(o.audioUrl!, title: 'English', language: 'en'));
      }
      await player.setRate(rate);
      await player.play();
    } catch (_) {
      if (id == _attemptId) _next();
    }
  }

  void _onPosition(Duration p) {
    if (!_started && p > _at + const Duration(milliseconds: 300)) {
      _started = true;
      _watchdog?.cancel();
      onStarted?.call();
    }
  }

  void _onError(String message) {
    // Subtitles are optional: their errors never stop the video.
    if (message.toLowerCase().contains('sub')) return;
    if (!_started) {
      _next();
    } else if (!_thoroughTried) {
      // Played, then failed (an expired URL): fresh streams, same quality, same point.
      _at = player.state.position;
      _thorough(keepQuality: true);
    }
  }

  void _next() {
    if (_disposed) return;
    _i++;
    if (_i < _queue.length) {
      unawaited(_attempt());
    } else {
      _exhausted();
    }
  }

  Future<void> _exhausted() async {
    if (_thoroughTried) {
      _watchdog?.cancel();
      onFailed();
      return;
    }
    await _thorough(keepQuality: false);
  }

  Future<void> _thorough({required bool keepQuality}) async {
    _thoroughTried = true;
    final quality = current?.quality;
    try {
      final fresh = await refetch();
      if (_disposed) return;
      _video = fresh;
      final first = keepQuality
          ? fresh.options.firstWhere((o) => o.quality == quality, orElse: () => fresh.options.last)
          : (fresh.options.where((o) => o.isMuxed).firstOrNull ?? fresh.options.last);
      _queue = fresh.fallbacksAfter(first);
      _i = 0;
      await _attempt();
    } catch (_) {
      if (!_disposed) onFailed();
    }
  }

  /// The user picked another quality: play it from here (with its own fallbacks).
  Future<void> switchTo(PlaybackOption option) => start(_video, option, at: player.state.position);

  void dispose() {
    _disposed = true;
    _watchdog?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
  }
}
