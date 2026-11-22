import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/concept_matcher.dart';
import 'package:theoremfeed/services/text_match.dart';

void main() {
  test('token_set_ratio behaves like rapidfuzz', () {
    expect(tokenSetRatio('integration by parts', 'Integration by Parts!'), 100);
    expect(tokenSetRatio('parts by integration', 'integration by parts'), 100);
    expect(tokenSetRatio('integraton by part', 'integration by parts'), greaterThan(85));
    expect(tokenSetRatio('fourier series', 'taylor series'), lessThan(85));
    expect(normalizeText("Bayes' Theorem"), normalizeText("Bayes's theorem"));
  });

  group('ConceptMatcher', () {
    late AppDatabase db;
    late ConceptMatcher m;
    setUp(() {
      db = AppDatabase.inMemory();
      for (final (id, name, aliases) in [
        ('ibp', 'Integration by Parts', '["IBP", "integration by parts formula"]'),
        ('taylor', 'Taylor Series', '["Taylor expansion"]'),
        ('fourier', 'Fourier Series', '[]'),
        ('bayes', "Bayes' Theorem", '["Bayes rule"]'),
        ('pyth', 'Pythagorean Theorem', '["Pythagoras theorem"]'),
      ]) {
        db.execute("INSERT INTO concepts (id, canonical_name, aliases, type, subject) VALUES (?, ?, ?, 'theorem', 'math')",
            [id, name, aliases]);
      }
      m = ConceptMatcher(db);
    });

    test('exact names and aliases', () {
      expect(m.match('integration by parts')?.id, 'ibp');
      expect(m.match('IBP')?.id, 'ibp');
      expect(m.match('Taylor expansion')?.id, 'taylor');
      expect(m.match("Bayes's theorem")?.id, 'bayes');
      expect(m.match('Bayes rule')?.id, 'bayes');
    });

    test('typos and word order', () {
      expect(m.match('integraton by part')?.id, 'ibp');
      expect(m.match('Pythagoras Theorem')?.id, 'pyth');
      expect(m.match('pythagorean theorm')?.id, 'pyth');
    });

    test('no false matches between different concepts', () {
      expect(m.match('Series'), isNull);
      expect(m.match('Laplace Transform'), isNull);
      expect(m.match('Fourier transform'), isNull);
      expect(m.match('Taylor Series')?.id, 'taylor');
    });

    test('matchAll dedupes', () {
      expect(m.matchAll(['IBP', 'Integration by parts', 'Fourier series']).map((r) => r.id), ['ibp', 'fourier']);
    });
  });
}
