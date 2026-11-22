import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../providers/providers.dart';
import '../services/material/material_service.dart';
import '../widgets/ingestion_banner.dart';
import 'concept_detail_screen.dart';

/// My Material (§13.5): upload, list with status chips, exam dates,
/// archive/delete/reactivate, and a "Studying now" summary.
class MyMaterialScreen extends ConsumerWidget {
  const MyMaterialScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final materials = ref.watch(materialsProvider);
    final upload = ref.watch(materialControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text(t('material.title'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: upload.isBusy ? null : () => ref.read(materialControllerProvider.notifier).pickAndUpload(),
        icon: const Icon(Icons.upload_file),
        label: Text(t('material.upload')),
      ),
      body: Column(children: [
        const _UploadBanner(),
        const IngestionBanner(),
        Expanded(
          child: materials.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (list) => ListView(padding: const EdgeInsets.only(bottom: 96), children: [
              const _StudyingNow(),
              if (list.isEmpty)
                Padding(padding: const EdgeInsets.all(24), child: Text(t('material.empty'), textAlign: TextAlign.center)),
              for (final m in list) _MaterialCard(m: m),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _StudyingNow extends ConsumerWidget {
  const _StudyingNow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(studyingNowProvider).value;
    if (s == null || s.materials == 0) return const SizedBox.shrink();
    final params = {'materials': s.materials, 'concepts': s.concepts, 'days': s.daysToNearestExam ?? 0};
    final text = s.daysToNearestExam == null
        ? t('material.summary', params)
        : s.daysToNearestExam == 0
            ? t('material.summary_exam_today', params)
            : t('material.summary_exam', params);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ListTile(
        leading: const Icon(Icons.school),
        title: Text(t('material.studying')),
        subtitle: Text(text),
      ),
    );
  }
}

class _UploadBanner extends ConsumerWidget {
  const _UploadBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(materialControllerProvider);
    final r = s.result;
    final String text = switch (s.status) {
      UploadStatus.idle => '',
      UploadStatus.preparingModel =>
        s.modelProgress == null ? t('upload.model_loading') : t('upload.model', {'percent': (s.modelProgress! * 100).round()}),
      UploadStatus.processing => switch (s.stage) {
          UploadStage.extracting => t('upload.extracting', {'done': s.done, 'total': s.total}),
          UploadStage.saving => t('upload.saving'),
          _ => t('upload.reading'),
        },
      UploadStatus.done => r == null
          ? ''
          : r.alreadyUploaded
              ? t('upload.already', {'title': r.title})
              : r.reactivated
                  ? t('upload.reactivated', {'title': r.title})
                  : r.conceptCount == 0
                      ? t('upload.done_none', {'title': r.title})
                      : t('upload.done', {'title': r.title, 'concepts': r.conceptCount}),
      UploadStatus.failed => t('upload.failed', {'message': s.message ?? ''}),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    final progress = s.status == UploadStatus.processing && s.total > 0 ? s.done / s.total : null;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(text)),
            if (s.isBusy)
              TextButton(
                onPressed: () => ref.read(materialControllerProvider.notifier).cancel(),
                child: Text(t('ingest.cancel')),
              )
            else
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => ref.read(materialControllerProvider.notifier).dismiss(),
              ),
          ]),
          if (s.isBusy) LinearProgressIndicator(value: progress ?? s.modelProgress),
          if (s.rulesOnly && s.status == UploadStatus.done)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(t('upload.rules_only'), style: Theme.of(context).textTheme.bodySmall),
            ),
        ]),
      ),
    );
  }
}

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _MaterialCard extends ConsumerWidget {
  const _MaterialCard({required this.m});
  final MaterialSummary m;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(materialControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final active = m.status == 'active';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ExpansionTile(
        leading: Icon(Icons.picture_as_pdf, color: active ? scheme.primary : scheme.outline),
        title: Text(m.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(active ? t('material.status.active') : t('material.status.archived')),
            backgroundColor: active ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          ),
          Text(t('material.pages_concepts', {'pages': m.pageCount, 'concepts': m.conceptCount})),
          if (m.examDate != null) Text(t('material.exam', {'date': _date(m.examDate!)})),
        ]),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'exam':
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: m.examDate ?? now.add(const Duration(days: 14)),
                  firstDate: now.subtract(const Duration(days: 1)),
                  lastDate: now.add(const Duration(days: 730)),
                );
                if (picked != null) c.setExamDate(m.id, picked);
              case 'clear_exam':
                c.setExamDate(m.id, null);
              case 'rename':
                final title = await _askTitle(context, m.title);
                if (title != null) c.rename(m.id, title);
              case 'archive':
                c.archive(m.id);
              case 'reactivate':
                c.reactivate(m.id);
              case 'delete':
                if (await _confirmDelete(context, m.title)) c.delete(m.id);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'exam', child: Text(t('material.set_exam'))),
            if (m.examDate != null) PopupMenuItem(value: 'clear_exam', child: Text(t('material.clear_exam'))),
            PopupMenuItem(value: 'rename', child: Text(t('material.rename'))),
            if (active)
              PopupMenuItem(value: 'archive', child: Text(t('material.archive')))
            else
              PopupMenuItem(value: 'reactivate', child: Text(t('material.reactivate'))),
            PopupMenuItem(value: 'delete', child: Text(t('material.delete'))),
          ],
        ),
        children: [_MaterialConcepts(materialId: m.id)],
      ),
    );
  }

  Future<String?> _askTitle(BuildContext context, String current) {
    final ctrl = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('material.rename')),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('material.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(t('material.save'))),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context, String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(t('material.delete_confirm', {'title': title})),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('material.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('material.delete'))),
          ],
        ),
      ) ??
      false;
}

class _MaterialConcepts extends ConsumerWidget {
  const _MaterialConcepts({required this.materialId});
  final String materialId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(materialConceptsProvider(materialId)).value ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(t('material.concepts'), style: Theme.of(context).textTheme.titleSmall),
      ),
      for (final r in rows)
        ListTile(
          dense: true,
          title: Text(r.name),
          subtitle: Text(
            [if (r.section != null) r.section!, r.statement].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => ConceptDetailScreen(conceptId: r.conceptId))),
        ),
    ]);
  }
}
