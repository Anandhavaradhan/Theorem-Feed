import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/services/gates.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/providers/providers.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/background_work.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/material/pdf_text.dart';
import 'package:theoremfeed/services/youtube_source.dart';

import 'support/factories.dart';
import 'support/sample_chapter.dart';

/// Two lesson videos per concept; each detail fetch takes 20 ms.
class _Source implements VideoSource {
  final queries = <String>[];
  @override
  Future<List<CandidateVideo>> search(String query, {int limit = 8}) async {
    queries.add(query);
    final name = query.split(' ').first;
    return [
      for (var i = 0; i < 2; i++)
        CandidateVideo(id: '$name-$i', title: '$name lesson $i explained', description: '', durationSec: 600),
    ];
  }

  @override
  Future<VideoDetails> details(String id, {bool needVertical = true}) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final name = id.split('-').first;
    return VideoDetails(
      title: '$name lesson explained',
      description: '',
      durationSec: 600,
      thumbnailUrl: 't',
      // Mentions the other concepts of the notes, so the rule accepts it.
      transcriptLines: ['today we study $name in detail', 'it builds on alpha, beta and gamma from the notes'],
      isVertical: false,
    );
  }

  @override
  Future<String?> downloadAudioClip(String id, {Duration length = const Duration(seconds: 30)}) async => null;
}

class _NoModel implements JsonModel {
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
          required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async {
    // The AI reads every accepted video's title; it agrees here.
    if (system == titleCheckSystemPrompt) return {'on_topic': true, 'safe': true, 'english': true};
    if (system == titleBatchSystemPrompt) {
      return {'keep': [for (var i = 1; i <= 10; i++) '$i'], 'unsafe': <String>[], 'not_english': <String>[]};
    }
    throw ModelApiError(0, 'local_model', 'no model in this test'); // ranking skips; the rule accepts videos
  }
}

/// PDF reading that waits until the test lets it finish.
class _SlowPdf implements PdfTextSource {
  Completer<void> gate = Completer<void>();
  @override
  Future<List<String>> pages(String filePath) async {
    await gate.future;
    return sampleChapterPages;
  }
}

/// Records what the background notification would show.
class _Keeper implements BackgroundKeeper {
  final events = <String>[];
  void Function()? stopButton;
  @override
  Future<void> start({required String title, required String text, required void Function() onStop}) async {
    events.add('start: $title');
    stopButton = onStop;
  }

  @override
  Future<void> update(String text) async => events.add('update: $text');
  @override
  Future<void> stop() async => events.add('stop');
}

ProviderContainer _container(AppDatabase db, {_Source? source, PdfTextSource? pdf, BackgroundKeeper? keeper}) =>
    ProviderContainer(overrides: [
      if (keeper != null) backgroundKeeperProvider.overrideWithValue(keeper),
      databaseProvider.overrideWithValue(db),
      modelLoaderProvider.overrideWithValue((onProgress) async => onProgress(1)),
      jsonModelProvider.overrideWithValue(_NoModel()),
      videoSourceProvider.overrideWithValue(source ?? _Source()),
      speechProbeProvider.overrideWithValue(null),
      if (pdf != null) pdfTextSourceProvider.overrideWithValue(pdf),
    ]);

Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 500 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue);
}

