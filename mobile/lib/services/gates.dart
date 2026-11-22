/// The three ingestion gates (§8.3), running on the phone.
///
///   Gate 1  Educational   – trusted-channel rule, else the on-device model.
///   Gate 2  Safety        – keyword filter; trusted channels; the on-device
///                           model's text check for everything else.
///   Gate 3  English       – on-device language ID on title/description and
///                           transcript; Whisper tiny on the first 30 s of audio
///                           when there is no transcript. Hard reject.
///
/// Everything runs on the phone. The instant rule checks run first, so most
/// candidates are decided in milliseconds and the model only sees the rest.
library;

import 'package:fast_language_detector/fast_language_detector.dart';

import 'llm.dart';
import 'text_match.dart';

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

// --- Gate 1 / 2 by rule: trusted channels -----------------------------------

/// Established English-language educational channels. Their uploads pass the
/// educational and safety gates by rule (they still go through the English
/// gate and must actually be about the concept). Matched by channel name.
const trustedChannels = {
  // math
  '3blue1brown', 'khan academy', 'numberphile', 'numberphile2', 'mathologer', 'stand-up maths',
  'professor leonard', 'patrickjmt', 'the organic chemistry tutor', 'blackpenredpen', 'eddie woo',
  'dr. trefor bazett', 'dr trefor bazett', 'krista king', 'kristakingmath', 'nancypi', 'zach star',
  'flammable maths', 'mit opencourseware', 'socratica', 'reducible', 'stanford online', 'steve brunton',
  'statquest with josh starmer', 'michel van biezen', 'mathispower4u', 'professor dave explains',
  'math with mr. j', 'mathbff',
  // physics
  'minutephysics', 'physics girl', 'veritasium', 'crashcourse', 'flipping physics', 'dot physics',
  'pbs space time', 'sixty symbols', 'physics explained',
  // cs
  'computerphile', 'abdul bari', 'william fiset', 'back to back swe', 'neetcode', 'freecodecamp.org',
  'cs dojo', 'spanning tree', 'fireship',
};

bool isTrustedChannel(String? channel) =>
    channel != null && trustedChannels.contains(channel.trim().toLowerCase());

/// Whether a video is plainly about [names] (canonical name + aliases): the name
/// is in the title, or close to it, or it's said repeatedly in the transcript.
bool coversConcept(List<String> names,
    {required String title, required String description, required String transcript}) {
  final t = normalizeText(title);
  final tr = normalizeText(transcript);
  for (final n in names) {
    final nn = normalizeText(n);
    if (nn.length < 3) continue;
    final word = RegExp('\\b${RegExp.escape(nn)}\\b');
    if (word.hasMatch(t)) return true;
    if (nn.split(' ').length > 1 && tokenSetRatio(nn, t) >= 90) return true;
    if (word.allMatches(tr).length >= 2) return true;
  }
  return false;
}

// --- Gate 1 + 2 by model: one on-device call ----------------------------------

const videoCheckSystemPrompt = '''
You check YouTube videos for a study app. Answer with JSON only.
educational: true only if the video mainly teaches a concept, proof, technique or theorem in math, science or computer science. False for vlogs, entertainment, music, gaming, news, motivation, "study with me", or videos that only mention the topic.
safe: false if the title, description or transcript has sexual, violent, hateful or otherwise inappropriate content.
text_language: ISO 639-1 code of the title and description ("en" for English; mixed Hindi-English is "hi").
is_theorem: true if it states or proves a specific theorem, formula or result.
primary_concepts: the 1-3 concepts it mainly teaches, using textbook names. If it mainly teaches the searched concept, include that name exactly.''';

const videoCheckSchema = {
  'type': 'object',
  'properties': {
    'educational': {'type': 'boolean'},
    'safe': {'type': 'boolean'},
    'subject': {'type': 'string', 'enum': ['math', 'physics', 'cs', 'other']},
    'is_theorem': {'type': 'boolean'},
    'primary_concepts': {'type': 'array', 'items': {'type': 'string'}},
    'text_language': {'type': 'string'},
    'reason': {'type': 'string'},
  },
  'required': ['educational', 'safe', 'subject', 'is_theorem', 'primary_concepts', 'text_language', 'reason'],
  'additionalProperties': false,
};

class VideoVerdict {
  VideoVerdict({
    required this.educational,
    required this.safe,
    required this.reason,
    required this.subject,
    required this.isTheorem,
    required this.primaryConcepts,
    required this.textLanguage,
  });

  final bool educational;
  final bool safe;
  final String reason;
  final String subject;
  final bool isTheorem;
  final List<String> primaryConcepts;
  final String textLanguage;

  factory VideoVerdict.fromJson(Map<String, dynamic> j) => VideoVerdict(
        educational: j['educational'] as bool,
        safe: j['safe'] as bool,
        reason: j['reason'] as String? ?? '',
        subject: j['subject'] as String,
        isTheorem: j['is_theorem'] as bool,
        primaryConcepts: (j['primary_concepts'] as List).cast<String>(),
        textLanguage: (j['text_language'] as String).toLowerCase(),
      );
}

/// One on-device model call covering the educational and (text-based) safety
/// checks. Inputs are kept short so a sub-1B model answers in a second or two.
Future<VideoVerdict> classifyVideo(
  JsonModel model, {
  required String searchedConcept,
  required String title,
  required String description,
  required String transcriptExcerpt,
  required int? durationSec,
  String? channel,
}) async {
  String clip(String s, int n) => s.length > n ? s.substring(0, n) : s;
  final json = await model.generateJson(
    system: videoCheckSystemPrompt,
    content: [
      TextContent('Searched concept: $searchedConcept\n'
          'Channel: ${channel ?? 'unknown'}\n'
          'Duration: ${durationSec ?? 'unknown'} seconds\n'
          'Title: $title\n'
          'Description: ${clip(description, 500)}\n'
          'Transcript start: ${clip(transcriptExcerpt, 1200)}'),
    ],
    schema: videoCheckSchema,
    maxTokens: 256,
  );
  return VideoVerdict.fromJson(json);
}
