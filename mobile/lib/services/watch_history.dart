/// Watch history: one row per video (the `saved` flag lives on the same row).
///
/// A viewing counts as completed at 90% of the duration. Completing a video that
/// was already completed counts as a rewatch. Search lowers already-watched
/// videos slightly (§11.4); nothing is ever deleted.
library;

import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/feed.dart';

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

extension WatchLists on WatchHistoryService {
  /// Recently watched, newest first (one entry per video).
  List<FeedCard> history({int limit = 30}) => _cards("""
    SELECT v.*, w.created_at AS at FROM watch_history w JOIN videos v ON v.id = w.video_id
    WHERE w.watched_sec > 0 AND v.status = 'active' ORDER BY w.rowid DESC LIMIT ?""", [limit]);

  /// Saved videos, most recent first.
  List<FeedCard> saved({int limit = 100}) => _cards("""
    SELECT v.*, w.created_at AS at FROM watch_history w JOIN videos v ON v.id = w.video_id
    WHERE w.saved = 1 AND v.status = 'active' ORDER BY w.rowid DESC LIMIT ?""", [limit]);

  List<FeedCard> _cards(String sql, List<Object?> args) {
    final db = _dbOf(this);
    return [
      for (final r in db.select(sql, args))
        () {
          // Label with the video's concept, preferring one from your material.
          final c = db.select("""
            SELECT c.id, c.canonical_name, (u.concept_id IS NOT NULL) AS active
            FROM video_concepts vc JOIN concepts c ON c.id = vc.concept_id
            LEFT JOIN user_active_concepts u ON u.concept_id = c.id
            WHERE vc.video_id = ? AND vc.is_primary = 1 ORDER BY active DESC, vc.confidence DESC LIMIT 1""",
              [r['id']]).firstOrNull;
          return FeedCard(
            videoId: r['id'] as String,
            title: r['title'] as String,
            thumbnailUrl: r['thumbnail_url'] as String?,
            durationSec: r['duration_sec'] as int?,
            isShort: r['is_short'] == 1,
            conceptId: (c?['id'] as String?) ?? '',
            conceptName: (c?['canonical_name'] as String?) ?? '',
            fromMaterial: c?['active'] == 1,
          );
        }(),
    ];
  }
}

AppDatabase _dbOf(WatchHistoryService s) => s._db;