void main() {
  late AppDatabase db;
  late List<String> ids;
  setUp(() {
    db = AppDatabase.inMemory();
    final m = addMaterial(db);
    ids = [for (final n in ['Alpha', 'Beta', 'Gamma']) addConcept(db, n)];
    for (final id in ids) {
      addMaterialConcept(db, m, id);
    }
    recomputeUserActiveConcepts(db);
  });

  int videos() => db.select("SELECT count(*) AS n FROM videos WHERE status = 'active'").first['n'] as int;

  test('Stop shows at once and halts before the next video; Continue picks up where it stopped', () async {
    final source = _Source();
    final c = _container(db, source: source);
    addTearDown(c.dispose);
    final ctrl = c.read(ingestionControllerProvider.notifier);

    final run = ctrl.findVideosFor(ids);
    await _until(() => (c.read(ingestionControllerProvider).report?.checked ?? 0) >= 1);
    ctrl.cancel();
    expect(c.read(ingestionControllerProvider).status, IngestionStatus.stopped); // at once
    await run;
    expect(c.read(ingestionControllerProvider).status, IngestionStatus.stopped); // not overwritten by "done"
    // The last concept was never checked (its search may have started early, in the background).
    expect(db.select("SELECT 1 FROM ingest_log WHERE source_id LIKE 'Gamma-%'"), isEmpty);
    expect(source.queries, isNotEmpty);
    final stoppedAt = videos();
    expect(stoppedAt, lessThan(6));
    // Saved: from the interrupted concept to the end.
    final saved = parseJsonList(db.getSetting(ingestResumeKey));
    expect(saved.last, ids.last);
    expect(ids.sublist(ids.length - saved.length), saved);

    // Continue: finishes the rest; already-decided videos are not checked again.
    expect(ctrl.canContinue, isTrue);
    await ctrl.resume();
    expect(c.read(ingestionControllerProvider).status, IngestionStatus.done);
    expect(videos(), 6);
    expect(parseJsonList(db.getSetting(ingestResumeKey)), isEmpty);
    expect(ctrl.canContinue, isFalse);
  });

  test('Continue works after the app was closed; a one-concept search keeps the saved place', () async {
    final c1 = _container(db);
    final ctrl1 = c1.read(ingestionControllerProvider.notifier);
    final run = ctrl1.findVideosFor(ids);
    await _until(() => (c1.read(ingestionControllerProvider).report?.checked ?? 0) >= 1);
    ctrl1.cancel();
    await run;
    c1.dispose(); // "app closed"

    final c2 = _container(db);
    addTearDown(c2.dispose);
    expect(c2.read(ingestionControllerProvider).status, IngestionStatus.stopped);
    final ctrl2 = c2.read(ingestionControllerProvider.notifier);
    expect(ctrl2.canContinue, isTrue);

    await ctrl2.findVideos(ids.first); // a single "Find videos" in between
    expect(parseJsonList(db.getSetting(ingestResumeKey)), isNotEmpty);
    expect(ctrl2.canContinue, isTrue);

    await ctrl2.resume();
    expect(videos(), 6);
  });

  test('upload: Stop saves nothing and says so at once; Continue reads the PDF again', () async {
    final pdf = _SlowPdf();
    final file = File('${Directory.systemTemp.createTempSync('tf').path}/Ch7.pdf')..writeAsStringSync('x');
    final c = _container(db, pdf: pdf);
    addTearDown(c.dispose);
    final ctrl = c.read(materialControllerProvider.notifier);
    final before = db.select('SELECT count(*) AS n FROM materials').first['n'];

    final run = ctrl.upload(file.path);
    await _until(() => c.read(materialControllerProvider).status == UploadStatus.processing);
    ctrl.cancel();
    expect(c.read(materialControllerProvider).status, UploadStatus.stopped);
    pdf.gate.complete();
    await run;
    expect(c.read(materialControllerProvider).status, UploadStatus.stopped);
    expect(db.select('SELECT count(*) AS n FROM materials').first['n'], before); // nothing saved

    await ctrl.resume();
    expect(c.read(materialControllerProvider).status, UploadStatus.done);
    expect(db.select('SELECT count(*) AS n FROM materials').first['n'], (before as int) + 1);
    // The upload starts finding videos; stop it before the test ends.
    final ingest = c.read(ingestionControllerProvider.notifier)..cancel();
    await ingest.idle;
  });

  test('runs in the background: a notification shows progress, and its Stop button stops the work', () async {
    final keeper = _Keeper();
    final c = _container(db, keeper: keeper);
    addTearDown(c.dispose);
    final ctrl = c.read(ingestionControllerProvider.notifier);
    final run = ctrl.findVideosFor(ids);
    await _until(() => (c.read(ingestionControllerProvider).report?.checked ?? 0) >= 1);
    expect(keeper.events.first, startsWith('start: '));
    expect(keeper.events.where((e) => e.startsWith('update: ')), isNotEmpty);
    keeper.stopButton!(); // Stop in the notification
    expect(c.read(ingestionControllerProvider).status, IngestionStatus.stopped);
    await run;
    expect(keeper.events.last, 'stop');
  });
}
