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

/// A top-level heading numbered without the word "Chapter": "4 Refraction of
/// light", "10 The human eye", "16 Question bank: 40 questions".
/// At least two words, the first a real word, no formula signs, so "20 Hz",
/// "3 s later" or "12 A lens of focal length 2 m" never qualify.
final _plainChapterRe = RegExp(r'^\s*(\d{1,2})\s+([A-Z][^=\n]{3,70})$');

bool _isPlainChapter(String line) {
  final m = _plainChapterRe.firstMatch(line);
  final l = line.trimRight();
  if (m == null || l.endsWith('.') || l.endsWith(',') || l.endsWith('?') && l.length > 50) return false;
  final title = m.group(2)!.trim();
  final words = title.split(RegExp(r'\s+'));
  if (words.length < 2 || !RegExp(r'^[A-Z][a-z]{2,}').hasMatch(words.first)) return false;
  // Digits are fine later in a longer title ("Question bank: 40 questions"), not in a short one.
  return !RegExp(r'\d').hasMatch(title) || words.length >= 3 && !RegExp(r'\d').hasMatch(words.take(2).join(' '));
}

/// Updates the running chapter/section from a paragraph's first line.
Heading updateHeading(Heading current, String paragraph) {
  final first = paragraph.trim().split('\n').first.trim();
  final ch = _chapterRe.firstMatch(first);
  if (ch != null) {
    final title = ch.group(2)!.trim();
    return Heading(chapter: title.isEmpty ? ch.group(1) : '${ch.group(1)} $title');
  }
  if (_isPlainChapter(first)) {
    final m = _plainChapterRe.firstMatch(first)!;
    return Heading(chapter: '${m.group(1)} ${m.group(2)!.trim()}');
  }
  final sec = _sectionRe.firstMatch(first);
  if (sec != null && !first.endsWith('.')) {
    return Heading(chapter: current.chapter ?? sec.group(1)!.split('.').first, section: '${sec.group(1)} ${sec.group(2)!.trim()}');
  }
  return current;
}

class Paragraph {
  Paragraph(this.text, this.page, this.heading, {this.isHeading = false, this.isTitle = false});
  final String text;
  final int page;
  final Heading heading;

  /// A chapter/section heading line on its own ("7.1 Integration by Parts").
  final bool isHeading;

