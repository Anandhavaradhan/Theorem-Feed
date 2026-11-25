import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/providers/providers.dart';
import 'package:theoremfeed/services/background_work.dart';
import 'package:theoremfeed/services/local_llm.dart';

/// A model whose download the test drives step by step.
class _SlowModel extends LocalLlmModel {
  int downloads = 0;
  final gate = Completer<void>();
  @override
  Future<void> ensureLoaded({void Function(double? fraction)? onProgress}) async {
    downloads++;
    onProgress?.call(0.1);
    onProgress?.call(0.5);
    await gate.future;
    onProgress?.call(1.0);
  }
}

class _Keeper implements BackgroundKeeper {
  final events = <String>[];
  @override
  Future<void> start({required String title, required String text, required void Function() onStop}) async =>
      events.add('start');
  @override
  Future<void> update(String text) async => events.add('update: $text');
  @override
  Future<void> stop() async => events.add('stop');
}

void main() {
  test('the model downloads once, in the background, for everyone who needs it', () async {
    final db = AppDatabase.inMemory();
    final model = _SlowModel();
    final keeper = _Keeper();
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      localModelProvider.overrideWithValue(model),
      backgroundKeeperProvider.overrideWithValue(keeper),
    ]);
    addTearDown(c.dispose);
    final loader = c.read(modelLoaderProvider);
    final seenA = <double?>[], seenB = <double?>[];

    final a = loader(seenA.add); // e.g. finding videos
    final b = loader(seenB.add); // e.g. an upload at the same time
    await Future<void>.delayed(Duration.zero);
    expect(model.downloads, 1); // one download, shared
    expect(c.read(modelDownloadProvider), 0.5); // progress for Settings
    expect(keeper.events.first, 'start'); // the background notification
    expect(keeper.events, contains('update: bg.model_progress'));

    model.gate.complete();
    await Future.wait([a, b]);
    expect(seenA, contains(1.0));
    expect(seenB, isNotEmpty);
    expect(keeper.events.last, 'stop');
    expect(c.read(modelReadyProvider), isTrue);
    expect(c.read(modelDownloadProvider), isNull);
  });
}
