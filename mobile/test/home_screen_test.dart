import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:theoremfeed/core/i18n.dart';
import 'package:theoremfeed/models/feed.dart';
import 'package:theoremfeed/providers/providers.dart';
import 'package:theoremfeed/screens/home_screen.dart';

Widget _app(FeedResponse feed) => ProviderScope(
      overrides: [longformFeedProvider.overrideWith((ref) async => feed)],
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

  testWidgets('no material shows the upload empty state, never a fallback feed', (tester) async {
    await tester.pumpWidget(_app(FeedResponse(items: [], coverageGaps: [], emptyState: 'upload_material')));
    await tester.pumpAndSettle();
    expect(find.text('Upload your material'), findsOneWidget);
  });

  testWidgets('cards show reason labels and coverage gaps are visible', (tester) async {
    await tester.pumpWidget(_app(FeedResponse(
      items: [
        FeedCard(
          videoId: 'v1', title: 'The essence of calculus', thumbnailUrl: null, durationSec: 1020,
          isShort: false, conceptId: 'c1', conceptName: 'Definite Integral', reasonKind: 'material',
          reasonLabel: 'From your material: Definite Integral',
        ),
      ],
      coverageGaps: [CoverageGap(conceptId: 'c2', concept: 'Product Rule', message: '')],
      emptyState: null,
    )));
    await tester.pumpAndSettle();
    expect(find.text('From your material: Definite Integral'), findsOneWidget);
    expect(find.text('The essence of calculus'), findsOneWidget);
    expect(find.text('17 min'), findsOneWidget);
    expect(find.text('No videos yet: Product Rule'), findsOneWidget);
  });
}
