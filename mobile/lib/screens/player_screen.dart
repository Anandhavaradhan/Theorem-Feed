import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/i18n.dart';
import '../models/resolved_video.dart';
import '../providers/providers.dart';
import '../services/resolver.dart';
import '../services/watch_history.dart';

/// Native, ad-free player. Streams come straight from YouTube to the phone;
/// for HD, the separate video and audio streams are combined on the device by
/// media_kit (libmpv). No IFrame, no embedded YouTube player, no tracking.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key, required this.videoId, required this.title, required this.reasonLabel});

  final String videoId;
  final String title;
  final String reasonLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = ref.watch(resolveProvider(videoId));
    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: resolved.when(
        loading: () => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(t('player.resolving')),
          ]),
        ),
        error: (e, _) => _ResolveError(
          retryAfterSec: e is ResolveFailed ? e.retryAfterSec : resolveRetryAfterSec,
          offline: e is ResolveFailed && e.offline,
          onRetry: () => ref.invalidate(resolveProvider(videoId)),
        ),
        data: (video) => _Player(video: video, reasonLabel: reasonLabel),
      ),
    );
  }
}

class _ResolveError extends StatefulWidget {
  const _ResolveError({required this.retryAfterSec, required this.onRetry, this.offline = false});
  final int retryAfterSec;
  final VoidCallback onRetry;
  final bool offline;

  @override
  State<_ResolveError> createState() => _ResolveErrorState();
}

class _ResolveErrorState extends State<_ResolveError> {
  late int _left = widget.retryAfterSec;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_left <= 1) {
        timer.cancel();
        widget.onRetry();
      } else {
        setState(() => _left--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(widget.offline ? t('player.offline') : t('player.failed'), textAlign: TextAlign.center),
        ),
        const SizedBox(height: 4),
        Text(t('player.retry_in', {'sec': _left})),
        const SizedBox(height: 12),
        FilledButton(onPressed: widget.onRetry, child: Text(t('player.retry'))),
      ]),
    );
  }
}

class _Player extends ConsumerStatefulWidget {
  const _Player({required this.video, required this.reasonLabel});
  final ResolvedVideo video;
  final String reasonLabel;

  @override
  ConsumerState<_Player> createState() => _PlayerState();
}

class _PlayerState extends ConsumerState<_Player> {
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  PlaybackOption? _option;
  double _speed = 1.0;
  bool _captions = false;
  late ResolvedVideo _video = widget.video;
  Duration _furthest = Duration.zero;
  bool _recovered = false;
  final _subs = <StreamSubscription<Object?>>[];

  late final WatchHistoryService _history;

  @override
  void initState() {
    super.initState();
    _history = ref.read(watchHistoryProvider);
    _subs
      ..add(_player.stream.position.listen((p) {
        if (p > _furthest) _furthest = p;
      }))
      ..add(_player.stream.error.listen((_) => _recover()));
  }

  /// YouTube stream URLs expire; if playback fails, fetch fresh ones once and
  /// continue from the same point.
  Future<void> _recover() async {
    if (_recovered || !mounted) return;
    _recovered = true;
    final at = _player.state.position;
    final resolver = ref.read(resolverProvider)..invalidate(_video.videoId);
    try {
      final fresh = await resolver.resolve(_video.videoId);
      if (!mounted) return;
      _video = fresh;
      final quality = _option?.quality;
      await _open(fresh.options.firstWhere((o) => o.quality == quality, orElse: () => fresh.options.first), start: at);
    } catch (_) {
      // The player shows its own error state; nothing more to do.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_option == null) {
      final mq = MediaQuery.of(context);
      final shortSidePx = (math.min(mq.size.width, mq.size.height) * mq.devicePixelRatio).round();
      _captions = widget.video.captions.isNotEmpty;
      // Long videos resume where you stopped; finished ones start over.
      final resume = widget.video.isVertical ? null : ref.read(watchHistoryProvider).resumeAt(widget.video.videoId);
      _open(widget.video.pickOption(shortSidePx), start: Duration(seconds: resume ?? 0));
    }
  }

  Future<void> _open(PlaybackOption option, {Duration start = Duration.zero}) async {
    setState(() => _option = option);
    await _player.open(Media(option.videoUrl, start: start), play: false);
    if (!option.isMuxed) {
      // Video-only stream + separate audio stream, combined on the device.
      await _player.setAudioTrack(AudioTrack.uri(option.audioUrl!, title: 'English', language: 'en'));
    }
    await _applyCaptions();
    await _player.setRate(_speed);
    await _player.play();
  }

  Future<void> _applyCaptions() async {
    final tracks = widget.video.captions;
    await _player.setSubtitleTrack(
      _captions && tracks.isNotEmpty
          ? SubtitleTrack.uri(tracks.first.url, title: 'English', language: 'en')
          : SubtitleTrack.no(),
    );
  }

  Future<void> _chooseQuality() async {
    final picked = await showModalBottomSheet<PlaybackOption>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(t('player.quality'), style: Theme.of(ctx).textTheme.titleMedium)),
          for (final o in _video.options)
            ListTile(
              title: Text(o.quality),
              trailing: identical(o, _option) ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(ctx).pop(o),
            ),
        ]),
      ),
    );
    if (picked != null && !identical(picked, _option)) {
      await _open(picked, start: _player.state.position);
    }
  }

  Future<void> _chooseSpeed() async {
    final picked = await showModalBottomSheet<double>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(t('player.speed'), style: Theme.of(ctx).textTheme.titleMedium)),
          for (final s in _speeds)
            ListTile(
              title: Text('${s}x'),
              trailing: s == _speed ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(ctx).pop(s),
            ),
        ]),
      ),
    );
    if (picked != null) {
      setState(() => _speed = picked);
      await _player.setRate(picked);
    }
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _history.recordViewing(
          _video.videoId,
          watchedSec: _furthest.inSeconds,
          durationSec: _player.state.duration.inSeconds > 0 ? _player.state.duration.inSeconds : _video.durationSec,
        );
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasCaptions = widget.video.captions.isNotEmpty;
    return ListView(
      children: [
        AspectRatio(
          aspectRatio: widget.video.isVertical ? 9 / 16 : 16 / 9,
          child: Video(controller: _controller),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            TextButton.icon(
              onPressed: _chooseQuality,
              icon: const Icon(Icons.high_quality),
              label: Text(_option?.quality ?? ''),
            ),
            TextButton.icon(onPressed: _chooseSpeed, icon: const Icon(Icons.speed), label: Text('${_speed}x')),
            if (hasCaptions)
              TextButton.icon(
                onPressed: () async {
                  setState(() => _captions = !_captions);
                  await _applyCaptions();
                },
                icon: Icon(_captions ? Icons.closed_caption : Icons.closed_caption_off),
                label: Text(_captions ? t('player.captions_on') : t('player.captions_off')),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.reasonLabel,
                style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(widget.video.title, style: Theme.of(context).textTheme.titleLarge),
          ]),
        ),
      ],
    );
  }
}
