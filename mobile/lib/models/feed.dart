/// Wire models for /feed/* (see backend app/schemas.py).
class FeedCard {
  FeedCard({
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.durationSec,
    required this.isShort,
    required this.conceptId,
    required this.conceptName,
    required this.reasonKind,
    required this.reasonLabel,
  });

  final String videoId;
  final String title;
  final String? thumbnailUrl;
  final int? durationSec;
  final bool isShort;
  final String conceptId;
  final String conceptName;
  final String reasonKind; // 'material' | 'theorem'
  final String reasonLabel; // mandatory on every card

  factory FeedCard.fromJson(Map<String, dynamic> j) => FeedCard(
        videoId: j['video_id'] as String,
        title: j['title'] as String,
        thumbnailUrl: j['thumbnail_url'] as String?,
        durationSec: j['duration_sec'] as int?,
        isShort: j['is_short'] as bool,
        conceptId: j['concept_id'] as String,
        conceptName: j['concept_name'] as String,
        reasonKind: j['reason_kind'] as String,
        reasonLabel: j['reason_label'] as String,
      );
}

class CoverageGap {
  CoverageGap({required this.conceptId, required this.concept, required this.message});

  final String conceptId;
  final String concept;
  final String message;

  factory CoverageGap.fromJson(Map<String, dynamic> j) => CoverageGap(
        conceptId: j['concept_id'] as String,
        concept: j['concept'] as String,
        message: j['message'] as String,
      );
}

class FeedResponse {
  FeedResponse({required this.items, required this.coverageGaps, required this.emptyState});

  final List<FeedCard> items;
  final List<CoverageGap> coverageGaps;
  final String? emptyState; // 'upload_material' when no active material

  bool get needsUpload => emptyState == 'upload_material';

  factory FeedResponse.fromJson(Map<String, dynamic> j) => FeedResponse(
        // A card without a reason label is never shown (constraint #14).
        items: (j['items'] as List)
            .map((e) => FeedCard.fromJson(e as Map<String, dynamic>))
            .where((c) => c.reasonLabel.trim().isNotEmpty)
            .toList(),
        coverageGaps: ((j['coverage_gaps'] as List?) ?? const [])
            .map((e) => CoverageGap.fromJson(e as Map<String, dynamic>))
            .toList(),
        emptyState: j['empty_state'] as String?,
      );
}
