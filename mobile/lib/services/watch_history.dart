/// Watch history: one row per video (the `saved` flag lives on the same row).
///
/// A viewing counts as completed at 90% of the duration. Completing a video that
/// was already completed counts as a rewatch. Search lowers already-watched
/// videos slightly (§11.4); nothing is ever deleted.
library;

import 'package:uuid/uuid.dart';

import '../data/app_database.dart';

const completionThreshold = 0.9;

class WatchHistoryService {
  WatchHistoryService(this._db);
  final AppDatabase _db;

  Map<String, Object?>? _row(String videoId) =>
      _db.select('SELECT * FROM watch_history WHERE video_id = ? ORDER BY created_at LIMIT 1', [videoId]).firstOrNull;

  /// Records the end of one viewing. [watchedSec] is the furthest point reached.
  void recordViewing(String videoId, {required int watchedSec, required int? durationSec}) {
    if (watchedSec <= 0) return;
    final completed = durationSec != null && durationSec > 0 && watchedSec >= durationSec * completionThreshold;
    final row = _row(videoId);
    if (row == null) {
      _db.execute(
        'INSERT INTO watch_history (id, video_id, watched_sec, completed, rewatched_count, saved, created_at) '
        'VALUES (?, ?, ?, ?, 0, 0, ?)',
        [const Uuid().v4(), videoId, watchedSec, boolInt(completed), nowMs()],
      );
      return;
    }
    final wasCompleted = row['completed'] == 1;
    _db.execute(
      'UPDATE watch_history SET watched_sec = max(watched_sec, ?), completed = ?, rewatched_count = rewatched_count + ? '
      'WHERE id = ?',
      [watchedSec, boolInt(wasCompleted || completed), (wasCompleted && completed) ? 1 : 0, row['id']],
    );
  }

  bool isCompleted(String videoId) => _row(videoId)?['completed'] == 1;

  /// Where to resume an unfinished video (null if finished or never started).
  int? resumeAt(String videoId) {
    final r = _row(videoId);
    if (r == null || r['completed'] == 1) return null;
    final s = r['watched_sec'] as int;
    return s >= 10 ? s : null;
  }
}
