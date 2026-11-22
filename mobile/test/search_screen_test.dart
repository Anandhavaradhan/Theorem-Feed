import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:theoremfeed/core/i18n.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/providers/providers.dart';
import 'package:theoremfeed/screens/search_screen.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/graph_seed.dart';

import 'support/factories.dart';

void main() {
  late AppDatabase db;
  setUp(() {
    Strings.debugSet({
      for (final e in (jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>).entries)
        e.key: e.value as String,
    });
    db = AppDatabase.inMemory();
    loadGraphSeed(db, File('assets/graph/graph_seed_v1.json').readAsStringSync());
  });

  String cid(String n) => db.select('SELECT id FROM concepts WHERE canonical_name = ?', [n]).first['id'] as String;

  Future<void> type(WidgetTester tester, String q) async {
    await tester.enterText(find.byType(TextField), q);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  testWidgets('grouped results, out-of-scope card with theorem-pool fallback, no-material notice', (tester) async {
    final m = addMaterial(db);
    addMaterialConcept(db, m, cid('Integration by Parts'));
    recomputeUserActiveConcepts(db);
    final v = addVideo(db, 'ibp');
    db.execute("UPDATE videos SET title = 'Integration by parts explained' WHERE id = ?", [v]);
    tag(db, v, cid('Integration by Parts'));

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: SearchScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Search what you\'re studying'), findsOneWidget);

    await type(tester, 'integraton by part');
    expect(find.text('Integration by Parts'), findsOneWidget); // group header
    expect(find.textContaining('From your material: Integration by Parts'), findsWidgets);
    expect(find.text('Integration by parts explained'), findsOneWidget);

    await type(tester, 'chocolate cake recipe');
    expect(find.textContaining('Not in your material'), findsOneWidget);
    await tester.tap(find.text('Search theorem pool instead'));
    await tester.pumpAndSettle();
    expect(find.text('Showing theorem-pool results only.'), findsOneWidget);
    expect(find.textContaining('No theorem-pool shorts match'), findsOneWidget);
  });

  testWidgets('no active material shows the theorem-pool-only notice', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: SearchScreen()),
    ));
    await tester.pumpAndSettle();
    await type(tester, 'taylor series');
    expect(find.textContaining('No active material'), findsOneWidget);
  });
}
