import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:theoremfeed/core/i18n.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/providers/providers.dart';
import 'package:theoremfeed/screens/home_screen.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/feed_service.dart';

import 'support/factories.dart';

/// Two PDFs: Sound notes (3 chapters) and Light notes (2 chapters).
({AppDatabase db, Map<String, String> c}) _library() {
  final db = AppDatabase.inMemory();
  final sound = addMaterial(db, title: 'Sound notes', created: DateTime.utc(2026, 11, 1));
  final light = addMaterial(db, title: 'Light notes', created: DateTime.utc(2026, 11, 2));
  final c = <String, String>{};
  void concept(String m, String name, String chapter, int videos) {
    final id = c[name] = addConcept(db, name, subject: 'physics');
    addMaterialConcept(db, m, id, chapter: chapter);
    for (var i = 0; i < videos; i++) {
      final v = addVideo(db, '$name-$i', subject: 'physics');
      db.execute('UPDATE videos SET title = ? WHERE id = ?', ['$name lesson $i', v]);
      tag(db, v, id);
    }
  }

  concept(sound, 'Echo', '8 Reflection of sound', 5);
  concept(sound, 'Reverberation', '8 Reflection of sound', 1);
  concept(sound, 'Pitch', '6 Characteristics of sound', 2);
  concept(sound, 'Beats', '13 Resonance and beats', 0); // a coverage gap
  concept(light, 'Plane mirror', '2 Reflection', 1);
  concept(light, 'Snell\'s Law', '4 Refraction', 1);
  recomputeUserActiveConcepts(db);
  return (db: db, c: c);
}

void main() {
  test('scopes: each PDF, then its chapters in reading order, with clean labels', () {
    final lib = _library();
    final scopes = FeedService(lib.db).scopes();
    expect(scopes.map((s) => s.label), [
      'Sound notes', 'Characteristics of sound', 'Reflection of sound', 'Resonance and beats', // 6 < 8 < 13
      'Light notes', 'Reflection', 'Refraction',
    ]);
    expect(scopes.first.isMaterial, isTrue);
    expect(scopes[2].conceptIds, {lib.c['Echo'], lib.c['Reverberation']});
  });

  test('a chapter feed shows all its videos and its gaps; All stays varied', () {
    final lib = _library();
    final feed = FeedService(lib.db);
    final reflection = feed.scopes().firstWhere((s) => s.label == 'Reflection of sound');
    final chapter = feed.longform(onlyConcepts: reflection.conceptIds);
    expect(chapter.items, hasLength(6)); // all 5 Echo videos + Reverberation: no per-concept cap
    expect(chapter.items.map((i) => i.conceptName).toSet(), {'Echo', 'Reverberation'});
    expect(chapter.coverageGaps, isEmpty);

    final beats = feed.longform(onlyConcepts: feed.scopes().firstWhere((s) => s.label == 'Resonance and beats').conceptIds);
    expect(beats.items, isEmpty);
    expect(beats.coverageGaps.single.concept, 'Beats');

    // All: every PDF; at most 3 per concept up front, the rest after everything else.
    final all = feed.longform().items.map((i) => i.conceptName).toList();
    expect(all.toSet(), containsAll(['Echo', 'Pitch', 'Plane mirror', "Snell's Law"]));
    final fourthEcho = [for (var i = 0; i < all.length; i++) if (all[i] == 'Echo') i][longformPerConceptCap];
    expect(all.indexOf('Plane mirror'), lessThan(fourthEcho));
    expect(all.indexOf("Snell's Law"), lessThan(fourthEcho));
  });

  test('labels: numbers dropped, bare numbers named', () {
    expect(chapterLabel('5 Speed of sound'), 'Speed of sound');
    expect(chapterLabel('Chapter 7 Techniques of Integration'), 'Techniques of Integration');
    expect(chapterLabel('7'), 'Chapter 7');
    expect(chapterLabel('Appendix'), 'Appendix');
    expect((['10 B', '2 A', 'Intro']..sort(compareChapters)), ['2 A', '10 B', 'Intro']);
  });

  test('one PDF with one chapter: no chips', () {
    final db = AppDatabase.inMemory();
    final m = addMaterial(db);
    addMaterialConcept(db, m, addConcept(db, 'Echo'), chapter: '8 Echo');
    recomputeUserActiveConcepts(db);
    expect(FeedService(db).scopes(), isEmpty);
  });

  testWidgets('Home: All by default; a chapter chip narrows the feed; a PDF chip shows that PDF', (tester) async {
    Strings.debugSet({'home.all': 'All', 'gap.title': 'No videos yet: {concept}'});
    final lib = _library();
    tester.view.physicalSize = const Size(2400, 4000); // every chip on screen
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(lib.db)],
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Plane mirror lesson 0'), findsOneWidget); // general feed: both PDFs

    await tester.tap(find.text('Characteristics of sound'));
    await tester.pumpAndSettle();
    expect(find.text('Pitch lesson 0'), findsOneWidget);
    expect(find.text('Pitch lesson 1'), findsOneWidget);
    expect(find.text('Plane mirror lesson 0'), findsNothing);
    expect(find.textContaining('Echo lesson'), findsNothing);

    await tester.ensureVisible(find.text('Light notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light notes'));
    await tester.pumpAndSettle();
    expect(find.text('Plane mirror lesson 0'), findsOneWidget);
    expect(find.textContaining('Snell'), findsWidgets);
    expect(find.text('Pitch lesson 0'), findsNothing);

    await tester.ensureVisible(find.text('All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('Pitch lesson 0'), findsOneWidget);
  });
}
