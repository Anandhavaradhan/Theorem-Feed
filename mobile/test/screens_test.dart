import 'dart:io';

import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:theoremfeed/core/i18n.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/providers/providers.dart';
import 'package:theoremfeed/screens/concept_detail_screen.dart';
import 'package:theoremfeed/screens/shorts_screen.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/youtube_source.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/graph_seed.dart';
import 'package:theoremfeed/services/relevance/evaluation.dart';

import 'support/factories.dart';

void main() {
  late AppDatabase db;
  setUp(() {
    Strings.debugSet({
      'shorts.empty.title': 'No theorem shorts yet',
      'concept.no_videos': 'No videos yet',
      'concept.find': 'Find some',
      'concept.out_of_scope': 'Not in scope',
      'concept.prerequisites': 'Prerequisites',
      'ingest.done': 'Done: {accepted} added from {checked} checked.',
      'golden.good': 'Good example for this concept',
      'card.duration': '{min} min',
    });
    db = AppDatabase.inMemory();
    loadGraphSeed(db, File(graphSeedAsset).readAsStringSync());
  });

  var modelLoads = 0;
  Widget app(Widget home) => ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          modelLoaderProvider.overrideWithValue((onProgress) async {
            modelLoads++;
            onProgress(1);
          }),
          jsonModelProvider.overrideWithValue(_NoModel()),
          videoSourceProvider.overrideWithValue(_EmptySource()),
          speechProbeProvider.overrideWithValue(null),
        ],
        child: MaterialApp(home: home),
      );

  String id(String name) => db.select('SELECT id FROM concepts WHERE canonical_name = ?', [name]).first['id'] as String;

  testWidgets('shorts with an empty library shows the build-the-pool state', (tester) async {
    await tester.pumpWidget(app(const ShortsScreen(active: true)));
    await tester.pumpAndSettle();
    expect(find.text('No theorem shorts yet'), findsOneWidget);
  });

  testWidgets('concept detail renders LaTeX, prerequisites, and Find some for a pool theorem', (tester) async {
    await tester.pumpWidget(app(ConceptDetailScreen(conceptId: id('Euler\'s Identity'))));
    await tester.pumpAndSettle();
    expect(find.byType(Math), findsOneWidget);
    expect(find.text("Euler's Formula"), findsOneWidget); // direct prerequisite
    expect(find.text('No videos yet'), findsOneWidget);
    expect(find.text('Find some'), findsOneWidget);
  });

  testWidgets('Find some prepares the on-device model, then runs scoped ingestion', (tester) async {
    await tester.pumpWidget(app(ConceptDetailScreen(conceptId: id('Pythagorean Theorem'))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find some'));
    await tester.pumpAndSettle();
    expect(modelLoads, 1);
    expect(db.getSetting('local_model_ready'), '1');
    expect(find.text('Done: 0 added from 0 checked.'), findsOneWidget);
  });

  testWidgets('out-of-scope concept offers no ingestion', (tester) async {
    final v = addVideo(db, 'x');
    tag(db, v, id('Laplace Transform'));
    await tester.pumpWidget(app(ConceptDetailScreen(conceptId: id('Laplace Transform'))));
    await tester.pumpAndSettle();
    expect(find.text('Find some'), findsNothing);
    expect(find.text('Not in scope'), findsOneWidget);
  });

  testWidgets('long-press a material concept\'s video to label it for the relevance check', (tester) async {
    final ibp = id('Integration by Parts');
    final m = addMaterial(db);
    addMaterialConcept(db, m, ibp);
    recomputeUserActiveConcepts(db);
    final v = addVideo(db, 'ibp1');
    tag(db, v, ibp);

    await tester.pumpWidget(app(ConceptDetailScreen(conceptId: ibp)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Video ibp1'), 300);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Video ibp1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Good example for this concept'));
    await tester.pumpAndSettle();
    expect(EvaluationService(db).labelOf(ibp, v), GoldenLabel.good);
    expect(find.byIcon(Icons.thumb_up), findsOneWidget);
  });
}

class _NoModel implements JsonModel {
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
          required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) =>
      throw StateError('not called');
}

class _EmptySource implements VideoSource {
  @override
  Future<List<CandidateVideo>> search(String query, {int limit = 8, bool shortOnly = false}) async => const [];
  @override
  Future<VideoDetails> details(String id, {bool needVertical = true}) => throw StateError('not called');
  @override
  Future<String?> downloadAudioClip(String id, {Duration length = const Duration(seconds: 30)}) async => null;
}
