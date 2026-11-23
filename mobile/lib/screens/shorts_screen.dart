import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/i18n.dart';
import '../core/theme.dart';
import '../models/feed.dart';
import '../providers/providers.dart';
import '../services/local_llm.dart';
import '../services/preloader.dart';
import '../services/watch_history.dart';
import '../widgets/ingestion_banner.dart';
import '../widgets/thumbnail.dart';
import 'concept_detail_screen.dart';
import 'player_screen.dart';

/// Shorts feed (§13.2): full-screen vertical swipe, autoplay, loop.
/// Candidates: material-concept shorts ∪ curated math theorem pool. Nothing else.
class ShortsScreen extends ConsumerStatefulWidget {
  const ShortsScreen({super.key, required this.active});

  /// False while another tab is showing: nothing plays.
  final bool active;

  @override
  ConsumerState<ShortsScreen> createState() => _ShortsScreenState();
}

class _ShortsScreenState extends ConsumerState<ShortsScreen> {
  int _current = 0;
  late final Preloader _preloader = Preloader((id) => ref.read(resolverProvider).resolve(id));

  /// Streams for the next 3 shorts are fetched in the background, and their thumbnails cached.
  void _preload(List<FeedCard> items) {
    if (!widget.active) return;
    _preloader.around([for (final c in items) c.videoId], _current);
    for (var i = _current + 1; i <= _current + 3 && i < items.length; i++) {
      Thumbnail.precache(context, items[i].thumbnailUrl);
    }
  }

  /// Keep a few unwatched shorts ahead: once the model is on the device, find
  /// the next couple of theorems' shorts in the background as you near the end.
  void _topUp(int itemCount) {
    if (!widget.active || !ref.read(modelReadyProvider)) return;
    if (ref.read(ingestionControllerProvider).isBusy) return;
    if (itemCount - _current <= 3) ref.read(ingestionControllerProvider.notifier).fillShorts();
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(shortsFeedProvider);
    final items = feed.value?.items;
    if (items != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _topUp(items.length);
        _preload(items);
      });
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: feed.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: Colors.white))),
        data: (f) => f.items.isEmpty
            ? const _EmptyShorts()
            : RefreshIndicator(
                onRefresh: () => ref.refresh(shortsFeedProvider.future),
                child: PageView.builder(
                  scrollDirection: Axis.vertical,
                  itemCount: f.items.length,
                  onPageChanged: (i) {
                    setState(() => _current = i);
                    _topUp(f.items.length);
                    _preload(f.items);
                  },
                  itemBuilder: (context, i) => _ShortPage(
                    key: ValueKey(f.items[i].videoId),
                    card: f.items[i],
                    active: widget.active && i == _current,
                  ),
                ),
              ),
      ),
    );
  }
}

/// Shorts opened from somewhere else (search results): swipe through [items],
/// starting at [initialIndex], with the same full-screen player as the Shorts tab.
class ShortsViewer extends ConsumerStatefulWidget {
  const ShortsViewer({super.key, required this.items, this.initialIndex = 0});
  final List<FeedCard> items;
  final int initialIndex;

  @override
  ConsumerState<ShortsViewer> createState() => _ShortsViewerState();
}

class _ShortsViewerState extends ConsumerState<ShortsViewer> {
  late int _current = widget.initialIndex;
  late final _pages = PageController(initialPage: widget.initialIndex);
  late final Preloader _preloader = Preloader((id) => ref.read(resolverProvider).resolve(id));

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _preloader.around([for (final c in widget.items) c.videoId], _current));
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pages,
          scrollDirection: Axis.vertical,
          itemCount: widget.items.length,
          onPageChanged: (i) => setState(() => _current = i),
          itemBuilder: (context, i) => _ShortPage(
            key: ValueKey(widget.items[i].videoId),
            card: widget.items[i],
            active: i == _current,
          ),
        ),
        SafeArea(
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ]),
    );
  }
}

class _EmptyShorts extends ConsumerWidget {
  const _EmptyShorts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(ingestionControllerProvider).isBusy;
    return SafeArea(
      child: Column(children: [
        const IngestionBanner(),
        Expanded(child: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.functions, size: 56, color: Colors.white70),
            const SizedBox(height: 16),
            Text(t('shorts.empty.title'),
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 20)),
            const SizedBox(height: 8),
            Text(t('shorts.empty.body', {'size': defaultLocalModel.approxSizeMb}),
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 20),
            if (busy)
              Text(t('shorts.finding'), style: const TextStyle(color: Colors.white))
            else
              FilledButton(
                onPressed: () => ref.read(ingestionControllerProvider.notifier).fillShorts(),
                child: Text(t('shorts.empty.cta')),
              ),
          ]),
        ),
        )),
      ]),
    );
  }
}

class _ShortPage extends ConsumerStatefulWidget {
  const _ShortPage({super.key, required this.card, required this.active});
  final FeedCard card;
  final bool active;

  @override
  ConsumerState<_ShortPage> createState() => _ShortPageState();
}

