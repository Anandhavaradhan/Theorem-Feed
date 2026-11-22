import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/services/claude_client.dart';
import 'package:theoremfeed/services/gates.dart';

class _FakeModel implements JsonModel {
  _FakeModel(this.reply);
  final Map<String, dynamic> Function(String system, List<ClaudeContent> content) reply;
  final calls = <List<ClaudeContent>>[];
  @override
  Future<Map<String, dynamic>> generateJson({
    required String system,
    required List<ClaudeContent> content,
    required Map<String, Object?> schema,
    String effort = 'low',
    int maxTokens = 4096,
  }) async {
    calls.add(content);
    return reply(system, content);
  }
}

const _englishTranscript = [
  'so in this video we are going to look at integration by parts',
  'which is a technique for integrating a product of two functions',
  'the idea comes from the product rule for derivatives',
  'if we take u times v and differentiate we get u prime v plus u v prime',
  'now integrate both sides and rearrange and we get the formula',
  'the integral of u dv equals u v minus the integral of v du',
  'let us try an example with x times e to the x',
  'we choose u equal to x because its derivative is simpler',
];

void main() {
  group('Gate 3: English', () {
    test('English titles pass; foreign-script and reliable foreign titles fail', () {
      expect(metadataIsEnglish('Integration by parts explained | Calculus', ''), isTrue);
      expect(metadataIsEnglish('Bayes theorem, the geometry of changing beliefs', 'Perhaps the most important formula in probability.'), isTrue);
      expect(metadataIsEnglish('Taylor series', ''), isTrue); // short + unreliable → not rejected here
      expect(metadataIsEnglish('आंशिक समाकलन की विधि को समझें', ''), isFalse);
      expect(metadataIsEnglish('Die Taylorreihe einfach erklärt mit Beispielen', ''), isFalse);
      expect(metadataIsEnglish('积分的分部积分法', ''), isFalse);
    });

    test('English transcript passes', () {
      final r = transcriptLanguage(_englishTranscript);
      expect(r.chunks, greaterThan(3));
      expect(r.isEnglish, isTrue);
    });

    test('Spanish and Hindi transcripts fail', () {
      final es = transcriptLanguage([
        'en este video vamos a estudiar la integración por partes',
        'que es una técnica para integrar el producto de dos funciones',
        'la idea viene de la regla del producto para las derivadas',
        'si derivamos el producto de u por v obtenemos la fórmula',
        'ahora integramos ambos lados y reorganizamos los términos',
      ]);
      expect(es.isEnglish, isFalse);
      final hi = transcriptLanguage([
        'इस वीडियो में हम आंशिक समाकलन के बारे में पढ़ेंगे',
        'यह दो फलनों के गुणनफल को समाकलित करने की विधि है',
        'हम उदाहरण के साथ इसे समझेंगे और सूत्र को सिद्ध करेंगे',
      ]);
      expect(hi.isEnglish, isFalse);
    });

    test('mixed transcript over 15% non-English fails', () {
      final mixed = [
        ..._englishTranscript.take(4),
        'आंशिक समाकलन के बारे में हम अब विस्तार से बात करेंगे दोस्तों',
        'यह दो फलनों के गुणनफल को समाकलित करने की विधि है समझिए',
      ];
      expect(transcriptLanguage(mixed).isEnglish, isFalse);
    });

    test('Whisper transcript decision', () {
      expect(speechIsEnglish(_englishTranscript.take(3).join(' ')), isTrue);
      expect(speechIsEnglish('इस वीडियो में हम आंशिक समाकलन के बारे में पढ़ेंगे यह दो फलनों के गुणनफल'), isFalse);
      expect(speechIsEnglish('[Music]'), isFalse); // can't verify → reject
    });
  });

  group('Gate 2: safety keywords', () {
    test('flags unsafe terms; leaves math vocabulary alone', () {
      expect(unsafeKeyword('NSFW compilation'), 'NSFW');
      expect(unsafeKeyword('beheading video'), 'beheading');
      for (final ok in ['Möbius strip explained', 'Sexy primes and prime gaps', 'Visible to the naked eye',
        'Shooting stars and meteors', 'The Killing form of a Lie algebra', 'Pornographic? No: polynomials']) {
        expect(unsafeKeyword(ok.replaceAll('Pornographic? No: ', '')), isNull, reason: ok);
      }
    });
  });

  group('Gate 1 + 2b (LLM)', () {
    test('educational verdict parsing and request content', () async {
      final model = _FakeModel((s, c) => {
            'educational': true, 'reason': 'teaches IBP', 'subject': 'math', 'is_theorem': false,
            'is_short': false, 'primary_concepts': ['Integration by Parts'], 'text_language': 'EN',
          });
      final v = await classifyEducational(model,
          searchedConcept: 'Integration by Parts', title: 'IBP', description: 'd', transcriptExcerpt: 't', durationSec: 600);
      expect(v.educational, isTrue);
      expect(v.textLanguage, 'en');
      expect(v.primaryConcepts, ['Integration by Parts']);
      expect((model.calls.single.single as TextContent).text, contains('Searched concept: Integration by Parts'));
    });

    test('thumbnail: safe, unsafe, and refusal', () async {
      expect(await thumbnailSafetyIssue(_FakeModel((s, c) => {'safe': true, 'reason': ''}), 'u'), isNull);
      expect(await thumbnailSafetyIssue(_FakeModel((s, c) => {'safe': false, 'reason': 'gore'}), 'u'), 'gore');
      expect(await thumbnailSafetyIssue(_FakeModel((s, c) => throw ClaudeRefusal('general_harms')), 'u'),
          contains('refusal'));
    });
  });
}
