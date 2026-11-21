import 'dart:async';
import 'dart:math' as math;

import 'package:chewie/chewie.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../core/api_client.dart';
import '../core/captions.dart';
import '../core/i18n.dart';
import '../models/resolved_video.dart';
import '../providers/providers.dart';

/// Native, ad-free player: direct stream URL from /resolve → video_player + chewie.
/// No IFrame, no embedded YouTube player, no tracking.
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
          retryAfterSec: e is ResolveFailed ? e.retryAfterSec : null,
          onRetry: () => ref.invalidate(resolveProvider(videoId)),
        ),
        data: (video) => _Player(video: video, reasonLabel: reasonLabel),
      ),
    );
  }
}

class _ResolveError extends StatefulWidget {
  const _ResolveError({required this.retryAfterSec, required this.onRetry});
  final int? retryAfterSec;
  final VoidCallback onRetry;

  @override
  State<_ResolveError> createState() => _ResolveErrorState();
}

class _ResolveErrorState extends State<_ResolveError> {
  Timer? _timer;
  int _left = 0;

  @override
  void initState() {
    super.initState();
    if (widget.retryAfterSec != null) {
      _left = widget.retryAfterSec!;
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_left <= 1) {
          timer.cancel();
          widget.onRetry();
        } else {
          setState(() => _left--);
        }
      });
    }
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
        Text(t('player.failed')),
        if (_timer?.isActive ?? false) ...[
          const SizedBox(height: 4),
          Text(t('player.retry_in', {'sec': _left})),
        ],
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
  VideoPlayerController? _video;
  ChewieController? _chewie;
  StreamFormat? _format;
  List<Subtitle> _subtitles = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_format == null) {
      final mq = MediaQuery.of(context);
      final shortSidePx = (math.min(mq.size.width, mq.size.height) * mq.devicePixelRatio).round();
      _open(widget.video.pickFormat(shortSidePx));
      _loadCaptions();
    }
  }

  Future<void> _loadCaptions() async {
    final tracks = widget.video.captions;
    if (tracks.isEmpty) return;
    try {
      final raw = await ref.read(apiClientProvider).fetchText(tracks.first.url);
      final subs = parseCaptions(raw);
      if (!mounted || subs.isEmpty) return;
      setState(() => _subtitles = subs);
      _rebuildChewie(autoPlay: _video?.value.isPlaying ?? true);
    } catch (_) {
      // Captions are optional; playback continues without them.
    }
  }

  Future<void> _open(StreamFormat format, {Duration startAt = Duration.zero}) async {
    final old = _video;
    final oldChewie = _chewie;
    setState(() {
      _format = format;
      _chewie = null;
    });
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(format.url),
      formatHint: format.isHls ? VideoFormat.hls : null,
    );
    _video = controller;
    oldChewie?.dispose();
    await old?.dispose();
    await controller.initialize();
    if (startAt > Duration.zero) await controller.seekTo(startAt);
    if (!mounted || _video != controller) return;
    _rebuildChewie(autoPlay: true);
  }

  void _rebuildChewie({required bool autoPlay}) {
    final controller = _video;
    if (controller == null || !controller.value.isInitialized) return;
    final previous = _chewie;
    setState(() {
      _chewie = ChewieController(
        videoPlayerController: controller,
        autoPlay: autoPlay,
        aspectRatio: controller.value.aspectRatio,
        playbackSpeeds: const [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2],
        allowedScreenSleep: false,
        subtitle: _subtitles.isEmpty ? null : Subtitles(_subtitles),
        showSubtitles: _subtitles.isNotEmpty,
        subtitleBuilder: (context, text) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Colors.black54,
          child: Text('$text', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
        ),
        additionalOptions: (context) => [
          OptionItem(
            onTap: (ctx) {
              Navigator.of(ctx).pop();
              _chooseQuality();
            },
            iconData: Icons.high_quality,
            title: '${t('player.quality')}: ${_format?.quality ?? ''}',
          ),
        ],
      );
    });
    previous?.dispose();
  }

  Future<void> _chooseQuality() async {
    final picked = await showModalBottomSheet<StreamFormat>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(t('player.quality'), style: Theme.of(ctx).textTheme.titleMedium)),
            for (final f in widget.video.formats)
              ListTile(
                title: Text(f.quality),
                subtitle: Text(f.isHls ? 'HLS' : 'MP4'),
                trailing: identical(f, _format) ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(f),
              ),
          ],
        ),
      ),
    );
    if (picked != null && !identical(picked, _format)) {
      await _open(picked, startAt: _video?.value.position ?? Duration.zero);
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chewie = _chewie;
    final aspect = widget.video.isVertical ? 9 / 16 : 16 / 9;
    return ListView(
      children: [
        AspectRatio(
          aspectRatio: chewie?.aspectRatio ?? aspect,
          child: ColoredBox(
            color: Colors.black,
            child: chewie == null ? const Center(child: CircularProgressIndicator()) : Chewie(controller: chewie),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.reasonLabel,
                  style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(widget.video.title, style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
      ],
    );
  }
}
