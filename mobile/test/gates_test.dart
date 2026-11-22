import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/gates.dart';

class _FakeModel implements JsonModel {
  _FakeModel(this.reply);
  final Map<String, dynamic> Function(String system, List<LlmContent> content) reply;
  final calls = <List<LlmContent>>[];
  @override
  Future<Map<String, dynamic>> generateJson({
    required String system,
    required List<LlmContent> content,
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

    test('Hindi written in English letters (Hinglish) fails; plain English with similar words passes', () {
      expect(metadataIsEnglish('Integration by parts kaise karte hain', 'A calculus lesson.'), isFalse);
      expect(metadataIsEnglish('Echo kya hai? Class 9 Physics', ''), isFalse);
      expect(metadataIsEnglish('Echo | Class 9 Physics',
          'Is video mein hum echo ke baare mein padhenge aur numericals bhi karenge.'), isFalse);
      // English that happens to contain a short word from the list.
      expect(metadataIsEnglish('Why do power lines hum? The physics of mains hum', ''), isTrue);
      expect(metadataIsEnglish('Kinetic energy (KE) and potential energy explained', ''), isTrue);

      final hinglish = transcriptLanguage([
        'toh dosto aaj hum integration by parts ke baare mein baat karenge',
        'yeh formula bahut important hai exam ke liye',
        'pehle hum u aur v choose karte hain jaise maine bataya tha',
        'phir derivative nikalte hain aur integral lagate hain bilkul simple',
        'agar aapko samajh aa gaya toh video ko like kar dijiye',
      ]);
      expect(hinglish.isEnglish, isFalse);
      expect(transcriptLanguage(_englishTranscript).isEnglish, isTrue);
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

  group('Gates 1 + 2: trusted channels, concept coverage, model check', () {
    test('trusted channel matching', () {
      expect(isTrustedChannel('3Blue1Brown'), isTrue);
      expect(isTrustedChannel(' Khan Academy '), isTrue);
      expect(isTrustedChannel('Random Uploads 123'), isFalse);
      expect(isTrustedChannel(null), isFalse);
    });

    test('coversConcept: title, close title, or repeated in transcript', () {
      const names = ['Integration by Parts', 'IBP'];
      expect(coversConcept(names, title: 'Integration by parts explained', description: '', transcript: ''), isTrue);
      expect(coversConcept(names, title: 'Parts, integration by: a guide', description: '', transcript: ''), isTrue);
      expect(coversConcept(names, title: 'Calculus 2 lecture 4', description: '',
          transcript: 'today integration by parts. more integration by parts later'), isTrue);
      expect(coversConcept(names, title: 'Limits intro', description: '', transcript: 'limits of functions'), isFalse);
    });

    test('classifyVideo sends a short prompt and parses the verdict', () async {
      final model = _FakeModel((s, c) => {
            'educational': true, 'safe': true, 'on_topic': true, 'is_theorem': false, 'language': 'EN',
          });
      final v = await classifyVideo(model,
          searchedConcept: 'Integration by Parts', title: 'IBP', description: 'd' * 5000,
          transcriptExcerpt: 't' * 5000, durationSec: 600, channel: 'Someone');
      expect(v.educational && v.safe && v.onTopic && v.english, isTrue);
      final text = (model.calls.single.single as TextContent).text;
      expect(text, contains('Searched concept: Integration by Parts'));
      expect(text.length, lessThan(1200)); // a short prompt: reading it dominates on a phone
      // Booleans only: the answer is a few dozen tokens.
      final props = (videoCheckSchema['properties']! as Map).values.cast<Map>();
      expect(props.every((p) => p['type'] == 'boolean' || p['enum'] != null), isTrue);
    });

    test('strongEvidence: name in the title and captions, plus lesson words or material context', () {
      const names = ['Echo'];
      const physicsTalk = 'an echo is sound reflected from a wall; the reflection arrives later';
      expect(strongEvidence(names, title: 'Echo | Class 9 Physics', description: '', transcript: physicsTalk), isTrue);
      expect(strongEvidence(names, title: 'Echo', description: '', transcript: physicsTalk,
          materialConcepts: ['Sound', 'Reflection', 'Pitch']), isTrue);
      // A song called "Echo": no lesson words, no other concepts from the material.
      expect(strongEvidence(names, title: 'Echo (Official Music Video)', description: 'Stream the new single',
          transcript: 'echo echo in my heart tonight', materialConcepts: ['Sound', 'Reflection', 'Pitch']), isFalse);
      // Title doesn't name it: never by rule.
      expect(strongEvidence(names, title: 'Physics class 9 full chapter', description: '', transcript: physicsTalk),
          isFalse);
    });
  });
}
