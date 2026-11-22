import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/relevance/evaluation.dart';
import 'package:theoremfeed/services/relevance/relevance_service.dart';

import 'support/factories.dart';

class TitleJudge implements JsonModel {
  TitleJudge(this.topicFor);
  final int Function(String title) topicFor;
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
      required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async {
    final text = (content.single as TextContent).text;
    return {
      'scores': [
        for (final m in RegExp(r'^\[(\d+)\] (.*) \(', multiLine: true).allMatches(text))
          {'video': m.group(1), 'topic_fit': topicFor(m.group(2)!), 'level_fit': 7, 'depth_fit': 7,
            'prerequisite_ok': 7, 'reason': ''},
      ],
    };
  }
}

void main() {
  late AppDatabase db;
  late EvaluationService eval;
  late String c1, c2;

  /// 5 good + 5 bad tagged videos per concept, labelled; plus 2 unlabelled.
  void golden(String concept, String prefix) {
    for (var i = 0; i < 5; i++) {
      final g = addVideo(db, '$prefix-good-$i');
      db.execute('UPDATE videos SET title = ? WHERE id = ?', ['$prefix good $i', g]);
      tag(db, g, concept);
      eval.setLabel(concept, g, GoldenLabel.good);
      final b = addVideo(db, '$prefix-bad-$i');
      db.execute('UPDATE videos SET title = ? WHERE id = ?', ['$prefix bad $i', b]);
      tag(db, b, concept);
      eval.setLabel(concept, b, GoldenLabel.bad);
    }
    for (var i = 0; i < 2; i++) {
      final u = addVideo(db, '$prefix-other-$i');
      db.execute('UPDATE videos SET title = ? WHERE id = ?', ['$prefix other $i', u]);
      tag(db, u, concept);
    }
  }

  setUp(() {
    db = AppDatabase.inMemory();
    eval = EvaluationService(db);
    c1 = addConcept(db, 'Integration by Parts');
    c2 = addConcept(db, 'Partial Fractions');
    final m = addMaterial(db);
    addMaterialConcept(db, m, c1);
    addMaterialConcept(db, m, c2);
    recomputeUserActiveConcepts(db);
    golden(c1, 'ibp');
    golden(c2, 'pf');
  });

  Future<EvalReport> run(int Function(String title) topicFor) async {
    final rel = RelevanceService(db, TitleJudge(topicFor));
    for (final c in eval.labelledConcepts()) {
      await rel.rankConcept(c);
    }
    return eval.evaluate(rel);
  }

  test('labels and progress', () {
    expect(eval.progress().concepts, 2);
    expect(eval.progress().videos, 20);
    final v = addVideo(db, 'x');
    eval.setLabel(c1, v, GoldenLabel.good);
    expect(eval.labelOf(c1, v), GoldenLabel.good);
    eval.setLabel(c1, v, null);
    expect(eval.labelOf(c1, v), isNull);
  });

  test('a judge that separates good from bad passes the targets', () async {
    final r = await run((t) => t.contains('good') ? 9 : t.contains('bad') ? 1 : 6);
    expect(r.concepts, hasLength(2));
    // Bad ones are off-topic (≤2) and hidden; top 10 = 5 good + 2 unlabelled.
    expect(r.concepts.first.shown, 7);
    expect(r.precisionAt10, 1.0);
    expect(r.badRateAt10, 0.0);
    expect(r.passes, isTrue);
  });

  test('a judge that can\'t tell them apart fails', () async {
    final r = await run((t) => 6);
    expect(r.concepts.first.shown, 10);
    expect(r.precisionAt10, lessThan(precisionTarget));
    expect(r.badRateAt10, greaterThan(badRateTarget));
    expect(r.passes, isFalse);
  });

  test('archived material drops its concepts from the check', () async {
    db.execute("UPDATE materials SET status = 'archived'");
    recomputeUserActiveConcepts(db);
    expect(eval.labelledConcepts(), isEmpty);
    expect((await run((t) => 9)).precisionAt10, isNull);
  });
}