class _ShortPageState extends ConsumerState<_ShortPage> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  bool _paused = false;
  late bool _saved = ref.read(conceptServiceProvider).isSaved(widget.card.videoId);
  late final FeedCard? _deeper = ref.read(conceptServiceProvider).goDeeper(widget.card.conceptId);
  late final WatchHistoryService _history = ref.read(watchHistoryProvider);
  final _subs = <StreamSubscription<Object?>>[];
  Duration _furthest = Duration.zero;
  bool _recovered = false;

  @override
  void initState() {
    super.initState();
    _history; // capture while mounted
    if (widget.active) _start();
  }

  /// Records this viewing (furthest point reached; 90% counts as completed).
  void _record(Player? p) {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    if (p == null) return;
    final duration = p.state.duration.inSeconds;
    _history.recordViewing(widget.card.videoId,
        watchedSec: _furthest.inSeconds, durationSec: duration > 0 ? duration : widget.card.durationSec);
    _furthest = Duration.zero;
  }

  @override
  void didUpdateWidget(covariant _ShortPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _start();
    if (!widget.active && old.active) _stop();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _paused = false;
    });
    try {
      final resolved = await ref.read(resolverProvider).resolve(widget.card.videoId);
      if (!mounted || !widget.active) return;
      final mq = MediaQuery.of(context);
      final option = resolved.pickOption((math.min(mq.size.width, mq.size.height) * mq.devicePixelRatio).round());
      final player = Player();
      final controller = VideoController(player);
      setState(() {
        _player = player;
        _controller = controller;
      });
      _subs
        ..add(player.stream.position.listen((pos) {
          if (pos > _furthest) _furthest = pos;
        }))
        ..add(player.stream.error.listen((_) {
          // Expired stream URL: fetch fresh ones once and restart.
          if (_recovered || !mounted || !widget.active) return;
          _recovered = true;
          ref.read(resolverProvider).invalidate(widget.card.videoId);
          _stop();
          _start();
        }));
      await player.setPlaylistMode(PlaylistMode.single); // loop
      await player.open(Media(option.videoUrl), play: false);
      if (option.audioUrl != null) await player.setAudioTrack(AudioTrack.uri(option.audioUrl!));
      await player.play();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _stop() {
    final p = _player;
    _record(p);
    setState(() {
      _player = null;
      _controller = null;
    });
    p?.dispose();
  }

  @override
  void dispose() {
    _record(_player);
    _player?.dispose();
    super.dispose();
  }

  void _togglePause() {
    final p = _player;
    if (p == null) return;
    setState(() => _paused = !_paused);
    _paused ? p.pause() : p.play();
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final controller = _controller;
    return Stack(fit: StackFit.expand, children: [
      GestureDetector(
        onTap: _togglePause,
        child: controller == null
            ? Thumbnail(card.thumbnailUrl)
            : Video(controller: controller, fit: BoxFit.cover, controls: NoVideoControls),
      ),
      if (_error != null)
        Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t('player.failed'), style: const TextStyle(color: Colors.white)),
            TextButton(onPressed: _start, child: Text(t('player.retry'))),
          ]),
        )
      else if (_player == null && widget.active)
        const Center(child: CircularProgressIndicator()),
      if (_paused) const Center(child: Icon(Icons.play_arrow, size: 72, color: Colors.white70)),
      // Bottom gradient for legibility.
      const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: 260,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black87],
            ),
          ),
        ),
      ),
      // Header, as on full-screen short-video apps.
      const Positioned(
        left: 16,
        top: 0,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('Shorts',
                style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700,
                    shadows: [Shadow(blurRadius: 6, color: Colors.black54)])),
          ),
        ),
      ),
      // Bottom-left: the concept as the "channel", then the title.
      Positioned(
        left: 12,
        right: 80,
        bottom: 20,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => ConceptDetailScreen(conceptId: card.conceptId))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              ConceptAvatar(card.conceptName, radius: 16),
              const SizedBox(width: 8),
              Flexible(
                child: Text(card.conceptName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: Text(card.fromMaterial ? t('shorts.chip.material') : t('shorts.chip.theorem'),
                    style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Text(card.title,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14)),
          const SizedBox(height: 4),
          Text(card.reasonLabel, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ]),
      ),
      // Right-hand action rail.
      Positioned(
        right: 6,
        bottom: 24,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _SideButton(
            icon: _saved ? Icons.bookmark : Icons.bookmark_border,
            label: _saved ? t('shorts.saved') : t('shorts.save'),
            onTap: () => setState(() => _saved = ref.read(conceptServiceProvider).toggleSaved(card.videoId)),
          ),
          if (_deeper != null) ...[
            const SizedBox(height: 20),
            _SideButton(
              icon: Icons.school_outlined,
              label: t('shorts.go_deeper'),
              onTap: () {
                _player?.pause();
                setState(() => _paused = true);
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(videoId: _deeper.videoId, title: _deeper.title, reasonLabel: _deeper.reasonLabel),
                ));
              },
            ),
          ],
          const SizedBox(height: 20),
          _SideButton(
            icon: Icons.info_outline,
            label: t('shorts.concept'),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => ConceptDetailScreen(conceptId: card.conceptId))),
          ),
        ]),
      ),
      // Thin progress bar along the bottom edge.
      if (_player != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: StreamBuilder<Duration>(
            stream: _player!.stream.position,
            builder: (context, snap) {
              final total = _player?.state.duration.inMilliseconds ?? 0;
              final pos = snap.data?.inMilliseconds ?? 0;
              return LinearProgressIndicator(
                value: total <= 0 ? 0 : (pos / total).clamp(0, 1).toDouble(),
                minHeight: 2,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(AppColors.accent),
              );
            },
          ),
        ),
    ]);
  }
}

class _SideButton extends StatelessWidget {
  const _SideButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 32),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ]),
    );
  }
}
