import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// en-US only. One strings file, one helper. No i18n framework (by design).
class Strings {
  Strings._();
  static Map<String, String> _strings = const {};

  static Future<void> load() async {
    final raw = await rootBundle.loadString('assets/i18n/en.json');
    _strings = (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as String));
  }

  /// Test hook.
  static void debugSet(Map<String, String> strings) => _strings = strings;

  static String t(String key, [Map<String, Object> params = const {}]) {
    var s = _strings[key] ?? key;
    params.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
    return s;
  }
}

String t(String key, [Map<String, Object> params = const {}]) => Strings.t(key, params);
