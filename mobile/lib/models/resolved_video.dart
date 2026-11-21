/// Wire models for GET /resolve (see backend app/services/resolver.py).
class StreamFormat {
  StreamFormat({required this.url, required this.quality, required this.mime, required this.height});

  final String url;
  final String quality;
  final String mime;
  final int height;

  bool get isHls => mime == 'application/x-mpegURL';

  factory StreamFormat.fromJson(Map<String, dynamic> j) => StreamFormat(
        url: j['url'] as String,
        quality: j['quality'] as String,
        mime: j['mime'] as String,
        height: (j['height'] as num?)?.toInt() ?? 0,
      );
}

class CaptionTrack {
  CaptionTrack({required this.kind, required this.ext, required this.url});

  final String kind; // 'manual' | 'auto'
  final String ext; // 'vtt' | 'srt'
  final String url;

  factory CaptionTrack.fromJson(Map<String, dynamic> j) =>
      CaptionTrack(kind: j['kind'] as String, ext: j['ext'] as String, url: j['url'] as String);
}

class ResolvedVideo {
  ResolvedVideo({
    required this.videoId,
    required this.title,
    required this.durationSec,
    required this.isVertical,
    required this.formats,
    required this.captions,
  });

  final String videoId;
  final String title;
  final int? durationSec;
  final bool isVertical;
  final List<StreamFormat> formats; // best first
  final List<CaptionTrack> captions;

  factory ResolvedVideo.fromJson(Map<String, dynamic> j) => ResolvedVideo(
        videoId: j['video_id'] as String,
        title: j['title'] as String,
        durationSec: (j['duration'] as num?)?.toInt(),
        isVertical: j['is_vertical'] as bool? ?? false,
        formats: (j['formats'] as List).map((e) => StreamFormat.fromJson(e as Map<String, dynamic>)).toList(),
        captions: ((j['captions'] as List?) ?? const [])
            .map((e) => CaptionTrack.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Best format whose height ≤ the device's native resolution (short side, in physical px).
  /// Falls back to the lowest available if every format is larger.
  StreamFormat pickFormat(int deviceShortSidePx) {
    final fitting = formats.where((f) => f.height > 0 && f.height <= deviceShortSidePx).toList();
    if (fitting.isNotEmpty) return fitting.first;
    final sized = formats.where((f) => f.height > 0).toList();
    return sized.isNotEmpty ? sized.last : formats.first;
  }
}
