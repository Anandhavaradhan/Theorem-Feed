/// One way to play a video: either a muxed URL, or a video-only URL plus an
/// audio-only URL that the on-device player combines while playing.
class PlaybackOption {
  PlaybackOption({required this.quality, required this.height, required this.videoUrl, this.audioUrl});

  final String quality; // e.g. '1080p'
  final int height;
  final String videoUrl;
  final String? audioUrl; // null → muxed stream (audio included)

  bool get isMuxed => audioUrl == null;

  Map<String, Object?> toJson() =>
      {'quality': quality, 'height': height, 'video_url': videoUrl, 'audio_url': audioUrl};

  factory PlaybackOption.fromJson(Map<String, dynamic> j) => PlaybackOption(
        quality: j['quality'] as String,
        height: (j['height'] as num).toInt(),
        videoUrl: j['video_url'] as String,
        audioUrl: j['audio_url'] as String?,
      );
}

class CaptionTrack {
  CaptionTrack({required this.url, required this.isAuto});

  final String url; // WebVTT
  final bool isAuto;

  Map<String, Object?> toJson() => {'url': url, 'is_auto': isAuto};

  factory CaptionTrack.fromJson(Map<String, dynamic> j) =>
      CaptionTrack(url: j['url'] as String, isAuto: j['is_auto'] as bool);
}

class ResolvedVideo {
  ResolvedVideo({
    required this.videoId,
    required this.title,
    required this.description,
    required this.durationSec,
    required this.isVertical,
    required this.thumbnail,
    required this.options,
    required this.captions,
    required this.expiresAt,
  });

  final String videoId;
  final String title;
  final String description;
  final int? durationSec;
  final bool isVertical;
  final String? thumbnail;
  final List<PlaybackOption> options; // best first
  final List<CaptionTrack> captions; // English only; manual before auto
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {
        'video_id': videoId,
        'title': title,
        'description': description,
        'duration': durationSec,
        'is_vertical': isVertical,
        'thumbnail': thumbnail,
        'options': options.map((o) => o.toJson()).toList(),
        'captions': captions.map((c) => c.toJson()).toList(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };

  factory ResolvedVideo.fromJson(Map<String, dynamic> j) => ResolvedVideo(
        videoId: j['video_id'] as String,
        title: j['title'] as String,
        description: j['description'] as String? ?? '',
        durationSec: (j['duration'] as num?)?.toInt(),
        isVertical: j['is_vertical'] as bool? ?? false,
        thumbnail: j['thumbnail'] as String?,
        options: (j['options'] as List).map((e) => PlaybackOption.fromJson(e as Map<String, dynamic>)).toList(),
        captions: (j['captions'] as List).map((e) => CaptionTrack.fromJson(e as Map<String, dynamic>)).toList(),
        expiresAt: DateTime.parse(j['expires_at'] as String),
      );

  /// Best option whose height ≤ the device's native resolution (short side, physical px).
  /// Falls back to the smallest option if every one is larger.
  /// The quality to start with: the best that fits the screen, but at most
  /// [startCap]p (720p), as YouTube does, so playback begins quickly; higher
  /// qualities stay in the quality menu.
  PlaybackOption pickOption(int deviceShortSidePx, {int startCap = 720}) {
    final limit = deviceShortSidePx < startCap ? deviceShortSidePx : startCap;
    final fitting = options.where((o) => o.height <= limit).toList();
    return fitting.isNotEmpty ? fitting.first : options.last;
  }
}
