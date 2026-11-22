/// Text-native PDF reading (§6). No OCR, no scanned pages, no handwriting.
library;

import 'package:pdfrx/pdfrx.dart';

/// Raised for PDFs without a text layer (§6: "reject the upload").
class NoTextLayer implements Exception {
  @override
  String toString() => 'This PDF has no text layer. Please upload a text-native PDF.';
}

abstract class PdfTextSource {
  /// One string per page, in order.
  Future<List<String>> pages(String filePath);
}

/// PDFium (via pdfrx) on the device.
class PdfrxTextSource implements PdfTextSource {
  @override
  Future<List<String>> pages(String filePath) async {
    final doc = await PdfDocument.openFile(filePath);
    try {
      return [
        for (final page in doc.pages) (await page.loadText())?.fullText ?? '',
      ];
    } finally {
      await doc.dispose();
    }
  }
}

/// §6: if page 1 has fewer than 50 characters of text, there's no usable text layer.
void ensureTextLayer(List<String> pages) {
  if (pages.isEmpty || pages.first.replaceAll(RegExp(r'\s'), '').length < 50) throw NoTextLayer();
}
