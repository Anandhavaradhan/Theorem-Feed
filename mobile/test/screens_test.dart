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
import 'package:theoremfeed/services/api_key_store.dart';
import 'package:theoremfeed/services/graph_seed.dart';

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
      'ingest.needs_key': 'Add your Claude API key in Settings first.',
    });
    db = AppDatabase.inMemory();
    loadGraphSeed(db, File(graphSeedAsset).readAsStringSync());
  });

  Widget app(Widget home, {ApiKeyStore? keys}) => ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          apiKeyStoreProvider.overrideWithValue(keys ?? MemoryApiKeyStore()),
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

  testWidgets('Find some without an API key explains what to do (no network calls)', (tester) async {
    await tester.pumpWidget(app(ConceptDetailScreen(conceptId: id('Pythagorean Theorem'))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find some'));
    await tester.pumpAndSettle();
    expect(find.text('Add your Claude API key in Settings first.'), findsOneWidget);
  });

  testWidgets('out-of-scope concept offers no ingestion', (tester) async {
    final v = addVideo(db, 'x');
    tag(db, v, id('Laplace Transform'));
    await tester.pumpWidget(app(ConceptDetailScreen(conceptId: id('Laplace Transform'))));
    await tester.pumpAndSettle();
    expect(find.text('Find some'), findsNothing);
    expect(find.text('Not in scope'), findsOneWidget);
  });
}
