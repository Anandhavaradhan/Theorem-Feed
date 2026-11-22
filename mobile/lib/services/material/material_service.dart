/// Material system (§6), on the device: upload → read → clean → chunk →
/// extract → map to graph → recompute active concepts → (caller) scoped
/// ingestion for new concepts with no videos. Plus the lifecycle (§6.5).
///
/// Soft-delete only: archive/delete are status changes; nothing is DELETEd.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../data/app_database.dart';
import '../active_concepts.dart';
import '../concept_matcher.dart';
import '../llm.dart';
import '../text_match.dart';
import 'concept_extractor.dart';
import 'concept_verifier.dart';
import 'pdf_text.dart';
import 'rules_extractor.dart';
import 'text_pipeline.dart';

enum UploadStage { reading, extracting, saving }

typedef UploadProgress = void Function(UploadStage stage, int done, int total);

class UploadResult {
  UploadResult({
    required this.materialId,
    required this.title,
    required this.conceptCount,
    required this.gapConceptIds,
    this.alreadyUploaded = false,
    this.reactivated = false,
    this.chunkErrors = 0,
    this.elapsed = Duration.zero,
    this.ruleConcepts = 0,
    this.aiConcepts = 0,
    this.aiUsed = false,
    this.aiError,
    this.candidatesChecked = 0,
    this.aiVerified = false,
  });

  final String materialId;
  final String title;
  final int conceptCount;

  /// Active concepts from this material with no videos yet, most important
  /// first: these get scoped ingestion (Path A) right after the upload.
  final List<String> gapConceptIds;
  final bool alreadyUploaded;
  final bool reactivated;
  final int chunkErrors;

  // Diagnostics shown after an upload.
  final Duration elapsed;
  final int ruleConcepts; // found by the fast rules
  final int aiConcepts; // found by the AI deep read
  final bool aiUsed;
  final String? aiError; // first AI failure, if any
  final int candidatesChecked; // rule candidates the AI verified
  final bool aiVerified;
}

