/// Layer B: LLM-as-judge re-ranking (§9.2), with the on-device model.
///
/// Videos are graded in small batches (a sub-1B model reads ~4 excerpts
/// reliably), every score is constrained to an integer 0–10 during decoding,
/// and the spec's weights combine them:
///
///   final = (0.5·topic_fit + 0.2·level_fit + 0.2·depth_fit + 0.1·prerequisite_ok) / 10
///
/// topic_fit is the disambiguator between "a video about the right topic" and
/// "a video about a mathematically adjacent topic".
library;

import '../llm.dart';
import 'retrieval.dart';

const judgeBatchSize = 4;

const judgeSystemPrompt = '''
Grade whether each video is useful for a student studying this concept. Answer with JSON only.
For each video, score 0-10:
- topic_fit: does it primarily teach THIS concept? (0 if it teaches a different but related concept)
- level_fit: is it at the right difficulty?
- depth_fit: does its depth match a section-level treatment? (penalize 3-minute overviews and 3-hour full courses)
- prerequisite_ok: does it assume only the listed prerequisites?
reason: a few words explaining the grade.''';

Map<String, Object?> judgeSchema(int n) {
  const score = {'type': 'integer', 'enum': [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]};
  return {
    'type': 'object',
    'properties': {
      'scores': {
        'type': 'array',
        'maxItems': n,
        'items': {
          'type': 'object',
          'properties': {
            'video': {'type': 'string', 'enum': [for (var i = 1; i <= n; i++) '$i']},
            'topic_fit': score,
            'level_fit': score,
            'depth_fit': score,
            'prerequisite_ok': score,
            'reason': {'type': 'string'},
          },
          'required': ['video', 'topic_fit', 'level_fit', 'depth_fit', 'prerequisite_ok', 'reason'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['scores'],
    'additionalProperties': false,
  };
}

class Judgement {
  Judgement({
    required this.videoId,
    required this.topicFit,
    required this.levelFit,
    required this.depthFit,
    required this.prerequisiteOk,
    required this.reason,
  });

  final String videoId;
  final double topicFit;
  final double levelFit;
  final double depthFit;
  final double prerequisiteOk;
  final String reason;

  double get finalScore => finalRelevance(topicFit, levelFit, depthFit, prerequisiteOk);
}

double finalRelevance(double topic, double level, double depth, double prereq) =>
    (0.5 * topic + 0.2 * level + 0.2 * depth + 0.1 * prereq) / 10;

String _clip(String s, int n) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > n ? '${t.substring(0, n)}…' : t;
}

String judgePrompt(ConceptContext c, List<Candidate> videos) {
  final b = StringBuffer()
    ..writeln('CONCEPT: ${c.name}')
    ..writeln('STATEMENT: ${_clip(c.statement, 300)}')
    ..writeln('DIFFICULTY: ${c.difficulty}')
    ..writeln('CHAPTER CONTEXT: ${[c.chapter, c.section].whereType<String>().join(' / ').ifEmpty('none')}')
    ..writeln('PREREQUISITES: ${c.prerequisiteNames.isEmpty ? 'none listed' : c.prerequisiteNames.join(', ')}')
    ..writeln()
    ..writeln('VIDEOS:');
  for (var i = 0; i < videos.length; i++) {
    final v = videos[i];
    final mins = v.durationSec == null ? '?' : (v.durationSec! / 60).toStringAsFixed(v.durationSec! < 600 ? 1 : 0);
    b
      ..writeln('[${i + 1}] ${v.title} ($mins min)')
      ..writeln('    description: ${_clip(v.description, 150)}')
      ..writeln('    transcript: ${_clip(v.transcript, 350)}');
  }
  return b.toString();
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Grades one batch. Videos the model leaves out are returned unjudged (retried later).
Future<List<Judgement>> judgeBatch(JsonModel model, ConceptContext c, List<Candidate> videos) async {
  final json = await model.generateJson(
    system: judgeSystemPrompt,
    content: [TextContent(judgePrompt(c, videos))],
    schema: judgeSchema(videos.length),
    maxTokens: 120 * videos.length + 60,
  );
  final seen = <int>{};
  final out = <Judgement>[];
  for (final s in (json['scores'] as List).cast<Map<String, dynamic>>()) {
    final i = int.tryParse('${s['video']}');
    if (i == null || i < 1 || i > videos.length || !seen.add(i)) continue;
    double score(String k) => ((s[k] as num).toDouble()).clamp(0, 10).toDouble();
    out.add(Judgement(
      videoId: videos[i - 1].videoId,
      topicFit: score('topic_fit'),
      levelFit: score('level_fit'),
      depthFit: score('depth_fit'),
      prerequisiteOk: score('prerequisite_ok'),
      reason: (s['reason'] as String).trim(),
    ));
  }
  return out;
}
