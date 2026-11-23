import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// The single on-device database. Everything (library, graph, materials, caches)
/// lives here; there is no server.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  /// Opens (and migrates) the app's database file in app-support storage.
  static Future<AppDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    return AppDatabase._(sqlite3.open(p.join(dir.path, 'theoremfeed.db')))..migrate();
  }

  /// In-memory database for tests.
  factory AppDatabase.inMemory() => AppDatabase._(sqlite3.openInMemory())..migrate();

  void migrate() {
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA journal_mode = WAL');
    final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version < 1) {
      transaction(() {
        for (final stmt in migrationV1) {
          db.execute(stmt);
        }
        db.execute('PRAGMA user_version = 1');
      });
    }
    if (version < 2) {
      transaction(() {
        for (final stmt in migrationV2) {
          db.execute(stmt);
        }
        db.execute('PRAGMA user_version = 2');
      });
    }
    if (version < 3) {
      transaction(() {
        for (final stmt in migrationV3) {
          db.execute(stmt);
        }
        db.execute('PRAGMA user_version = 3');
      });
    }
    if (version < 4) {
      transaction(() {
        for (final stmt in migrationV4) {
          db.execute(stmt);
        }
        db.execute('PRAGMA user_version = 4');
      });
    }
    if (version < 5) {
      transaction(() {
        for (final stmt in migrationV5) {
          db.execute(stmt);
        }
        db.execute('PRAGMA user_version = 5');
      });
    }
  }

  T transaction<T>(T Function() body) {
    db.execute('BEGIN');
    try {
      final result = body();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  ResultSet select(String sql, [List<Object?> params = const []]) => db.select(sql, params);

  void execute(String sql, [List<Object?> params = const []]) => db.execute(sql, params);

  void close() => db.close();

  String? getSetting(String key) {
    final r = db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void setSetting(String key, String value) =>
      db.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', [key, value]);
}

int nowMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

int boolInt(bool b) => b ? 1 : 0;

String jsonList(List<Object?> v) => jsonEncode(v);

List<String> parseJsonList(String? raw) =>
    raw == null || raw.isEmpty ? const [] : (jsonDecode(raw) as List).cast<String>();

/// Embeddings are stored as little-endian float32 BLOBs.
Uint8List encodeEmbedding(List<double> v) => Float32List.fromList(v).buffer.asUint8List();

Float32List decodeEmbedding(Uint8List blob) =>
    Float32List.view(Uint8List.fromList(blob).buffer, 0, blob.length ~/ 4);
