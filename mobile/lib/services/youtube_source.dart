/// Candidate discovery for scoped ingestion, straight from YouTube on the phone.
///
/// Only called with queries built from in-scope concepts (material concepts or
/// the curated theorem pool). There is no browse/explore entry point.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yte;

import 'gates.dart';

class CandidateVideo {
  CandidateVideo(
      {required this.id, required this.title, required this.description, this.durationSec, this.thumbnailUrl, this.channel});
  final String id;
  final String? channel;
  final String title;
  final String description;
  final int? durationSec;
  final String? thumbnailUrl;
}

class VideoDetails {
  VideoDetails({
    required this.title,
    required this.description,
    required this.durationSec,
    required this.thumbnailUrl,
    required this.transcriptLines,
    required this.isVertical,
    this.channel,
    this.spokenLanguage = 'en',
  });

  final String? channel;

  /// The language YouTube's speech recognition heard (the auto-generated caption
  /// track's language), e.g. "en", "ta", "hi". Null when YouTube has no such
  /// track, so the speech must be checked another way. English subtitles on a
  /// Tamil video are a manual track: they don't make the video English.
  final String? spokenLanguage;

  final String title;
  final String description;
  final int? durationSec;
  final String thumbnailUrl;

  /// Caption lines in the video's own language: a manual English track if one
  /// exists, else the auto-generated (speech-recognised) track. Empty if none.
  final List<String> transcriptLines;
  final bool isVertical;

  String get transcript => transcriptLines.join('\n');
}

abstract class VideoSource {
  /// [shortOnly]: YouTube's "under 4 minutes" filter, for shorts searches.
  Future<List<CandidateVideo>> search(String query, {int limit = 8, bool shortOnly = false});
  /// Metadata, transcript and orientation. [needVertical] = false skips the
  /// stream-list request (only shorts need to know whether they're vertical).
  Future<VideoDetails> details(String youtubeId, {bool needVertical = true});

  /// Downloads roughly the first [length] of audio to a temp file; null if unavailable.
  Future<String?> downloadAudioClip(String youtubeId, {Duration length = const Duration(seconds: 30)});
}

class YoutubeExplodeSource implements VideoSource {
  YoutubeExplodeSource([yte.YoutubeExplode? yt]) : _yt = yt ?? yte.YoutubeExplode();
  final yte.YoutubeExplode _yt;

  @override
  Future<List<CandidateVideo>> search(String query, {int limit = 8, bool shortOnly = false}) async {
    // Every YouTube request has a time limit: a stuck connection mustn't freeze finding videos.
    final results = await _yt.search
        .search(query, filter: shortOnly ? yte.DurationFilters.short : yte.TypeFilters.video)
        .timeout(const Duration(seconds: 20));
    return [
      for (final v in results.take(limit))
        if (!v.isLive)
          CandidateVideo(
            id: v.id.value,
            title: v.title,
            description: v.description,
            durationSec: v.duration?.inSeconds,
            thumbnailUrl: v.thumbnails.highResUrl,
            channel: v.author,
          ),
    ];
  }

  @override
  Future<VideoDetails> details(String youtubeId, {bool needVertical = true}) async {
    // The three requests are independent: run them at the same time.
    final videoF = _yt.videos.get(youtubeId).timeout(const Duration(seconds: 20));
    final verticalF = needVertical ? _isVertical(youtubeId) : Future.value(false);
    final captionsF = _captions(youtubeId);
    final video = await videoF;
    final isVertical = await verticalF;
    final (lines, spoken) = await captionsF;
    return VideoDetails(
      title: video.title,
      description: video.description,
      durationSec: video.duration?.inSeconds,
      thumbnailUrl: video.thumbnails.highResUrl,
      transcriptLines: lines,
      isVertical: isVertical,
      channel: video.author,
      spokenLanguage: spoken,
    );
  }

  /// Orientation from the stream list, the fast way; unknown (false) if YouTube
  /// doesn't answer quickly. Never fails the whole lookup.
  Future<bool> _isVertical(String youtubeId) async {
    try {
      final manifest = await _yt.videos.streams
          .getManifest(youtubeId, requireWatchPage: false)
          .timeout(const Duration(seconds: 6));
      final withVideo = [...manifest.videoOnly, ...manifest.muxed]
        ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
      return withVideo.isNotEmpty && withVideo.first.videoResolution.height > withVideo.first.videoResolution.width;
    } catch (_) {
      return false;
    }
  }

  /// Caption lines (a manual English track if one exists, else the
  /// speech-recognised track) and the spoken language (the speech-recognised
  /// track's language; null if YouTube has none).
  Future<(List<String>, String?)> _captions(String youtubeId) async {
    try {
      final cc = await _yt.videos.closedCaptions.getManifest(youtubeId).timeout(const Duration(seconds: 10));
      final tracks = cc.tracks.toList();
      final spoken = tracks.where((t) => t.isAutoGenerated).firstOrNull?.language.code;
      final pick = tracks.where((t) => !t.isAutoGenerated && t.language.code.startsWith('en')).firstOrNull ??
          tracks.where((t) => t.isAutoGenerated).firstOrNull ??
          tracks.firstOrNull;
      if (pick == null) return (const <String>[], spoken);
      final track = await _yt.videos.closedCaptions.get(pick).timeout(const Duration(seconds: 10));
      return ([for (final c in track.captions) c.text.trim()].where((l) => l.isNotEmpty).toList(), spoken);
    } catch (_) {
      return (const <String>[], null); // no captions: the speech is checked with the probe
    }
  }

  @override
  Future<String?> downloadAudioClip(String youtubeId, {Duration length = const Duration(seconds: 30)}) async {
    final manifest = await _yt.videos.streams.getManifest(youtubeId);
    final audio = manifest.audioOnly.toList()..sort((a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond));
    if (audio.isEmpty) return null;
    final stream = audio.first; // lowest bitrate is plenty for language ID
    // bytes for `length` at this bitrate, plus headroom for the container header
    final wanted = (stream.bitrate.bitsPerSecond / 8 * (length.inSeconds + 5)).round() + 64 * 1024;
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'probe_$youtubeId.${stream.container.name}'));
    final sink = file.openWrite();
    var got = 0;
    try {
      await for (final chunk in _yt.videos.streams.get(stream)) {
        sink.add(chunk);
        got += chunk.length;
        if (got >= wanted) break;
      }
    } finally {
      await sink.close();
    }
    return got > 0 ? file.path : null;
  }

  void close() => _yt.close();
}

/// Whisper tiny (multilingual) on-device. Transcribes with `lang: 'auto'` so the
/// text comes back in the spoken language; Gate 3 then language-IDs that text.
/// The model (~75 MB) downloads once on first use.
class WhisperSpeechProbe implements SpeechLanguageProbe {
  final _controller = WhisperController();

  @override
  Future<String?> transcribeClip(String audioFilePath) async {
    try {
      final result = await _controller.transcribe(model: WhisperModel.tiny, audioPath: audioFilePath, lang: 'auto');
      return result?.transcription.text;
    } finally {
      unawaited(File(audioFilePath).delete().then((_) {}, onError: (_) {}));
    }
  }
}
