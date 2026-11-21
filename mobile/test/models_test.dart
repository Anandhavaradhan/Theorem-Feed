import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/core/captions.dart';
import 'package:theoremfeed/models/feed.dart';
import 'package:theoremfeed/models/resolved_video.dart';

ResolvedVideo _video(List<int> heights) => ResolvedVideo.fromJson({
      'video_id': 'v',
      'title': 'T',
      'duration': 60,
      'is_vertical': false,
      'formats': [
        for (final h in heights) {'url': 'u$h', 'quality': '${h}p', 'mime': 'video/mp4', 'height': h},
      ],
      'captions': [],
    });

void main() {
  test('pickFormat chooses best quality not exceeding device resolution', () {
    final v = _video([1080, 720, 360]);
    expect(v.pickFormat(1080).quality, '1080p');
    expect(v.pickFormat(800).quality, '720p');
    expect(v.pickFormat(200).quality, '360p'); // smallest fallback
  });

  test('cards without a reason label are dropped', () {
    final f = FeedResponse.fromJson({
      'items': [
        {
          'video_id': 'a', 'title': 'A', 'thumbnail_url': null, 'duration_sec': 60, 'is_short': false,
          'concept_id': 'c', 'concept_name': 'X', 'reason_kind': 'material', 'reason_label': 'From your material: X',
        },
        {
          'video_id': 'b', 'title': 'B', 'thumbnail_url': null, 'duration_sec': 60, 'is_short': false,
          'concept_id': 'c', 'concept_name': 'X', 'reason_kind': 'material', 'reason_label': '  ',
        },
      ],
      'coverage_gaps': [],
      'empty_state': null,
    });
    expect(f.items.map((c) => c.videoId), ['a']);
  });

  test('parses WebVTT and SRT cues', () {
    const vtt = 'WEBVTT\n\n00:00:01.000 --> 00:00:02.500 align:start\n<c>Hello</c> world\n\n'
        '00:01:00.000 --> 00:01:01.000\nSecond';
    final cues = parseCaptions(vtt);
    expect(cues.length, 2);
    expect(cues[0].text, 'Hello world');
    expect(cues[0].start, const Duration(seconds: 1));
    expect(cues[0].end, const Duration(seconds: 2, milliseconds: 500));
    expect(cues[1].start, const Duration(minutes: 1));

    const srt = '1\n00:00:03,000 --> 00:00:04,000\nSRT line\n';
    expect(parseCaptions(srt).single.start, const Duration(seconds: 3));
  });
}
