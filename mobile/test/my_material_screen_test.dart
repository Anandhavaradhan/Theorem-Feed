import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/services/gates.dart';
import 'package:material_ui/material_ui.dart';
import 'package:theoremfeed/core/i18n.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/providers/providers.dart';
import 'package:theoremfeed/screens/my_material_screen.dart';
import 'package:theoremfeed/services/feed_service.dart';
import 'package:theoremfeed/services/graph_seed.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/material/pdf_text.dart';
import 'package:theoremfeed/services/youtube_source.dart';

import 'support/sample_chapter.dart';

class _Pdf implements PdfTextSource {
  @override
  Future<List<String>> pages(String filePath) async => sampleChapterPages;
}

class _NoConcepts implements JsonModel {
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
          required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async =>
      system == titleBatchSystemPrompt
          ? {'keep': [for (var i = 1; i <= 10; i++) '$i'], 'unsafe': <String>[], 'not_english': <String>[]}
          : system == titleCheckSystemPrompt
          ? {'on_topic': true, 'safe': true, 'english': true}
          : {'concepts': <Object>[], 'taught': <Object>[], 'mentioned': <Object>[]};
}

class _Source implements VideoSource {
  final queries = <String>[];
  @override
  Future<List<CandidateVideo>> search(String query, {int limit = 8}) async {
    queries.add(query);
    return const [];
  }

  @override
  Future<VideoDetails> details(String id, {bool needVertical = true}) => throw StateError('unused');
  @override
  Future<String?> downloadAudioClip(String id, {Duration length = const Duration(seconds: 30)}) async => null;
}

void main() {
  setUp(() => Strings.debugSet({
        for (final e in (jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>).entries)
          e.key: e.value as String,
      }));

  testWidgets('upload → listed with concepts → Path A starts → archive reverts the feed', (tester) async {
    final db = AppDatabase.inMemory();
    loadGraphSeed(db, File('assets/graph/graph_seed_v1.json').readAsStringSync());
    final pdf = File('${Directory.systemTemp.createTempSync('tf').path}/Calc Ch7.pdf')..writeAsStringSync('%PDF');
    final source = _Source();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        pdfTextSourceProvider.overrideWithValue(_Pdf()),
        pdfPickerProvider.overrideWithValue(() async => pdf.path),
        modelLoaderProvider.overrideWithValue((onProgress) async => onProgress(1)),
        jsonModelProvider.overrideWithValue(_NoConcepts()),
        videoSourceProvider.overrideWithValue(source),
        speechProbeProvider.overrideWithValue(null),
      ],
      child: const MaterialApp(home: MyMaterialScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('No material yet'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Upload PDF'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.text('Calc Ch7'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\b([2-9]|\d\d) concepts')), findsWidgets); // headings + labelled blocks
    expect(find.textContaining('Studying now'), findsOneWidget);
    // §6.4 step 5: scoped ingestion ran for the new concepts.
    // Searches carry the chapter: "Techniques of Integration".
    expect(source.queries, containsAll(['Integration by Parts IBP techniques', 'Partial Fractions partial fraction decomposition techniques integration']));
    expect(FeedService(db).longform().needsUpload, isFalse);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(find.text('Archived'), findsOneWidget);
    expect(FeedService(db).longform().needsUpload, isTrue);
  });
}