class MaterialSummary {
  MaterialSummary({
    required this.id,
    required this.title,
    required this.status,
    required this.pageCount,
    required this.conceptCount,
    required this.examDate,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String status;
  final int pageCount;
  final int conceptCount;
  final DateTime? examDate;
  final DateTime createdAt;
}

class StudyingNow {
  StudyingNow(this.materials, this.concepts, this.daysToNearestExam);
  final int materials;
  final int concepts;
  final int? daysToNearestExam;
}

class MaterialConceptRow {
  MaterialConceptRow(this.conceptId, this.name, this.statement, this.chapter, this.section, this.importance);
  final String conceptId;
  final String name;
  final String statement;
  final String? chapter;
  final String? section;
  final double importance;
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class MaterialService {
  MaterialService(this._db,
      {PdfTextSource? pdf, this.model, this.verify = true, this.deepRead = false, this.mapThreshold = 88})
      : _pdf = pdf ?? PdfrxTextSource(),
        _matcher = ConceptMatcher(_db, threshold: mapThreshold);

  final AppDatabase _db;
  final PdfTextSource _pdf;

  /// The on-device model, used only when [deepRead] is on.
  final JsonModel? model;

  /// Let loose rules propose and the AI verify (default). Without a model, or
  /// if verification fails, the strict rules decide.
  final bool verify;

  /// Also run the AI over every section (slower; finds unlabelled concepts the
  /// rules miss). Off by default: the rules handle clear textbooks in seconds.
  final bool deepRead;
  final double mapThreshold;
  final ConceptMatcher _matcher;
  static const _uuid = Uuid();

  // --- upload ---------------------------------------------------------------

  Future<UploadResult> upload(String filePath,
      {String? title, UploadProgress? onProgress, bool Function()? isCancelled, DateTime? now}) async {
    final t = (now ?? DateTime.now()).toUtc();
    final hash = sha256.convert(await File(filePath).readAsBytes()).toString();
    final name = (title?.trim().isNotEmpty ?? false) ? title!.trim() : p.basenameWithoutExtension(filePath);

    // Re-upload of the same file: no re-processing.
    final existing = _db.select('SELECT id, title, status FROM materials WHERE file_hash = ?', [hash]).firstOrNull;
    if (existing != null) {
      final id = existing['id'] as String;
      final wasActive = existing['status'] == 'active';
      if (!wasActive) _setStatus(id, 'active', now: t);
      return UploadResult(
        materialId: id,
        title: existing['title'] as String,
        conceptCount: _conceptCount(id),
        gapConceptIds: _gapsFor(id),
        alreadyUploaded: wasActive,
        reactivated: !wasActive,
      );
    }

    final clock = Stopwatch()..start();
    onProgress?.call(UploadStage.reading, 0, 1);
    final pages = await _pdf.pages(filePath);
    ensureTextLayer(pages);
    final paragraphs = paragraphsFromPages(pages);
    onProgress?.call(UploadStage.reading, 1, 1);

    // Rules over the whole document (milliseconds), then — if the model is
    // available — loose candidates verified by the on-device AI.
    final dict = _dictionary();
    final strict = extractByRules(paragraphs, dict);
    final ruleCount = mergeExtracted(strict).length;
    List<ExtractedConcept> extracted = strict;
    var checked = 0;
    var verified = false;
    String? verifyError;
    final vm = model;
    if (verify && vm != null) {
      final loose = mergeExtracted(extractByRules(paragraphs, dict, loose: true))
        ..sort((a, b) => b.importance.compareTo(a.importance));
      final candidates = loose.take(64).toList();
      final vr = await verifyCandidates(
        vm,
        candidates,
        strictNames: {for (final e in mergeExtracted(strict)) e.name},
        isCancelled: isCancelled,
        onProgress: (done, total) => onProgress?.call(UploadStage.extracting, done, total),
      );
      checked = vr.checked;
      verifyError = vr.error;
      verified = true;
      // Mentioned-only concepts become prerequisites of the section's concepts.
      extracted = [
        for (final c in vr.concepts)
          c.copyWith(prerequisitesMentioned: {
            ...c.prerequisitesMentioned,
            for (final m in vr.mentionedOnly)
              if (m.section != null && m.section == c.section && m.name != c.name) m.name,
          }.toList()),
      ];
      // Never end with nothing because of the AI: fall back to the strict rules.
      if (extracted.isEmpty && strict.isNotEmpty) extracted = strict;
    }

    // Optional deep read: the AI over each section.
    var errors = 0, aiCount = 0;
    String? aiError = verifyError;
    final m = model;
    final useAi = deepRead && m != null;
    if (useAi) {
      final chunks = chunkParagraphs(paragraphs);
      for (var i = 0; i < chunks.length; i++) {
        if (isCancelled?.call() ?? false) throw const UploadCancelled();
        try {
          final found = await extractWithModel(m, chunks[i]);
          aiCount += found.length;
          extracted.addAll(found);
        } on ModelRefusal catch (e) {
          errors++;
          aiError ??= '$e';
        } on ModelApiError catch (e) {
          errors++;
          aiError ??= e.message;
        }
        onProgress?.call(UploadStage.extracting, i + 1, chunks.length);
      }
    } else if (!verified) {
      onProgress?.call(UploadStage.extracting, 1, 1);
    }

    onProgress?.call(UploadStage.saving, 0, 1);
    final materialId = _uuid.v4();
    var count = 0;
    _db.transaction(() {
      _db.execute(
        "INSERT INTO materials (id, title, file_hash, page_count, status, created_at) VALUES (?, ?, ?, ?, 'active', ?)",
        [materialId, name, hash, pages.length, t.millisecondsSinceEpoch],
      );
      final byConcept = <String, (ExtractedConcept, Set<String>)>{};
      for (final e in mergeExtracted(extracted)) {
        final conceptId = _resolveOrCreate(e);
        final prev = byConcept[conceptId];
        // Same graph concept under two names in one material: keep the more important one (§6.4.1).
        if (prev == null || e.importance > prev.$1.importance) {
          byConcept[conceptId] = (e, {...?prev?.$2, ...e.prerequisitesMentioned});
        } else {
          prev.$2.addAll(e.prerequisitesMentioned);
        }
      }
      for (final entry in byConcept.entries) {
        final (e, prereqNames) = entry.value;
        final prereqIds = <String>{
          for (final n in prereqNames)
            if (_matcher.match(n) case final ConceptRef r when r.id != entry.key) r.id,
        };
        _db.execute(
          'INSERT INTO material_concepts (id, material_id, concept_id, statement, latex, chapter, section, difficulty, '
          'importance, prerequisites_mentioned) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [_uuid.v4(), materialId, entry.key, e.statement, e.latex, e.chapter, e.section, e.difficulty,
           e.importance, jsonList(prereqIds.toList())],
        );
        for (final pid in prereqIds) {
          _db.execute(
            "INSERT OR IGNORE INTO concept_edges (from_concept, to_concept, relation, weight) VALUES (?, ?, 'requires', 1.0)",
            [entry.key, pid],
          );
        }
        count++;
      }
    });
    recomputeUserActiveConcepts(_db, now: t);
    onProgress?.call(UploadStage.saving, 1, 1);
    return UploadResult(
      materialId: materialId,
      title: name,
      conceptCount: count,
      gapConceptIds: _gapsFor(materialId),
      chunkErrors: errors,
      elapsed: clock.elapsed,
      ruleConcepts: ruleCount,
      aiConcepts: aiCount,
      aiUsed: useAi,
      aiError: aiError,
      candidatesChecked: checked,
      aiVerified: verified,
    );
  }

  ConceptDictionary _dictionary() => ConceptDictionary([
        for (final r in _db.select('SELECT canonical_name, aliases, type FROM concepts'))
          (r['canonical_name'] as String, parseJsonList(r['aliases'] as String?), r['type'] as String),
      ]);

  /// §6.4 step 2: attach to an existing concept (fuzzy name/alias match), else
  /// create a new concept node with canonical_name = name.
  String _resolveOrCreate(ExtractedConcept e) {
    final hit = _matcher.match(e.name);
    if (hit != null) return hit.id;
    final id = _uuid.v4();
    _db.execute(
      'INSERT INTO concepts (id, canonical_name, aliases, type, subject, description) VALUES (?, ?, ?, ?, ?, ?)',
      [id, e.name, '[]', e.type, e.subject, e.statement],
    );
    return id;
  }

  int _conceptCount(String materialId) =>
      _db.select('SELECT count(DISTINCT concept_id) AS n FROM material_concepts WHERE material_id = ?', [materialId])
          .first['n'] as int;

  List<String> _gapsFor(String materialId) => [
        for (final r in _db.select('''
          SELECT mc.concept_id FROM material_concepts mc
          JOIN user_active_concepts u ON u.concept_id = mc.concept_id
          WHERE mc.material_id = ? AND NOT EXISTS (
            SELECT 1 FROM video_concepts vc JOIN videos v ON v.id = vc.video_id
            WHERE vc.concept_id = mc.concept_id AND vc.is_primary = 1 AND v.status = 'active' AND v.is_short = 0)
          GROUP BY mc.concept_id ORDER BY max(mc.importance) DESC, min(mc.section), mc.concept_id
        ''', [materialId]))
          r['concept_id'] as String,
      ];

  // --- lifecycle (§6.5) ---------------------------------------------------------

  void _setStatus(String id, String status, {DateTime? now}) {
    _db.execute('UPDATE materials SET status = ? WHERE id = ?', [status, id]);
    recomputeUserActiveConcepts(_db, now: now);
  }

  void archive(String id) => _setStatus(id, 'archived');
  void delete(String id) => _setStatus(id, 'deleted'); // soft delete
  void reactivate(String id) => _setStatus(id, 'active');

  void rename(String id, String title) {
    if (title.trim().isEmpty) return;
    _db.execute('UPDATE materials SET title = ? WHERE id = ?', [title.trim(), id]);
  }

  void setExamDate(String id, DateTime? date) {
    _db.execute('UPDATE materials SET exam_date = ? WHERE id = ?', [date == null ? null : _ymd(date), id]);
    recomputeUserActiveConcepts(_db); // exam proximity boost
  }

  /// §6.5 daily job: archive active materials whose exam date has passed.
  /// Run at app start and once a day while the app is open.
  int autoArchivePastExams({DateTime? now}) {
    final today = _ymd((now ?? DateTime.now()));
    final ids = [
      for (final r in _db.select(
          "SELECT id FROM materials WHERE status = 'active' AND exam_date IS NOT NULL AND exam_date < ?", [today]))
        r['id'] as String,
    ];
    if (ids.isEmpty) return 0;
    for (final id in ids) {
      _db.execute("UPDATE materials SET status = 'archived' WHERE id = ?", [id]);
    }
    recomputeUserActiveConcepts(_db, now: now?.toUtc());
    return ids.length;
  }

  // --- queries ----------------------------------------------------------------

  /// Active and archived materials (deleted ones are hidden), newest first.
  List<MaterialSummary> list() => [
        for (final r in _db.select('''
          SELECT m.*, (SELECT count(DISTINCT concept_id) FROM material_concepts mc WHERE mc.material_id = m.id) AS concepts
          FROM materials m WHERE m.status != 'deleted' ORDER BY m.status = 'active' DESC, m.created_at DESC
        '''))
          MaterialSummary(
            id: r['id'] as String,
            title: r['title'] as String,
            status: r['status'] as String,
            pageCount: r['page_count'] as int,
            conceptCount: r['concepts'] as int,
            examDate: r['exam_date'] == null ? null : DateTime.parse(r['exam_date'] as String),
            createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int, isUtc: true),
          ),
      ];

  StudyingNow studyingNow({DateTime? now}) {
    final today = _ymd(now ?? DateTime.now());
    final materials = _db.select("SELECT count(*) AS n FROM materials WHERE status = 'active'").first['n'] as int;
    final concepts = _db.select('SELECT count(*) AS n FROM user_active_concepts').first['n'] as int;
    final nearest = _db.select(
        "SELECT min(exam_date) AS d FROM materials WHERE status = 'active' AND exam_date >= ?", [today]).first['d'];
    final days = nearest == null ? null : DateTime.parse(nearest as String).difference(DateTime.parse(today)).inDays;
    return StudyingNow(materials, concepts, days);
  }

  List<MaterialConceptRow> conceptsOf(String materialId) => [
        for (final r in _db.select('''
          SELECT c.id, c.canonical_name, mc.statement, mc.chapter, mc.section, mc.importance
          FROM material_concepts mc JOIN concepts c ON c.id = mc.concept_id
          WHERE mc.material_id = ? ORDER BY mc.chapter, mc.section, mc.importance DESC
        ''', [materialId]))
          MaterialConceptRow(r['id'] as String, r['canonical_name'] as String, r['statement'] as String,
              r['chapter'] as String?, r['section'] as String?, (r['importance'] as num).toDouble()),
      ];
}

class UploadCancelled implements Exception {
  const UploadCancelled();
  @override
  String toString() => 'Upload cancelled';
}

/// §6.4 step 1, without an embedding model: merge extractions of the same concept
/// across chunks by name (normalized, or token_set_ratio ≥ 90). A labelled rule
/// hit supplies the statement exactly as the material states it; the model
/// fills LaTeX, prerequisites and difficulty. Highest importance wins.
List<ExtractedConcept> mergeExtracted(List<ExtractedConcept> items) {
  final groups = <List<ExtractedConcept>>[];
  for (final e in items) {
    final n = normalizeText(e.name);
    final g = groups.where((g) {
      final gn = normalizeText(g.first.name);
      return gn == n || tokenSetRatio(gn, n) >= 90 && (gn.split(' ').length > 1 || n.split(' ').length > 1);
    }).firstOrNull;
    g == null ? groups.add([e]) : g.add(e);
  }
  return [
    for (final g in groups)
      () {
        final best = (g.where((e) => e.fromRule).toList()..sort((a, b) => b.importance.compareTo(a.importance)))
                .firstOrNull ??
            (g.toList()..sort((a, b) => b.importance.compareTo(a.importance))).first;
        final latex = best.latex ?? g.map((e) => e.latex).whereType<String>().firstOrNull;
        final prereqs = {for (final e in g) ...e.prerequisitesMentioned}.toList();
        final importance = g.map((e) => e.importance).reduce((a, b) => a > b ? a : b);
        final modelHit = g.where((e) => !e.fromRule).firstOrNull;
        return ExtractedConcept(
          name: best.name,
          type: best.type,
          subject: modelHit?.subject ?? best.subject,
          statement: best.statement,
          latex: latex,
          chapter: best.chapter,
          section: best.section,
          difficulty: modelHit?.difficulty ?? best.difficulty,
          prerequisitesMentioned: prereqs,
          importance: importance,
          fromRule: best.fromRule,
        );
      }(),
  ];
}
