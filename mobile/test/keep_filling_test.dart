import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/providers/providers.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/ingestion_service.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/youtube_source.dart';

import 'support/factories.dart';

/// Every query returns 8 results of its own; shorts searches return shorts.
/// With [same], every query returns the same 8 (YouTube has nothing new).
class _Source implements VideoSource {
  _Source({this.same = false, this.slow = false});
  final bool same;
  final bool slow;
  final queries = <String>[];

  bool _isShortQuery(String q) => q.contains('shorts') || q.contains('seconds');

  @override
  Future<List<CandidateVideo>> search(String query, {int limit = 8}) async {
    queries.add(query);
    final name = query.split(' ').first;
    final short = _isShortQuery(query);
    final key = same ? (short ? 's' : 'l') : '${queries.length}';
    return [
      for (var i = 0; i < limit; i++)
        CandidateVideo(id: '$name~$key~$i~${short ? 's' : 'l'}', title: '$name video', description: '',
            durationSec: short ? 50 : 600),
    ];
  }

  @override
  Future<VideoDetails> details(String id, {bool needVertical = true}) async {
    if (slow) await Future<void>.delayed(const Duration(milliseconds: 5));
    final parts = id.split('~');
    final short = parts.last == 's';
    return VideoDetails(
      title: '${parts.first} video',
      description: '',
      durationSec: short ? 50 : 600,
      thumbnailUrl: 't',
      transcriptLines: ['${parts.first} explained, with alpha, beta and gamma from the notes'],
      isVertical: short,
    );
  }

  @override
  Future<String?> downloadAudioClip(String id, {Duration length = const Duration(seconds: 30)}) async => null;
}

class _NoModel implements JsonModel {
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
          required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async =>
      throw ModelApiError(0, 'local_model', 'no model in this test');
}

void main() {
  late AppDatabase db;
  late List<String> ids;
  setUp(() {
    db = AppDatabase.inMemory();
    final m = addMaterial(db);
    ids = [for (final n in ['Alpha', 'Beta', 'Gamma']) addConcept(db, n)];
    for (final id in ids) {
      addMaterialConcept(db, m, id);
    }
    recomputeUserActiveConcepts(db);
  });

  test('a round tops up long videos and shorts separately, with new wording each round', () async {
    final src = _Source();
    final s = IngestionService(db: db, source: src, model: _NoModel());
    await s.fillConcept(ids.first, round: 1);
    expect(s.videoCounts(ids.first), (long: 3, short: 3));
    expect(src.queries, ['Alpha math', 'Alpha math #shorts']);

    await s.fillConcept(ids.first, round: 2);
    expect(s.videoCounts(ids.first), (long: 6, short: 6));
    expect(src.queries.sublist(2), ['Alpha math explained', 'Alpha math explained #shorts']);
  });

  ProviderContainer container(_Source src) => ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        modelLoaderProvider.overrideWithValue((onProgress) async => onProgress(1)),
        jsonModelProvider.overrideWithValue(_NoModel()),
        videoSourceProvider.overrideWithValue(src),
        speechProbeProvider.overrideWithValue(null),
      ]);

  test('keeps going round after round until every concept has 20 videos and 20 shorts', () async {
    final c = container(_Source());
    addTearDown(c.dispose);
    final s = IngestionService(db: db, source: _Source(), model: _NoModel());
    await c.read(ingestionControllerProvider.notifier).fillLibrary();
    for (final id in ids) {
      expect(s.videoCounts(id), (long: IngestionService.maxPerKind, short: IngestionService.maxPerKind));
    }
    expect(c.read(ingestionControllerProvider).status, IngestionStatus.done);
    expect(db.getSetting(fillResumeKey), isEmpty);
  });

  test('stops early when YouTube has nothing new', () async {
    final src = _Source(same: true);
    final c = container(src);
    addTearDown(c.dispose);
    await c.read(ingestionControllerProvider.notifier).fillLibrary();
    final s = IngestionService(db: db, source: src, model: _NoModel());
    expect(s.videoCounts(ids.first), (long: 8, short: 8)); // all YouTube had
    // It stopped one round after nothing new came back, not after all 7 rounds.
    expect(src.queries.length, lessThan(IngestionService.maxRounds * 2 * ids.length));
    expect(c.read(ingestionControllerProvider).status, IngestionStatus.done);
  });

  test('Stop pauses the rounds, also across a restart; Continue carries on', () async {
    final src = _Source(slow: true);
    final c1 = container(src);
    final ctrl = c1.read(ingestionControllerProvider.notifier);
    final run = ctrl.fillLibrary();
    for (var i = 0; i < 400 && (c1.read(ingestionControllerProvider).report?.accepted ?? 0) < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    ctrl.cancel();
    await run;
    expect(db.getSetting(fillStoppedKey), '1');
    c1.dispose();

    final c2 = container(src);
    addTearDown(c2.dispose);
    expect(c2.read(ingestionControllerProvider).status, IngestionStatus.stopped);
    expect(c2.read(ingestionControllerProvider).round, greaterThanOrEqualTo(1));
    final before = src.queries.length;
    await c2.read(ingestionControllerProvider.notifier).autoFill(); // at start-up: respects Stop
    expect(src.queries.length, before);

    await c2.read(ingestionControllerProvider.notifier).resume();
    final s = IngestionService(db: db, source: src, model: _NoModel());
    expect(s.videoCounts(ids.last), (long: IngestionService.maxPerKind, short: IngestionService.maxPerKind));
    expect(db.getSetting(fillStoppedKey), '0');
  });
}
