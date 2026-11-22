import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/feed_service.dart';
import 'package:theoremfeed/services/gates.dart';
import 'package:theoremfeed/services/ingestion_service.dart';
import 'package:theoremfeed/services/youtube_source.dart';

import 'support/factories.dart';

const _en = [
  'so in this video we are going to look at integration by parts',
  'which is a technique for integrating a product of two functions',
  'the idea comes from the product rule for derivatives',
  'if we take u times v and differentiate we get u prime v plus u v prime',
];

class FakeSource implements VideoSource {
  final results = <String, List<CandidateVideo>>{};
  final details_ = <String, VideoDetails>{};
  final detailCalls = <String>[];
  final queries = <String>[];

  void add(String query, String id,
      {String title = 'Integration by parts explained', int duration = 600, bool vertical = false,
      List<String> transcript = _en, String description = 'A calculus lesson.', String channel = 'Some Channel'}) {
    (results[query] ??= [])
        .add(CandidateVideo(id: id, title: title, description: description, durationSec: duration, channel: channel));
    details_[id] = VideoDetails(title: title, description: description, durationSec: duration,
        thumbnailUrl: 'https://i.ytimg.com/vi/$id/hqdefault.jpg', transcriptLines: transcript, isVertical: vertical,
        channel: channel);
  }

  @override
  Future<List<CandidateVideo>> search(String query, {int limit = 8}) async {
    queries.add(query);
    return (results[query] ?? []).take(limit).toList();
  }

  @override
  Future<VideoDetails> details(String id, {bool needVertical = true}) async {
    detailCalls.add(id);
    return details_[id]!;
  }

  @override
  Future<String?> downloadAudioClip(String id, {Duration length = const Duration(seconds: 30)}) async => '/tmp/$id.m4a';
}

class FakeModel implements JsonModel {
  final edu = <String, Map<String, dynamic>>{}; // keyed by title
  final unsafeTitles = <String>{};
  int calls = 0;
  Object? throwOnCall;

  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
      required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async {
    calls++;
    if (throwOnCall != null) throw throwOnCall!;
    expect(system, videoCheckSystemPrompt);
    final text = (content.single as TextContent).text;
    final title = RegExp(r'^Title: (.*)$', multiLine: true).firstMatch(text)!.group(1)!;
    return edu[title] ??
        {'educational': true, 'safe': !unsafeTitles.contains(title), 'reason': 'teaches it', 'subject': 'math',
         'is_theorem': false, 'primary_concepts': ['Integration by Parts'], 'text_language': 'en'};
  }
}

class FakeProbe implements SpeechLanguageProbe {
  FakeProbe(this.text);
  final String? text;
  @override
  Future<String?> transcribeClip(String path) async => text;
}

