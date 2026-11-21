import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test("every t('key') used in lib/ exists in assets/i18n/en.json", () {
    final strings = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    final used = <String>{};
    final re = RegExp(r"""\bt\(\s*'([a-z0-9_.]+)'""");
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      used.addAll(re.allMatches(f.readAsStringSync()).map((m) => m.group(1)!));
    }
    expect(used, isNotEmpty);
    expect(used.difference(strings.keys.toSet()), isEmpty);
  });
}
