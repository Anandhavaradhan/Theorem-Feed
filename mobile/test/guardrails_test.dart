/// §15.8 / §15.9 guardrail greps (comment-aware), plus the on-device rule.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _ads = RegExp(r'\b(ads|admob|ad_unit|adslot)\b', caseSensitive: false);
final _discovery = RegExp(r'\b(discovery|adjacent|explore)\b', caseSensitive: false);

/// Dart source minus comments (comments *document* the bans) and minus URLs.
String _code(String src) {
  src = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return src
      .split('\n')
      .map((l) => l.trimLeft().startsWith('//') ? '' : l.replaceAll(RegExp(r'\s//\s.*$'), ''))
      .join('\n');
}

Iterable<File> _dartFiles(String dir) =>
    Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));

void main() {
  test('comment stripper keeps code and drops comments', () {
    expect(_discovery.hasMatch(_code('// explore\n/* adjacent */ final x = 1;')), isFalse);
    expect(_discovery.hasMatch(_code("final s = 'explore more';")), isTrue);
    expect(_ads.hasMatch('uploads loads threads'), isFalse);
  });

  test('no ads: code, dependencies, strings, manifest', () {
    final hits = <String>[
      for (final f in _dartFiles('lib'))
        if (_ads.hasMatch(_code(f.readAsStringSync()))) f.path,
      for (final path in ['pubspec.yaml', 'assets/i18n/en.json', 'android/app/src/main/AndroidManifest.xml'])
        if (_ads.hasMatch(File(path).readAsStringSync())) path,
    ];
    expect(hits, isEmpty);
  });

  test('no discovery / adjacent / explore affordances in app code or UI strings', () {
    final hits = <String>[
      for (final f in _dartFiles('lib'))
        if (_discovery.hasMatch(_code(f.readAsStringSync()))) f.path,
      if (_discovery.hasMatch(File('assets/i18n/en.json').readAsStringSync())) 'en.json',
    ];
    expect(hits, isEmpty);
  });

  test('no middleman: the app never talks to a server of its own', () {
    // Network access happens only via the YouTube extractor (and, from Phase C, the Claude API).
    final hits = <String>[
      for (final f in _dartFiles('lib'))
        if (RegExp(r'localhost|10\.0\.2\.2|TF_API_BASE|package:dio').hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(hits, isEmpty);
  });

  test('the only hosts named in app code are YouTube/Google video hosts and the Claude API', () {
    const allowed = {'api.anthropic.com', 'www.youtube.com', 'i.ytimg.com', 'img.youtube.com'};
    final hosts = <String>{
      for (final f in _dartFiles('lib'))
        for (final m in RegExp(r'https?://([a-zA-Z0-9.-]+)').allMatches(f.readAsStringSync())) m.group(1)!,
    };
    expect(hosts.difference(allowed), isEmpty);
  });
}
