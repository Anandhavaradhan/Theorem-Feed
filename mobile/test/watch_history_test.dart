import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/concept_service.dart';
import 'package:theoremfeed/services/resolver.dart';
import 'package:theoremfeed/services/watch_history.dart';

import 'support/factories.dart';

class _Ex implements StreamExtractor {
  _Ex(this.error);
  Object? error;
  int calls = 0;
  @override
  Future<RawExtraction> extract(String youtubeId, {bool thorough = false}) async {
    calls++;
    if (error != null) throw error!;
    return RawExtraction(title: 't', description: '', duration: const Duration(seconds: 60), thumbnail: null, streams: [
      RawStream(kind: RawKind.muxed, url: Uri.parse('https://x/m?expire=4102444800'), width: 640, height: 360,
          codec: 'avc1', container: 'mp4', bitrate: 1),
    ], captions: const []);
  }
}

void main() {
  late AppDatabase db;
  late WatchHistoryService h;
  setUp(() {
    db = AppDatabase.inMemory();
    h = WatchHistoryService(db);
  });

  test('viewings: partial → resume point; 90% → completed; again → rewatch; one row per video', () {
    final v = addVideo(db, 'a');
    h.recordViewing(v, watchedSec: 0, durationSec: 600);
    expect(db.select('SELECT * FROM watch_history'), isEmpty); // nothing watched, nothing recorded
    h.recordViewing(v, watchedSec: 120, durationSec: 600);
    expect(h.isCompleted(v), isFalse);
    expect(h.resumeAt(v), 120);
    h.recordViewing(v, watchedSec: 560, durationSec: 600);
    expect(h.isCompleted(v), isTrue);
    expect(h.resumeAt(v), isNull);
    h.recordViewing(v, watchedSec: 590, durationSec: 600);
    final row = db.select('SELECT * FROM watch_history').single;
    expect([row['completed'], row['rewatched_count'], row['watched_sec']], [1, 1, 590]);
  });

  test('saving and watching share the row', () {
    final v = addVideo(db, 'a');
    ConceptService(db).toggleSaved(v);
    h.recordViewing(v, watchedSec: 58, durationSec: 60);
    final row = db.select('SELECT * FROM watch_history').single;
    expect([row['saved'], row['completed']], [1, 1]);
  });

  test('resolver: offline is reported as such; invalidate forces a fresh fetch', () async {
    final v = addVideo(db, 'yt');
    final ex = _Ex(const SocketException('Failed host lookup: www.youtube.com'));
    final r = Resolver(db, ex);
    await expectLater(r.resolve(v), throwsA(isA<ResolveFailed>().having((e) => e.offline, 'offline', isTrue)));
    ex.error = StateError('bot check');
    await expectLater(r.resolve(v), throwsA(isA<ResolveFailed>().having((e) => e.offline, 'offline', isFalse)));

    ex.error = null;
    await r.resolve(v);
    await r.resolve(v);
    expect(ex.calls, 3); // second was cached
    r.invalidate(v);
    await r.resolve(v);
    expect(ex.calls, 4);
  });
}
