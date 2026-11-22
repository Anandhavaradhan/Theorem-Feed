/// The three ingestion gates (§8.3), running on the phone.
///
///   Gate 1  Educational   – Claude classifier (strict).
///   Gate 2  Safety        – keyword filter + Claude thumbnail moderation.
///   Gate 3  English       – on-device language ID on title/description and
///                           transcript; Whisper tiny on the first 30 s of audio
///                           when there is no transcript. Hard reject.
///
/// The ingestion service runs the cheap, local checks first (keywords, title
/// language) so obviously-failing candidates never cost an API call; the accept
/// set is the same as running the gates in spec order.
library;

import 'package:fast_language_detector/fast_language_detector.dart';

import 'claude_client.dart';

// --- Gate 3: English ---------------------------------------------------------

/// Share of letters that are Latin script (a–z with accents). Hindi, Chinese,
/// Arabic, Cyrillic etc. drive this toward 0.
double latinLetterShare(String text) {
  var latin = 0, letters = 0;
  for (final r in text.runes) {
    final ch = String.fromCharCode(r);
    if (RegExp(r'\p{L}', unicode: true).hasMatch(ch)) {
      letters++;
      if (RegExp(r'[A-Za-zÀ-ɏ]').hasMatch(ch)) latin++;
    }
  }
  return letters == 0 ? 1 : latin / letters;
}

int _wordCount(String s) => RegExp(r'[A-Za-z\p{L}]{2,}', unicode: true).allMatches(s).length;

/// The detector's scores are not calibrated probabilities (clear English scores
/// ~0.5–0.6), so the spec's "non-en with p > 0.8" becomes: the detector is
/// *reliably* non-English, or the text is mostly non-Latin script.
bool isConfidentlyNonEnglish(String text) {
  if (_wordCount(text) == 0) return false;
  if (latinLetterShare(text) < 0.7) return true;
  final r = LanguageDetector.detect(text);
  return r != null && r.code != 'en' && r.isReliable;
}

/// Title + description check (spec: reject if non-en with high confidence).
bool metadataIsEnglish(String title, String description) =>
    !isConfidentlyNonEnglish('$title\n${description.length > 600 ? description.substring(0, 600) : description}');

/// Transcript check: split into chunks of ≥ 8 words (single caption lines are
/// too short to identify); reject if > 15% of identifiable chunks are non-English.
class TranscriptLanguage {
  TranscriptLanguage(this.chunks, this.nonEnglish);
  final int chunks;
  final int nonEnglish;
  double get nonEnglishShare => chunks == 0 ? 0 : nonEnglish / chunks;
  bool get isEnglish => nonEnglishShare <= 0.15;
}

TranscriptLanguage transcriptLanguage(List<String> lines) {
  final chunks = <String>[];
  final buf = StringBuffer();
  for (final line in lines) {
    buf.write('$line ');
    if (_wordCount(buf.toString()) >= 8) {
      chunks.add(buf.toString());
      buf.clear();
    }
  }
  if (_wordCount(buf.toString()) >= 4) chunks.add(buf.toString());

  var counted = 0, nonEn = 0;
  for (final c in chunks) {
    // Mostly-math chunks ("f of x equals x squared") can misdetect; only count
    // chunks the detector is reliable about, or that are clearly non-Latin.
    final nonLatin = latinLetterShare(c) < 0.7;
    final r = LanguageDetector.detect(c);
    if (nonLatin || (r != null && r.isReliable)) {
      counted++;
      if (nonLatin || r!.code != 'en') nonEn++;
    }
  }
  return TranscriptLanguage(counted, nonEn);
}

/// Spoken-language probe for videos with no transcript (Whisper tiny, first 30 s).
abstract class SpeechLanguageProbe {
  /// Returns the transcribed text of the clip, or null if it couldn't be probed.
  Future<String?> transcribeClip(String audioFilePath);
}

/// Decides English from a Whisper transcript (`lang: 'auto'`, so the text comes
/// back in the spoken language) using the same on-device detector.
bool speechIsEnglish(String transcribed) {
  if (_wordCount(transcribed) < 4) return false; // silence/music: can't verify → reject
  final r = transcriptLanguage([transcribed]);
  if (r.chunks == 0) {
    final d = LanguageDetector.detect(transcribed);
    return d?.code == 'en';
  }
  return r.isEnglish;
}

// --- Gate 2a: safety keywords --------------------------------------------------

