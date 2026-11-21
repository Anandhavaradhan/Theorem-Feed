import 'package:chewie/chewie.dart';

/// Parses WebVTT or SRT cue text into chewie [Subtitle]s. Inline tags are stripped.
List<Subtitle> parseCaptions(String raw) {
  final cues = <Subtitle>[];
  final blocks = raw.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
  final timing = RegExp(r'((?:\d+:)?\d{1,2}:\d{2}[.,]\d{3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{3})');
  for (final block in blocks) {
    final lines = block.split('\n');
    final i = lines.indexWhere(timing.hasMatch);
    if (i < 0) continue;
    final m = timing.firstMatch(lines[i])!;
    final text = lines
        .sublist(i + 1)
        .map((l) => l.replaceAll(RegExp(r'<[^>]+>'), '').trim())
        .where((l) => l.isNotEmpty)
        .join('\n');
    if (text.isEmpty) continue;
    cues.add(Subtitle(index: cues.length, start: _ts(m.group(1)!), end: _ts(m.group(2)!), text: text));
  }
  return cues;
}

Duration _ts(String s) {
  final parts = s.replaceAll(',', '.').split(':');
  final secParts = parts.last.split('.');
  final h = parts.length == 3 ? int.parse(parts[0]) : 0;
  final m = int.parse(parts[parts.length - 2]);
  return Duration(hours: h, minutes: m, seconds: int.parse(secParts[0]), milliseconds: int.parse(secParts[1]));
}
