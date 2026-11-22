import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:theoremfeed/core/i18n.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/providers/providers.dart';
import 'package:theoremfeed/screens/home_screen.dart';
import 'package:theoremfeed/services/feed_service.dart';
import 'support/seed_phase_a.dart';

Widget _app(AppDatabase db) => ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: HomeScreen()),
    );

void main() {
  setUp(() => Strings.debugSet({
        'home.title': 'Your study feed',
        'home.empty.title': 'Upload your material',
        'gap.title': 'No videos yet: {concept}',
        'gap.find': 'Find videos for this concept',
        'card.duration': '{min} min',
      }));

  testWidgets('empty on-device library shows the upload state, never a fallback feed', (tester) async {
    await tester.pumpWidget(_app(AppDatabase.inMemory()));
    await tester.pumpAndSettle();
    expect(find.text('Upload your material'), findsOneWidget);
  });

  testWidgets('seeded library shows the 5 videos, YouTube-style, from the local database', (tester) async {
    final db = AppDatabase.inMemory();
    expect(seedPhaseA(db), isTrue);
    expect(seedPhaseA(db), isFalse); // idempotent
    db.execute("UPDATE videos SET channel = '3Blue1Brown' WHERE title = 'The essence of calculus'");
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    expect(find.text('The essence of calculus'), findsOneWidget);
    expect(find.text('3Blue1Brown'), findsOneWidget); // the channel under the title, as on YouTube
    // The concept each video belongs to stays out of the feed (watch page and ⋮ menu show it).
    expect(find.textContaining('From your material'), findsNothing);
    expect(find.text('17:00'), findsOneWidget); // duration badge
    expect(FeedService(db).longform().items.map((c) => c.reasonLabel).toSet().length, 5);
  });

  testWidgets('a concept with no videos gets no card on Home: recommendations only', (tester) async {
    final db = AppDatabase.inMemory();
    seedPhaseA(db);
    db.execute("UPDATE videos SET status = 'rejected_lang' WHERE source_id = 'WUvTyaaNkzM'");
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    expect(find.text('No videos yet: Definite Integral'), findsNothing);
    expect(FeedService(db).longform().coverageGaps.map((g) => g.concept), contains('Definite Integral')); // still tracked
  });
}