void main() {
  late AppDatabase db;
  late FakeSource src;
  late FakeModel model;
  late String ibp, laplace;

  setUp(() {
    db = AppDatabase.inMemory();
    src = FakeSource();
    model = FakeModel();
    ibp = addConcept(db, 'Integration by Parts');
    db.execute("UPDATE concepts SET aliases = '[\"IBP\"]' WHERE id = ?", [ibp]);
    addConcept(db, 'Pythagorean Theorem', pool: true, poolOrder: 1);
    laplace = addConcept(db, 'Laplace Transform');
    final m = addMaterial(db);
    addMaterialConcept(db, m, ibp, importance: 0.9);
    recomputeUserActiveConcepts(db);
  });

  IngestionService svc({SpeechLanguageProbe? probe}) =>
      IngestionService(db: db, source: src, model: model, speechProbe: probe);

  String status(String yt) => db.select('SELECT status FROM videos WHERE source_id = ?', [yt]).firstOrNull?['status'] as String? ?? '-';
  String outcome(String yt) => db.select('SELECT outcome FROM ingest_log WHERE source_id = ?', [yt]).first['outcome'] as String;

  test('Path A accepts an in-scope video; it fills the feed and closes the coverage gap', () async {
    src.add('Integration by Parts IBP', 'good1');
    expect(FeedService(db).longform().coverageGaps.map((g) => g.concept), ['Integration by Parts']);

    final r = await svc().ingestMaterialConcept(ibp);
    expect(r.accepted, 1);
    expect(status('good1'), 'active');
    expect(outcome('good1'), 'accepted');
    final feed = FeedService(db).longform();
    expect(feed.items.single.reasonLabel, 'From your material: Integration by Parts');
    expect(feed.coverageGaps, isEmpty);
  });

  test('refuses to ingest outside the two paths', () async {
    expect(() => svc().ingestMaterialConcept(laplace), throwsA(isA<OutOfScopeIngestion>()));
    expect(() => svc().ingestPoolTheorem(ibp), throwsA(isA<OutOfScopeIngestion>()));
    expect(() => svc().ingestForConcept(laplace), throwsA(isA<OutOfScopeIngestion>()));
    expect(src.queries, isEmpty);
  });

  test('cheap local gates reject before any API call or detail fetch', () async {
    const q = 'Integration by Parts IBP';
    src.add(q, 'hindi', title: 'आंशिक समाकलन की विधि को समझें');
    src.add(q, 'nsfw', title: 'Integration by parts NSFW edition');
    await svc().ingestMaterialConcept(ibp);
    expect(status('hindi'), 'rejected_lang');
    expect(status('nsfw'), 'rejected_safety');
    expect(model.calls, 0);
    expect(src.detailCalls, isEmpty);
  });

  test('Gate 3 on transcript and Whisper fallback', () async {
    const q = 'Integration by Parts IBP';
    src.add(q, 'es', transcript: [
      'en este video vamos a estudiar la integración por partes',
      'que es una técnica para integrar el producto de dos funciones',
      'la idea viene de la regla del producto para las derivadas',
    ]);
    src.add(q, 'silent1', title: 'IBP in 10 minutes', transcript: const []);
    await svc(probe: FakeProbe('इस वीडियो में हम आंशिक समाकलन के बारे में पढ़ेंगे यह दो फलनों के गुणनफल')).ingestMaterialConcept(ibp);
    expect(status('es'), 'rejected_lang');
    expect(status('silent1'), 'rejected_lang');
    expect(model.calls, 0);

    src.add(q, 'silent2', title: 'IBP worked example', transcript: const []);
    await svc(probe: FakeProbe(_en.join(' '))).ingestMaterialConcept(ibp);
    expect(status('silent2'), 'active');
  });

  test('no transcript and no probe → cannot verify English → reject', () async {
    src.add('Integration by Parts IBP', 'silent', transcript: const []);
    await svc().ingestMaterialConcept(ibp);
    expect(status('silent'), 'rejected_lang');
  });

  test('model gates: educational, safety, language, and scope', () async {
    const q = 'Integration by Parts IBP';
    src.add(q, 'vlog', title: 'My study vlog');
    model.edu['My study vlog'] = {'educational': false, 'safe': true, 'reason': 'vlog', 'subject': 'other',
      'is_theorem': false, 'primary_concepts': <String>[], 'text_language': 'en'};
    src.add(q, 'hinglish', title: 'Integration by parts kaise karte hain');
    model.edu['Integration by parts kaise karte hain'] = {'educational': true, 'safe': true, 'reason': 'x',
      'subject': 'math', 'is_theorem': false, 'primary_concepts': ['Integration by Parts'], 'text_language': 'hi'};
    src.add(q, 'unsafe', title: 'IBP trick');
    model.unsafeTitles.add('IBP trick');
    src.add(q, 'offtopic', title: 'Laplace transforms explained');
    model.edu['Laplace transforms explained'] = {'educational': true, 'safe': true, 'reason': 'x', 'subject': 'math',
      'is_theorem': false, 'primary_concepts': ['Laplace Transform'], 'text_language': 'en'};

    final r = await IngestionService(db: db, source: src, model: model, acceptPerConcept: 5).ingestMaterialConcept(ibp);
    expect(status('vlog'), 'rejected_edu');
    expect(status('hinglish'), 'rejected_lang');
    expect(status('unsafe'), 'rejected_safety');
    expect(outcome('offtopic'), 'rejected_scope');
    expect(status('offtopic'), '-'); // scope rejects never enter the library
    expect(r.accepted, 0);
  });

  test('Path B: pool shorts only — prefilter, vertical theorem short accepted, re-run skips seen', () async {
    const q = 'Pythagorean Theorem #shorts';
    final pythEdu = {'educational': true, 'safe': true, 'reason': 'proof', 'subject': 'math', 'is_theorem': true,
      'primary_concepts': ['Pythagorean theorem'], 'text_language': 'en'};
    src.add(q, 'long', title: 'Pythagoras full lecture', duration: 1800);
    src.add(q, 'wide', title: 'Pythagoras proof (landscape)', duration: 50, vertical: false);
    model.edu['Pythagoras proof (landscape)'] = pythEdu;
    src.add(q, 'short', title: 'Pythagoras in 45 seconds', duration: 45, vertical: true);
    model.edu['Pythagoras in 45 seconds'] = pythEdu;

    final r = await svc().buildTheoremPool();
    expect(outcome('long'), 'rejected_format');
    expect(src.detailCalls, isNot(contains('long')));
    expect(outcome('wide'), 'rejected_format');
    expect(status('short'), 'active');
    expect(r.accepted, 1);
    final v = db.select("SELECT * FROM videos WHERE source_id = 'short'").first;
    expect([v['is_short'], v['in_theorem_pool'], v['subject']], [1, 1, 'math']);

    // Cold-start shorts now come from the pool (material has no shorts).
    final shorts = FeedService(db).shorts().items;
    expect(shorts.single.reasonLabel, 'Math theorem: Pythagorean Theorem');

    final calls = model.calls;
    await svc().buildTheoremPool();
    expect(model.calls, calls); // nothing re-classified
  });

  test('trusted channel covering the concept is accepted by rule, without the model', () async {
    src.add('Integration by Parts IBP', 'khan', title: 'Integration by parts | Khan Academy', channel: 'Khan Academy');
    // A trusted channel video that is NOT about the concept still goes to the model.
    src.add('Integration by Parts IBP', 'khan2', title: 'Limits intro', channel: 'Khan Academy',
        transcript: const ['today we look at limits of functions as x approaches a value', 'and why they matter']);
    model.edu['Limits intro'] = {'educational': true, 'safe': true, 'reason': 'limits', 'subject': 'math',
      'is_theorem': false, 'primary_concepts': ['Limit of a Function'], 'text_language': 'en'};
    final r = await IngestionService(db: db, source: src, model: model, acceptPerConcept: 5).ingestMaterialConcept(ibp);
    expect(status('khan'), 'active');
    expect(outcome('khan2'), 'rejected_scope');
    expect(model.calls, 1); // only the off-topic one
    expect(r.accepted, 1);
  });

  test('model paraphrasing the concept still counts when the video plainly covers it', () async {
    src.add('Integration by Parts IBP', 'para', title: 'Integration by parts: 5 examples');
    model.edu['Integration by parts: 5 examples'] = {'educational': true, 'safe': true, 'reason': 'x',
      'subject': 'math', 'is_theorem': false, 'primary_concepts': ['integrating products'], 'text_language': 'en'};
    expect((await svc().ingestMaterialConcept(ibp)).accepted, 1);
  });

  test('pool build can be limited to a few theorems (Shorts fills as you scroll)', () async {
    addConcept(db, 'Euler Identity', pool: true, poolOrder: 2);
    await svc().buildTheoremPool(maxTheorems: 1);
    expect(src.queries, ['Pythagorean Theorem #shorts']);
  });

  test('a fatal model error stops the run instead of logging every candidate as an error', () async {
    src.add('Integration by Parts IBP', 'a');
    model.throwOnCall = ModelApiError(401, 'authentication_error', 'invalid x-api-key', isAuth: true);
    expect(svc().ingestMaterialConcept(ibp), throwsA(isA<ModelApiError>()));
  });

  test('other API errors are logged and the run continues', () async {
    src.add('Integration by Parts IBP', 'a');
    model.throwOnCall = ModelApiError(500, 'api_error', 'boom');
    final r = await svc().ingestMaterialConcept(ibp);
    expect(r.errors, hasLength(1));
    expect(outcome('a'), 'error');

    model.throwOnCall = null; // transient errors are retried next run
    expect((await svc().ingestMaterialConcept(ibp)).accepted, 1);
    expect(outcome('a'), 'accepted');
  });
}
