import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/i18n.dart';
import '../models/feed.dart';
import '../providers/providers.dart';
import '../services/local_llm.dart';
import '../widgets/ingestion_banner.dart';
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
    final n = feed.value?.items.length;
    if (n != null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _topUp(n) : null);
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

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
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
    setState(() {
      _player = null;
      _controller = null;
    });
    p?.dispose();
  }

  @override
  void dispose() {
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
            ? (card.thumbnailUrl == null
                ? const ColoredBox(color: Colors.black)
                : Image.network(card.thumbnailUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()))
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
      Positioned(
        left: 16,
        right: 88,
        bottom: 24,
        child: SafeArea(
          top: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: card.fromMaterial ? Colors.indigoAccent : Colors.teal,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(card.fromMaterial ? t('shorts.chip.material') : t('shorts.chip.theorem'),
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => ConceptDetailScreen(conceptId: card.conceptId))),
              child: Text(card.conceptName,
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 4),
            Text(card.reasonLabel, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 4),
            Text(card.title,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14)),
          ]),
        ),
      ),
      Positioned(
        right: 8,
        bottom: 32,
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _SideButton(
              icon: _saved ? Icons.bookmark : Icons.bookmark_border,
              label: _saved ? t('shorts.saved') : t('shorts.save'),
              onTap: () => setState(() => _saved = ref.read(conceptServiceProvider).toggleSaved(card.videoId)),
            ),
            if (_deeper != null) ...[
              const SizedBox(height: 16),
              _SideButton(
                icon: Icons.school,
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
          ]),
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
