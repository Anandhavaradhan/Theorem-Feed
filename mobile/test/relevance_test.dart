import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/feed_service.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/relevance/judge.dart';
import 'package:theoremfeed/services/relevance/relevance_service.dart';
import 'package:theoremfeed/services/relevance/retrieval.dart';

import 'support/factories.dart';

/// Grades by a title → scores table; records each prompt.
class FakeJudge implements JsonModel {
  FakeJudge(this.byTitle);
  final Map<String, List<int>> byTitle; // title → [topic, level, depth, prereq]
  final prompts = <String>[];
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
      required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async {
    expect(system, judgeSystemPrompt);
    final text = (content.single as TextContent).text;
    prompts.add(text);
    final titles = RegExp(r'^\[(\d+)\] (.*) \(', multiLine: true).allMatches(text).map((m) => (m.group(1)!, m.group(2)!));
    return {
      'scores': [
        for (final (i, title) in titles)
          if (byTitle[title] case final List<int> s)
            {'video': i, 'topic_fit': s[0], 'level_fit': s[1], 'depth_fit': s[2], 'prerequisite_ok': s[3], 'reason': 'r:$title'},
      ],
    };
  }
}

String _video(AppDatabase db, String src, String title, {String transcript = '', int duration = 900}) {
  final id = addVideo(db, src);
  db.execute('UPDATE videos SET title = ?, transcript = ?, duration_sec = ? WHERE id = ?', [title, transcript, duration, id]);
  return id;
}

void main() {
  late AppDatabase db;
  late String ibp, product, laplace;

  setUp(() {
    db = AppDatabase.inMemory();
    ibp = addConcept(db, 'Integration by Parts');
    product = addConcept(db, 'Product Rule');
    laplace = addConcept(db, 'Laplace Transform');
    db.execute("INSERT INTO concept_edges VALUES (?, ?, 'requires', 1.0)", [ibp, product]);
    final m = addMaterial(db);
    addMaterialConcept(db, m, ibp, importance: 0.9,
        statement: '∫ u dv = uv − ∫ v du, a technique for integrating products of functions');
    recomputeUserActiveConcepts(db);
  });

  test('final score follows the spec weights', () {
    expect(finalRelevance(10, 10, 10, 10), 1.0);
    expect(finalRelevance(8, 6, 4, 2), closeTo((0.5 * 8 + 0.2 * 6 + 0.2 * 4 + 0.1 * 2) / 10, 1e-12));
  });

  test('Layer A: tag, statement (BM25 on transcript), and prerequisite signals, deduped', () {
    final tagged = _video(db, 't', 'IBP lecture');
    tag(db, tagged, ibp);
    final untagged = _video(db, 'u', 'Calculus 2, lecture 9',
        transcript: 'we integrate products of functions with u dv equals uv minus the integral of v du');
    final prereq = _video(db, 'p', 'The product rule');
    tag(db, prereq, product);
    final unrelated = _video(db, 'x', 'Laplace transforms', transcript: 'the laplace transform of a function');
    tag(db, unrelated, laplace);

    final ctx = conceptContext(db, ibp)!;
    expect(ctx.statement, startsWith('∫ u dv'));
    expect(ctx.prerequisiteNames, ['Product Rule']);
    expect(statementKeywords(ctx), containsAll(['integration', 'parts', 'technique', 'integrating', 'products']));

    final c = retrieveCandidates(db, ctx);
    final byId = {for (final x in c) x.videoId: x.signals};
    expect(byId[tagged], contains(Signal.tag));
    expect(byId[untagged], contains(Signal.statement));
    expect(byId[prereq], contains(Signal.prerequisite));
    expect(byId.containsKey(unrelated), isFalse);
    expect(c.first.videoId, tagged); // tag hits first
  });

  test('Layer B: batches of 4, cached, confirms strong untagged matches, hides off-topic', () async {
    final ids = <String, String>{};
    for (var i = 0; i < 6; i++) {
      ids['good$i'] = _video(db, 'g$i', 'IBP worked example $i');
      tag(db, ids['good$i']!, ibp);
    }
    ids['offtopic'] = _video(db, 'o', 'Limits explained');
    tag(db, ids['offtopic']!, ibp); // mis-tagged at ingestion
    ids['untagged'] = _video(db, 'u', 'Calc 2 lecture',
        transcript: 'integrating products of functions: u dv equals uv minus v du');

    final judge = FakeJudge({
      for (var i = 0; i < 6; i++) 'IBP worked example $i': [9 - i, 7, 7, 8],
      'Limits explained': [1, 5, 5, 5],
      'Calc 2 lecture': [8, 7, 6, 7],
    });
    final svc = RelevanceService(db, judge);
    final r = await svc.rankConcept(ibp);
    expect(r.judged, 8);
    expect(judge.prompts.length, 2); // ceil(8 / 4)
    expect(judge.prompts.first, contains('STATEMENT: ∫ u dv = uv − ∫ v du'));
    expect(judge.prompts.first, contains('PREREQUISITES: Product Rule'));
    expect(r.confirmed, 1); // the untagged lecture, topic_fit 8

    // Cached: a second pass judges nothing.
    expect((await svc.rankConcept(ibp)).judged, 0);
    expect(judge.prompts.length, 2);

    // Feed: ordered by final, off-topic hidden, confirmed untagged video included, reasons on cards.
    final feed = FeedService(db).longform(limit: 20).items;
    expect(feed.map((c) => c.videoId), isNot(contains(ids['offtopic'])));
    expect(feed.map((c) => c.videoId), contains(ids['untagged']));
    expect(feed.first.videoId, ids['good0']);
    expect(feed.first.why, 'r:IBP worked example 0');
    final scores = feed.map((c) => c.score!).toList();
    expect(scores, orderedEquals([...scores]..sort((a, b) => b.compareTo(a))));

    final ranked = svc.rankedFor(ibp);
    expect(ranked.length, 7);
    expect(ranked.map((v) => v.videoId), isNot(contains(ids['offtopic'])));
  });

  test('a concept whose only video is off-topic shows a coverage gap', () async {
    final v = _video(db, 'o', 'Limits explained');
    tag(db, v, ibp);
    await RelevanceService(db, FakeJudge({'Limits explained': [0, 5, 5, 5]})).rankConcept(ibp);
    final feed = FeedService(db).longform();
    expect(feed.items, isEmpty);
    expect(feed.coverageGaps.map((g) => g.concept), ['Integration by Parts']);
  });

  test('judge failures are counted and retried later; missing videos stay unjudged', () async {
    final v = _video(db, 'g', 'IBP worked example');
    tag(db, v, ibp);
    final svc = RelevanceService(db, FakeJudge({})); // judge omits every video
    expect((await svc.rankConcept(ibp)).judged, 0);
    final svc2 = RelevanceService(db, FakeJudge({'IBP worked example': [9, 8, 8, 8]}));
    expect((await svc2.rankConcept(ibp)).judged, 1);
  });

  test('judge prompt clips long text for the small model', () {
    final ctx = conceptContext(db, ibp)!;
    final c = Candidate(videoId: 'v', title: 'T', description: 'd' * 2000, transcript: 't' * 5000, durationSec: 300, isShort: false);
    final prompt = judgePrompt(ctx, [c, c, c, c]);
    expect(prompt.length, lessThan(3500));
    expect(prompt, contains('(5.0 min)'));
  });
}
