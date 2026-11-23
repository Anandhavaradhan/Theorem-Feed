import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/ingestion_service.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/youtube_source.dart';

import 'ingestion_test.dart' show FakeModel;
import 'support/factories.dart';

const _en = [
  'so in this video we are going to look at integration by parts',
  'which is a technique for integrating a product of two functions',
  'the idea comes from the product rule for derivatives',
];

/// Each details() call takes 100 ms; records concurrency and needVertical.
class SlowSource implements VideoSource {
  SlowSource(this.n, {this.duration = 600});
  final int n;
  final int duration;
  int inFlight = 0, maxInFlight = 0;
  final needVertical = <bool>[];

  @override
  Future<List<CandidateVideo>> search(String query, {int limit = 8, bool shortOnly = false}) async => [
        for (var i = 0; i < n; i++)
          CandidateVideo(id: 'v$i', title: 'Integration by parts example $i', description: 'calculus', durationSec: duration),
      ];

  @override
  Future<VideoDetails> details(String id, {bool needVertical = true}) async {
    this.needVertical.add(needVertical);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    inFlight--;
    return VideoDetails(title: 'Integration by parts example ${id.substring(1)}', description: 'calculus',
        durationSec: duration, thumbnailUrl: 't', transcriptLines: _en, isVertical: false);
  }

  @override
  Future<String?> downloadAudioClip(String id, {Duration length = const Duration(seconds: 30)}) async => null;
}

/// A model that takes 100 ms per check, like a small on-device model.
class SlowModel implements JsonModel {
  final inner = FakeModel();
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
      required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return inner.generateJson(system: system, content: content, schema: schema);
  }
}

void main() {
  late AppDatabase db;
  late String ibp;
  setUp(() {
    db = AppDatabase.inMemory();
    ibp = addConcept(db, 'Integration by Parts');
    final m = addMaterial(db);
    addMaterialConcept(db, m, ibp, importance: 0.9);
    recomputeUserActiveConcepts(db);
  });

  test('details for upcoming candidates download in parallel; long videos skip the stream list', () async {
    final src = SlowSource(6);
    final svc = IngestionService(db: db, source: src, model: SlowModel(), acceptPerConcept: 6);
    final sw = Stopwatch()..start();
    final r = await svc.ingestMaterialConcept(ibp);
    sw.stop();
    expect(r.accepted, 6);
    expect(src.maxInFlight, greaterThan(1)); // prefetching overlapped
    expect(src.needVertical, everyElement(isFalse)); // 10-minute videos can't be shorts
    // Sequential would be 6 × (100 ms details + 100 ms model) = 1.2 s.
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('candidates up to 3 minutes look up their orientation (long ones don\'t)', () async {
    final src = SlowSource(2, duration: 120);
    await IngestionService(db: db, source: src, model: SlowModel()).ingestMaterialConcept(ibp);
    expect(src.needVertical, everyElement(isTrue));
  });

  test('a short: vertical or tagged #shorts, up to 3 minutes; a short landscape clip is not one', () {
    expect(looksLikeShort(45, 'Echo in 45 seconds', vertical: false), isFalse); // would be cut off full-screen
    expect(looksLikeShort(45, 'Echo in 45 seconds', vertical: true), isTrue);
    expect(looksLikeShort(150, 'Echo explained #shorts', vertical: false), isTrue);
    expect(looksLikeShort(150, 'Echo explained', vertical: true), isTrue);
    expect(looksLikeShort(600, 'Echo #shorts', vertical: true), isFalse);
    expect(needsOrientation(45, 'x'), isTrue);
    expect(needsOrientation(45, 'x #shorts'), isFalse);
    expect(needsOrientation(600, 'x'), isFalse);
  });
}
