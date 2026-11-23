import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app.dart';
import 'core/i18n.dart';
import 'data/app_database.dart';
import 'providers/providers.dart';
import 'services/graph_seed.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort(); // the background notification's Stop button
  MediaKit.ensureInitialized();
  await pdfrxFlutterInitialize(); // PDF text extraction uses the engine API directly
  await Strings.load();
  final db = await AppDatabase.open();
  loadGraphSeed(db, await rootBundle.loadString(graphSeedAsset)); // no-op once loaded
  runApp(ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const TheoremFeedApp(),
  ));
}
