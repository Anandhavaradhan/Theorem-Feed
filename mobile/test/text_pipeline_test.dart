import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/services/material/pdf_text.dart';
import 'package:theoremfeed/services/material/text_pipeline.dart';

import 'support/sample_chapter.dart';

void main() {
  test('§6.1 cleaning: ligatures, hyphen breaks, bare page numbers, blank runs', () {
    expect(cleanText('the ﬁrst eﬃcient proof'), 'the first efficient proof');
    expect(cleanText('some-\ntimes it works'), 'sometimes it works');
    expect(cleanText('Text\n\n\n\n42\n\nMore'), 'Text\n\nMore');
    expect(cleanText('Self-\nAdjoint'), 'Self-\nAdjoint'); // only lowercase continuations are joined
  });

  test('no text layer is rejected (§6)', () {
    expect(() => ensureTextLayer(['   \n  ']), throwsA(isA<NoTextLayer>()));
    expect(() => ensureTextLayer([]), throwsA(isA<NoTextLayer>()));
    ensureTextLayer(sampleChapterPages); // fine
    expect(NoTextLayer().toString(), 'This PDF has no text layer. Please upload a text-native PDF.');
  });

  test('repeated headers/footers (>60% of pages) are removed, digits ignored', () {
    final pages = removeRepeatedHeadersFooters(sampleChapterPages);
    expect(pages.any((p) => p.contains('Calculus Notes — Spring Term')), isFalse);
    expect(pages.any((p) => RegExp(r'^Page \d+$', multiLine: true).hasMatch(p)), isFalse);
    expect(pages.first, contains('Theorem 7.1 (Integration by Parts)'));
  });

  test('headings: chapter and numbered sections are tracked per paragraph', () {
    final paras = paragraphsFromPages(sampleChapterPages);
    final thm = paras.firstWhere((p) => p.text.startsWith('Theorem 7.1'));
    expect(thm.heading.chapter, '7 Techniques of Integration');
    expect(thm.heading.section, '7.1 Integration by Parts');
    expect(thm.page, 1);
    final def = paras.firstWhere((p) => p.text.startsWith('Definition 7.3'));
    expect(def.heading.section, '7.2 Partial Fractions');
    expect(def.page, 2);
    // A sentence ending in a period is not mistaken for a section heading.
    expect(updateHeading(Heading(), '3.5 This is a sentence that ends.').section, isNull);
  });

  test('chunks pack whole paragraphs, overlap, and keep theorem with proof', () {
    final paras = paragraphsFromPages(sampleChapterPages);
    final chunks = chunkParagraphs(paras, maxChars: 400, overlapChars: 120);
    expect(chunks.length, greaterThan(2));
    expect(chunks.every((c) => c.text.length <= 400 + 120 + 200), isTrue);
    // The theorem statement and its proof paragraph end up in the same chunk somewhere.
    expect(chunks.any((c) => c.text.contains('Theorem 7.1') && c.text.contains('Proof.')), isTrue);
    // Overlap: consecutive chunks share text.
    final shared = [for (var i = 1; i < chunks.length; i++) chunks[i].text.contains(chunks[i - 1].text.split('\n\n').last)];
    expect(shared.where((s) => s).length, greaterThan(0));
    expect(chunks.first.firstPage, 1);
    expect(chunks.last.lastPage, 4);
  });

  test('a single oversized paragraph is split at sentence boundaries', () {
    final long = List.generate(60, (i) => 'Sentence number $i is here.').join(' ');
    final chunks = chunkParagraphs([Paragraph(long, 1, Heading())], maxChars: 300, overlapChars: 0);
    expect(chunks.length, greaterThan(3));
    expect(chunks.every((c) => c.text.endsWith('.')), isTrue);
  });
}
