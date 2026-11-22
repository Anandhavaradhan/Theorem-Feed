/// Loads the knowledge graph seed (§7) into the on-device database.
///
/// Edges are stored as (from_concept = C, to_concept = P, relation = 'requires'):
/// "C requires P". So the prerequisites of C are the `to_concept`s of its
/// outgoing 'requires' edges.
///
/// Idempotent and merge-friendly: concepts are matched by canonical name
/// (case-insensitive), so concepts created earlier (e.g. by the Phase A seed or
/// by material extraction) are enriched rather than duplicated.
library;

import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../data/app_database.dart';

const graphSeedAsset = 'assets/graph/graph_seed_v1.json';
const _settingKey = 'graph_seed_version';

class GraphSeedResult {
  GraphSeedResult(this.inserted, this.updated, this.edges);
  final int inserted;
  final int updated;
  final int edges;
}

/// Returns null if this seed version is already loaded.
GraphSeedResult? loadGraphSeed(AppDatabase db, String json) {
  final data = jsonDecode(json) as Map<String, dynamic>;
  final version = data['version'] as int;
  final loaded = int.tryParse(db.getSetting(_settingKey) ?? '') ?? 0;
  if (loaded >= version) return null;

  final concepts = (data['concepts'] as List).cast<Map<String, dynamic>>();
  const uuid = Uuid();
  var inserted = 0, updated = 0, edges = 0;

  db.transaction(() {
    final idByName = <String, String>{};
    for (final c in concepts) {
      final name = c['canonical_name'] as String;
      final aliases = (c['aliases'] as List).cast<String>();
      final existing = db.select('SELECT id, aliases FROM concepts WHERE canonical_name = ? COLLATE NOCASE', [name]);
      if (existing.isEmpty) {
        final id = uuid.v4();
        db.execute(
          'INSERT INTO concepts (id, canonical_name, aliases, type, subject, description, in_theorem_pool, pool_order, latex) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [id, name, jsonList(aliases), c['type'], c['subject'], c['description'],
           boolInt(c['in_theorem_pool'] as bool), c['pool_order'], c['latex']],
        );
        idByName[name.toLowerCase()] = id;
        inserted++;
      } else {
        final id = existing.first['id'] as String;
        final merged = {...parseJsonList(existing.first['aliases'] as String?), ...aliases}.toList();
        db.execute(
          'UPDATE concepts SET aliases = ?, type = ?, subject = ?, description = ?, in_theorem_pool = ?, '
          'pool_order = ?, latex = coalesce(?, latex) WHERE id = ?',
          [jsonList(merged), c['type'], c['subject'], c['description'], boolInt(c['in_theorem_pool'] as bool),
           c['pool_order'], c['latex'], id],
        );
        idByName[name.toLowerCase()] = id;
        updated++;
      }
    }
    for (final c in concepts) {
      final from = idByName[(c['canonical_name'] as String).toLowerCase()]!;
      for (final req in (c['requires'] as List).cast<String>()) {
        final to = idByName[req.toLowerCase()];
        if (to == null) continue;
        db.execute(
          "INSERT OR IGNORE INTO concept_edges (from_concept, to_concept, relation, weight) VALUES (?, ?, 'requires', 1.0)",
          [from, to],
        );
        edges++;
      }
    }
    db.setSetting(_settingKey, '$version');
  });
  return GraphSeedResult(inserted, updated, edges);
}