const _unsafeTerms = [
  // Deliberately excludes words with real math/science uses: Möbius strip,
  // sexy primes, naked eye, shooting stars, killing form.
  'nsfw', 'porn', 'porno', 'pornography', 'xxx', 'nude', 'nudes', 'nudity', 'onlyfans', 'hentai',
  'erotic', 'stripper', 'gore', 'gory', 'beheading', 'execution video', 'murder',
  'terrorist', 'terrorism', 'jihad', 'isis', 'nazi', 'kkk', 'white power', 'genocide', 'massacre', 'self harm',
  'self-harm', 'suicide', 'hate speech', 'racist', 'slur',
];
final _unsafeRe = RegExp('\\b(${_unsafeTerms.map(RegExp.escape).join('|')})\\b', caseSensitive: false);

/// Returns the first unsafe term found, or null.
String? unsafeKeyword(String text) => _unsafeRe.firstMatch(text)?.group(0);

// --- Gate 1: educational (LLM) ------------------------------------------------

const educationalSystemPrompt = '''
Strict educational gatekeeper. EDUCATIONAL only if the video primarily teaches a concept, proof, technique, or theorem in math, science, or CS.
Reject: vlogs, entertainment, music, gaming, news, motivation, "study with me", and any video that only mentions an educational topic in passing.
Also report the language of the title and description as an ISO 639-1 code ("en" for English; Hinglish or other mixed/transliterated text is not "en").
Use concept names a textbook would use for primary_concepts. When the video primarily teaches the searched concept, include its name exactly as given.''';

const educationalSchema = {
  'type': 'object',
  'properties': {
    'educational': {'type': 'boolean'},
    'reason': {'type': 'string'},
    'subject': {'type': 'string', 'enum': ['math', 'physics', 'cs', 'other']},
    'is_theorem': {'type': 'boolean'},
    'is_short': {'type': 'boolean'},
    'primary_concepts': {'type': 'array', 'items': {'type': 'string'}},
    'text_language': {'type': 'string'},
  },
  'required': ['educational', 'reason', 'subject', 'is_theorem', 'is_short', 'primary_concepts', 'text_language'],
  'additionalProperties': false,
};

class EducationalVerdict {
  EducationalVerdict({
    required this.educational,
    required this.reason,
    required this.subject,
    required this.isTheorem,
    required this.isShort,
    required this.primaryConcepts,
    required this.textLanguage,
  });

  final bool educational;
  final String reason;
  final String subject;
  final bool isTheorem;
  final bool isShort;
  final List<String> primaryConcepts;
  final String textLanguage;

  factory EducationalVerdict.fromJson(Map<String, dynamic> j) => EducationalVerdict(
        educational: j['educational'] as bool,
        reason: j['reason'] as String,
        subject: j['subject'] as String,
        isTheorem: j['is_theorem'] as bool,
        isShort: j['is_short'] as bool,
        primaryConcepts: (j['primary_concepts'] as List).cast<String>(),
        textLanguage: (j['text_language'] as String).toLowerCase(),
      );
}

Future<EducationalVerdict> classifyEducational(
  JsonModel model, {
  required String searchedConcept,
  required String title,
  required String description,
  required String transcriptExcerpt,
  required int? durationSec,
}) async {
  final desc = description.length > 1500 ? description.substring(0, 1500) : description;
  final json = await model.generateJson(
    system: educationalSystemPrompt,
    content: [
      TextContent('''
Searched concept: $searchedConcept
Duration: ${durationSec ?? 'unknown'} seconds

<title>$title</title>
<description>$desc</description>
<transcript_excerpt>$transcriptExcerpt</transcript_excerpt>'''),
    ],
    schema: educationalSchema,
    maxTokens: 2048,
  );
  return EducationalVerdict.fromJson(json);
}

// --- Gate 2b: thumbnail moderation (LLM vision) -------------------------------

const thumbnailSystemPrompt = '''
You review video thumbnails for a personal study app. Mark the thumbnail unsafe if it shows sexual or suggestive content, nudity, graphic violence or gore, hate symbols, or other content inappropriate for a study app. Ordinary educational imagery (people talking, equations, diagrams, text) is safe.''';

const thumbnailSchema = {
  'type': 'object',
  'properties': {
    'safe': {'type': 'boolean'},
    'reason': {'type': 'string'},
  },
  'required': ['safe', 'reason'],
  'additionalProperties': false,
};

/// Returns null if safe, otherwise the reason. A refusal counts as unsafe.
Future<String?> thumbnailSafetyIssue(JsonModel model, String thumbnailUrl) async {
  try {
    final j = await model.generateJson(
      system: thumbnailSystemPrompt,
      content: [ImageUrlContent(thumbnailUrl), TextContent('Is this thumbnail safe?')],
      schema: thumbnailSchema,
      maxTokens: 1024,
    );
    return j['safe'] == true ? null : (j['reason'] as String? ?? 'unsafe thumbnail');
  } on ClaudeRefusal catch (e) {
    return 'moderation refusal (${e.category ?? 'unspecified'})';
  }
}