  /// A short unnumbered title line on its own, such as a box title
  /// ("Plane mirror", "Principle of reversibility") or a figure label.
  final bool isTitle;
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
/// Labels that start a new block in textbooks.
final blockLabelRe = RegExp(
    r'^(Theorem|Lemma|Proposition|Corollary|Definition|Example|Proof|Remark|Note|Exercise|Problem|Formula|Law|Principle|Rule|Algorithm|Identity|Claim|Fact)\b',
    caseSensitive: false);

/// "Theorem 7.1 …", "Definition.", "Lemma (Zorn)" — but not "Principle of reversibility".
bool labelledBlockStart(String line) {
  final m = blockLabelRe.firstMatch(line);
  if (m == null) return false;
  return RegExp(r'^\s*(?:\d|\(|[.:—–-]|$)').hasMatch(line.substring(m.end));
}

final _listItemRe = RegExp(r'^(\d{1,3}[.)]|[•▪◦\-–*]|\([a-z]\))\s');

bool _isHeadingLine(String line) {
  if (_chapterRe.hasMatch(line)) return true;
  if (_isPlainChapter(line)) return true;
  final sec = _sectionRe.firstMatch(line);
  return sec != null && !line.endsWith('.');
}

const _connectors = {
  'is', 'are', 'was', 'were', 'the', 'a', 'an', 'of', 'and', 'or', 'to', 'in', 'on', 'for', 'with', 'by', 'from',
  'giving', 'gives', 'so', 'that', 'as', 'at', 'then', 'than', 'but', 'if', 'when', 'which', 'where', 'its',
};

/// A short line that stands alone as a title: starts with a capital, at most 8
/// words, much shorter than a full line, and does not end mid-sentence.
bool isTitleLine(String line, {required int fullLength}) {
  final l = line.trim();
  if (l.isEmpty || l.length > 70 || l.length > fullLength * 0.7) return false;
  if (!RegExp(r'^[A-Z]').hasMatch(l)) return false;
  if (RegExp(r'[.,;=+×÷/]$').hasMatch(l) || l.contains('=')) return false;
  final words = l.split(RegExp(r'\s+'));
  if (words.length > 8) return false;
  if (_connectors.contains(words.last)) return false; // "Amplitude A" is fine; "… of a" is not
  if (labelledBlockStart(l)) return false; // "Theorem 2 (…)" / "Definition" join their statement
  return RegExp(r'[a-z]{2}').hasMatch(l);
}

/// A line of formula rather than prose ("P1 V1 = P2 V2", "7.9", "NA = 6.022 × 1023"):
/// a heading may follow it directly (formula sheets have no sentences to end).
bool _formulaLine(String line) {
  final l = line.trim();
  if (l.isEmpty) return false;
  if (l.contains('=') || l.contains('∝') || l.contains('→')) return true;
  final letters = RegExp(r'[A-Za-z]').allMatches(l).length;
  return letters < l.length * 0.5;
}

/// A table-of-contents page: a "Contents" line or several dot-leader lines.
bool _isContentsPage(String page) {
  final lines = page.split('\n').map((l) => l.trim()).toList();
  if (lines.take(8).any((l) => RegExp(r'^(table of )?contents$', caseSensitive: false).hasMatch(l))) return true;
  return lines.where((l) => RegExp(r'(\. ){4,}|\.{6,}').hasMatch(l)).length >= 5;
}

/// Real PDF text has one line per *visual* line and usually no blank lines
/// between paragraphs. Paragraphs are rebuilt from the layout: a new one starts
/// at a heading, a labelled block ("Theorem 7.1."), a list item, a blank line,
/// or after a line that ends a sentence and is clearly shorter than a full line.
/// Length of a full line of body text: the 80th percentile of line lengths.
int _fullLineLength(Iterable<String> lines) {
  final lengths = [for (final l in lines) if (l.trim().isNotEmpty) l.trim().length]..sort();
  return lengths.isEmpty ? 80 : lengths[(lengths.length * 0.8).floor().clamp(0, lengths.length - 1)];
}

List<(String, bool)> _paragraphsOfPage(String page, {int? fullLength}) {
  final lines = page.split('\n').map((l) => l.trim()).toList();
  // Measured over the whole document: a page full of table cells would make it tiny.
  final full = fullLength ?? _fullLineLength(lines);
  final paras = <(String, bool)>[];
  final buf = StringBuffer();
  String prev = '';

  void flush({bool title = false}) {
    final t = buf.toString().trim();
    if (t.isNotEmpty) paras.add((t, title));
    buf.clear();
    prev = '';
  }

  String nextLine(int i) {
    for (var j = i + 1; j < lines.length; j++) {
      if (lines[j].isNotEmpty) return lines[j];
    }
    return '';
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) {
      flush();
      continue;
    }
    final heading = _isHeadingLine(line);
    // A box title or label line: its own paragraph when the next line starts
    // something new (a capital, a bullet, a number, a symbol).
    final next = nextLine(i);
    final title = !heading &&
        isTitleLine(line, fullLength: full) &&
        (buf.isEmpty ||
            RegExp(r'[.:?!]$').hasMatch(prev) ||
            _formulaLine(prev) ||
            // A short heading with formulas under it (formula sheets rarely end lines with a full stop).
            (_formulaLine(next) && line.split(' ').length <= 5 && !RegExp(r'\d|:$').hasMatch(line))) &&
        (next.isEmpty || RegExp(r'^[A-Z0-9•▪◦\-–*(λμωνρϕφθ]').hasMatch(next) || _formulaLine(next));
    if (title) {
      flush();
      buf.write(line);
      flush(title: true);
      continue;
    }
    final startsBlock = heading || labelledBlockStart(line) || _listItemRe.hasMatch(line);
    final prevEndedParagraph =
        prev.isNotEmpty && RegExp(r'[.:?!]$').hasMatch(prev) && prev.length < full * 0.85;
    if (startsBlock || prevEndedParagraph) flush();
    if (buf.isNotEmpty) {
      // Re-join hyphenated words split across lines.
      final b = buf.toString();
      if (b.endsWith('-') && RegExp(r'^[a-z]').hasMatch(line)) {
        buf
          ..clear()
          ..write(b.substring(0, b.length - 1));
      } else {
        buf.write(' ');
      }
    }
    buf.write(line);
    prev = line;
    if (heading) flush(); // headings are paragraphs of their own
  }
  flush();
  return paras;
}

/// Cleaned, header-free paragraphs with page numbers and running headings.
List<Paragraph> paragraphsFromPages(List<String> rawPages) {
  final pages = removeRepeatedHeadersFooters([for (final p in rawPages) p.replaceAll('\r\n', '\n').replaceAll('\r', '\n')]);
  final out = <Paragraph>[];
  var heading = Heading();
  final cleaned = [for (final p in pages) cleanText(p)];
  final full = _fullLineLength(cleaned.expand((p) => p.split('\n')));
  for (var i = 0; i < pages.length; i++) {
    if (_isContentsPage(pages[i])) continue; // the outline is read from the real headings
    for (final (text, title) in _paragraphsOfPage(cleaned[i], fullLength: full)) {
      final isHeading = _isHeadingLine(text);
      heading = updateHeading(heading, text);
      out.add(Paragraph(text, i + 1, heading, isHeading: isHeading, isTitle: title && !isHeading));
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
