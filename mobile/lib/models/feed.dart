/// Feed card. Every card carries a reason label (constraint #14): no label, no card.
class FeedCard {
  FeedCard({
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.durationSec,
    required this.isShort,
    required this.conceptId,
    required this.conceptName,
    required this.fromMaterial,
    this.score,
    this.why,
  });

  final String videoId;
  final String title;
  final String? thumbnailUrl;
  final int? durationSec;
  final bool isShort;
  final String conceptId;
  final String conceptName;
  final bool fromMaterial; // false → curated math theorem pool
  final double? score;

  /// The on-device judge's short reason (e.g. "derives the formula, worked examples").
  final String? why;

  String get reasonLabel => fromMaterial ? 'From your material: $conceptName' : 'Math theorem: $conceptName';
}

/// An active concept with zero videos. Coverage gaps are never silent (#12).
class CoverageGap {
  CoverageGap({required this.conceptId, required this.concept});

  final String conceptId;
  final String concept;
}

class FeedResponse {
  FeedResponse({required this.items, this.coverageGaps = const [], this.needsUpload = false});

  final List<FeedCard> items;
  final List<CoverageGap> coverageGaps;

  /// True when there is no active material (§1, §10.4): show the upload CTA.
  final bool needsUpload;
}
