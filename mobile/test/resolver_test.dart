import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/resolver.dart';

final _exp = DateTime.utc(2100).millisecondsSinceEpoch ~/ 1000;
Uri _u(String name, {int? expire}) => Uri.parse('https://rr1.googlevideo.com/$name?expire=${expire ?? _exp}');

RawExtraction _sample({int? expire}) => RawExtraction(
      title: 'The essence of calculus',
      description: 'd',
      duration: const Duration(seconds: 1022),
      thumbnail: 'thumb',
      streams: [
        RawStream(kind: RawKind.muxed, url: _u('m360', expire: expire), width: 640, height: 360,
            codec: 'avc1.42001E', container: 'mp4', bitrate: 500000),
        RawStream(kind: RawKind.videoOnly, url: _u('v1080vp9'), width: 1920, height: 1080,
            codec: 'vp9', container: 'webm', bitrate: 3000000),
        RawStream(kind: RawKind.videoOnly, url: _u('v1080avc'), width: 1920, height: 1080,
            codec: 'avc1.640028', container: 'mp4', bitrate: 2500000),
        RawStream(kind: RawKind.videoOnly, url: _u('v720vp9'), width: 1280, height: 720,
            codec: 'vp9', container: 'webm', bitrate: 1500000),
        RawStream(kind: RawKind.videoOnly, url: _u('v360avc'), width: 640, height: 360,
            codec: 'avc1.4d401e', container: 'mp4', bitrate: 400000),
        RawStream(kind: RawKind.audioOnly, url: _u('opus'), codec: 'opus', container: 'webm', bitrate: 160000),
        RawStream(kind: RawKind.audioOnly, url: _u('aac'), codec: 'mp4a.40.2', container: 'mp4', bitrate: 128000),
      ],
      captions: [
        RawCaption(url: Uri.parse('https://x/de.vtt'), languageCode: 'de', isAuto: false),
        RawCaption(url: Uri.parse('https://x/auto-en.vtt'), languageCode: 'en', isAuto: true),
        RawCaption(url: Uri.parse('https://x/en-us.vtt'), languageCode: 'en-US', isAuto: false),
      ],
    );

class _FakeExtractor implements StreamExtractor {
  _FakeExtractor(this.result);
  RawExtraction Function() result;
  final calls = <String>[];
  @override
  Future<RawExtraction> extract(String youtubeId) async {
    calls.add(youtubeId);
    return result();
  }
}

final _now = DateTime.utc(2026, 11, 22, 12);

void main() {
  test('options: H.264 preferred per height, paired with AAC; 360p uses the muxed stream', () {
    final opts = buildOptions(_sample().streams);
    expect(opts.map((o) => o.quality), ['1080p', '720p', '360p']);
    expect(opts[0].videoUrl, contains('v1080avc'));
    expect(opts[0].audioUrl, contains('aac'));
    expect(opts[1].videoUrl, contains('v720vp9')); // only option at 720p
    expect(opts[2].isMuxed, isTrue);
    expect(opts[2].videoUrl, contains('m360'));
  });

  test('english captions only, manual before auto', () {
    final caps = englishCaptions(_sample().captions);
    expect(caps.map((c) => c.url), ['https://x/en-us.vtt', 'https://x/auto-en.vtt']);
  });

  test('expiry is 6h unless a stream URL expires sooner', () {
    expect(buildResolved('v', _sample(), now: _now).expiresAt, _now.add(const Duration(hours: 6)));
    final soon = _now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
    expect(buildResolved('v', _sample(expire: soon), now: _now).expiresAt, _now.add(const Duration(minutes: 50)));
  });

  test('pickOption: starts at 720p at most (fast start), lower on small screens', () {
    final r = buildResolved('v', _sample(), now: _now);
    expect(r.pickOption(1752).quality, '720p'); // a tablet: 720p to start, higher in the menu
    expect(r.pickOption(1080, startCap: 1080).quality, '1080p');
    expect(r.pickOption(900).quality, '720p');
    expect(r.pickOption(200).quality, '360p');
    expect(r.options.map((o) => o.quality), contains('1080p'));
    expect(r.isVertical, isFalse);
  });

  group('Resolver', () {
    late AppDatabase db;
    setUp(() {
      db = AppDatabase.inMemory();
      db.execute(
          "INSERT INTO videos (id, source, source_id, title, created_at, status) VALUES ('v1','youtube','WUvTyaaNkzM','t',0,'active'),('v2','youtube','rej','t',0,'rejected_lang')");
    });

    test('caches in SQLite; second call does not hit YouTube', () async {
      final ex = _FakeExtractor(_sample);
      final r = Resolver(db, ex, clock: () => _now);
      final a = await r.resolve('v1');
      final b = await r.resolve('v1');
      expect(ex.calls, ['WUvTyaaNkzM']);
      expect(b.toJson(), a.toJson());
    });

    test('fills in title, duration and thumbnail from the library (only streams are fetched)', () async {
      db.execute("UPDATE videos SET title = 'Echo explained', duration_sec = 300, thumbnail_url = 'th' WHERE id = 'v1'");
      final streamsOnly = _sample();
      final r = Resolver(db, _FakeExtractor(() => RawExtraction(title: '', description: '', duration: null,
          thumbnail: null, streams: streamsOnly.streams, captions: const [])), clock: () => _now);
      final v = await r.resolve('v1');
      expect([v.title, v.durationSec, v.thumbnail], ['Echo explained', 300, 'th']);
      expect(v.captions, isEmpty); // no captions in time: the video still plays
    });

    test('expired cache is refreshed', () async {
      final ex = _FakeExtractor(_sample);
      var t = _now;
      final r = Resolver(db, ex, clock: () => t);
      await r.resolve('v1');
      t = _now.add(const Duration(hours: 7));
      await r.resolve('v1');
      expect(ex.calls.length, 2);
    });

    test('only library videos are playable', () async {
      final r = Resolver(db, _FakeExtractor(_sample));
      expect(r.resolve('v2'), throwsA(isA<ResolveFailed>()));
      expect(r.resolve('unknown'), throwsA(isA<ResolveFailed>()));
    });

    test('extractor errors map to the retry contract', () async {
      final r = Resolver(db, _FakeExtractor(() => throw StateError('blocked')));
      await expectLater(
        r.resolve('v1'),
        throwsA(isA<ResolveFailed>().having((e) => e.retryAfterSec, 'retryAfterSec', 30)),
      );
    });
  });
}
