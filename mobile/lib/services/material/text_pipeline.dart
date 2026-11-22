/// Cleaning (§6.1), heading detection and chunking (§6.2) for text-native PDFs.
library;

/// §6.1 clean(): ligatures (NFKC-equivalent for common ones), hyphenated line
/// breaks, bare page-number lines, and runs of blank lines.
String cleanText(String text) {
  const ligatures = {'ﬀ': 'ff', 'ﬁ': 'fi', 'ﬂ': 'fl', 'ﬃ': 'ffi', 'ﬄ': 'ffl', 'ﬅ': 'st', 'ﬆ': 'st', ' ': ' '};
  var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  ligatures.forEach((k, v) => t = t.replaceAll(k, v));
  t = t.replaceAll(RegExp(r'-\n(?=[a-z])'), ''); // hyphen line breaks
  t = t.replaceAll(RegExp(r'^\s*\d+\s*$', multiLine: true), ''); // bare page numbers
  t = t.replaceAll(RegExp(r'[ \t]+\n'), '\n');
  t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return t.trim();
}

/// Removes header/footer lines that repeat on more than 60% of pages.
/// Only the first and last 3 lines of each page are candidates; digits are
/// ignored when comparing ("Chapter 7 · page 12" matches "Chapter 7 · page 13").
List<String> removeRepeatedHeadersFooters(List<String> pages, {double threshold = 0.6}) {
  if (pages.length < 3) return pages;
  String key(String line) => line.trim().replaceAll(RegExp(r'\d+'), '#').toLowerCase();
  List<String> edges(String page) {
    final lines = page.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return {...lines.take(3), ...lines.skip(lines.length > 3 ? lines.length - 3 : 0)}.toList();
  }

  final counts = <String, int>{};
  for (final p in pages) {
    for (final k in edges(p).map(key).toSet()) {
      counts[k] = (counts[k] ?? 0) + 1;
    }
  }
  final repeated = {for (final e in counts.entries) if (e.value > pages.length * threshold && e.key.isNotEmpty) e.key};
  if (repeated.isEmpty) return pages;
  return [
    for (final p in pages) p.split('\n').where((l) => !repeated.contains(key(l))).join('\n'),
  ];
}

class Heading {
  Heading({this.chapter, this.section});
  final String? chapter;
  final String? section;
}

final _chapterRe = RegExp(r'^\s*(?:chapter|unit|part)\s+(\d+|[ivxlc]+)\b[\s.:–—-]*(.{0,80})$', caseSensitive: false);
final _sectionRe = RegExp(r'^\s*(\d+\.\d+(?:\.\d+)?)\.?\s+([A-Z][^\n]{2,80})$');

/// Updates the running chapter/section from a paragraph's first line.
Heading updateHeading(Heading current, String paragraph) {
  final first = paragraph.trim().split('\n').first.trim();
  final ch = _chapterRe.firstMatch(first);
  if (ch != null) {
    final title = ch.group(2)!.trim();
    return Heading(chapter: title.isEmpty ? ch.group(1) : '${ch.group(1)} $title');
  }
  final sec = _sectionRe.firstMatch(first);
  if (sec != null && !first.endsWith('.')) {
    return Heading(chapter: current.chapter ?? sec.group(1)!.split('.').first, section: '${sec.group(1)} ${sec.group(2)!.trim()}');
  }
  return current;
}

class Paragraph {
  Paragraph(this.text, this.page, this.heading);
  final String text;
  final int page;
  final Heading heading;
}

class Chunk {
  Chunk({
    required this.text,
    required this.firstPage,
    required this.lastPage,
    required this.chapter,
    required this.section,
    this.paragraphs = const [],
  });
  final String text;
  final int firstPage;
  final int lastPage;
  final String? chapter; // first heading seen in the chunk
  final String? section;
  final List<Paragraph> paragraphs;

  /// Heading of the first paragraph that mentions [name] (normalized, case-insensitive),
  /// else the chunk's first heading.
  Heading headingFor(String name) {
    final n = name.toLowerCase();
    for (final p in paragraphs) {
      if (p.text.toLowerCase().contains(n)) return p.heading;
    }
    return Heading(chapter: chapter, section: section);
  }
}

/// Cleaned, header-free paragraphs with page numbers and running headings.
List<Paragraph> paragraphsFromPages(List<String> rawPages) {
  final pages = removeRepeatedHeadersFooters(rawPages);
  final out = <Paragraph>[];
  var heading = Heading();
  for (var i = 0; i < pages.length; i++) {
    for (final p in cleanText(pages[i]).split(RegExp(r'\n\s*\n'))) {
      final text = p.trim();
      if (text.isEmpty) continue;
      heading = updateHeading(heading, text);
      out.add(Paragraph(text, i + 1, heading));
    }
  }
  return out;
}

/// §6.2, sized for a small on-device model: pack whole paragraphs into chunks of
/// about [maxChars] (≈1,100 tokens) with about [overlapChars] of trailing
/// paragraphs repeated in the next chunk. A paragraph is never split unless it
/// alone exceeds [maxChars], so a theorem stays with its proof.
List<Chunk> chunkParagraphs(List<Paragraph> paragraphs, {int maxChars = 4500, int overlapChars = 600}) {
  final chunks = <Chunk>[];
  var current = <Paragraph>[];
  var size = 0;

  void emit() {
    if (current.isEmpty) return;
    chunks.add(Chunk(
      text: current.map((p) => p.text).join('\n\n'),
      firstPage: current.first.page,
      lastPage: current.last.page,
      chapter: current.map((p) => p.heading.chapter).whereType<String>().firstOrNull,
      section: current.map((p) => p.heading.section).whereType<String>().firstOrNull,
      paragraphs: List.of(current),
    ));
  }

  for (final para in _splitOversized(paragraphs, maxChars)) {
    if (size + para.text.length > maxChars && current.isNotEmpty) {
      emit();
      // Overlap: carry trailing paragraphs into the next chunk.
      final carry = <Paragraph>[];
      var carried = 0;
      for (final p in current.reversed) {
        if (carried + p.text.length > overlapChars) break;
        carry.insert(0, p);
        carried += p.text.length;
      }
      current = carry;
      size = carried;
    }
    current.add(para);
    size += para.text.length;
  }
  emit();
  return chunks;
}

Iterable<Paragraph> _splitOversized(List<Paragraph> paragraphs, int maxChars) sync* {
  for (final p in paragraphs) {
    if (p.text.length <= maxChars) {
      yield p;
      continue;
    }
    final buf = StringBuffer();
    for (final sentence in p.text.split(RegExp(r'(?<=[.!?])\s+'))) {
      if (buf.length + sentence.length > maxChars && buf.isNotEmpty) {
        yield Paragraph(buf.toString().trim(), p.page, p.heading);
        buf.clear();
      }
      buf.write('$sentence ');
    }
    if (buf.isNotEmpty) yield Paragraph(buf.toString().trim(), p.page, p.heading);
  }
}
