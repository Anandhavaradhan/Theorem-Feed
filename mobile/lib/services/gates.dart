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

// Hindi, Tamil, Telugu, Malayalam and Kannada written in English letters
// ("kaise karte hain", "enna solringa") read as English to a language
// detector. These are their common words that are not English words
// (ambiguous ones like "to", "the", "me", "an", "and" are left out).
const _hinglishWords = {
  // Tamil
  'enna', 'epdi', 'eppadi', 'ippo', 'ippadi', 'appadi', 'apdi', 'ipdi', 'naan', 'neenga', 'nee', 'romba', 'paakalam',
  'pakalam', 'paarunga', 'parunga', 'sollunga', 'solren', 'sollren', 'theriyuma', 'theriyum', 'vanakkam', 'iruku',
  'irukku', 'irukum', 'pannunga', 'panna', 'pannalam', 'nalla', 'inniki', 'innaiku', 'intha', 'antha', 'athu', 'ithu',
  'unga', 'namma', 'nambha', 'konjam', 'seri', 'sari', 'illa', 'illai', 'venum', 'vendam', 'vaanga', 'kandippa',
  'enga', 'ellam', 'ellarum', 'pathi', 'paathu', 'vidunga', 'mattum', 'aana', 'aprom', 'apram', 'kooda', 'thaan',
  'dhaan', 'nanba', 'nanbargale', 'puriyuma', 'puriyum', 'tamil', 'tanglish',
  // Telugu
  'ela', 'emiti', 'enti', 'meeru', 'nenu', 'chala', 'baga', 'ledu', 'undi', 'cheyyandi', 'chudandi', 'cheppandi',
  'telugu', 'manam', 'kada', 'avunu', 'kaadu', 'ippudu', 'tharvatha', 'kosam', 'lo',
  // Malayalam
  'enthanu', 'engane', 'ningal', 'njan', 'valare', 'undu', 'cheyyam', 'nokkam', 'malayalam',
  // Kannada
  'hegide', 'yenu', 'neevu', 'naanu', 'tumba', 'illi', 'alli', 'maadi', 'nodi', 'kannada', 'yaake',
  // Hindi
  'hai', 'hain', 'ka', 'ki', 'ke', 'ko', 'se', 'mein', 'aur', 'ye', 'yeh', 'wo', 'woh', 'kya', 'kaise', 'kyun',
  'kyon', 'nahi', 'nahin', 'bhi', 'toh', 'hota', 'hoti', 'hote', 'karte', 'karo', 'karna', 'karein', 'kare', 'kar',
  'raha', 'rahe', 'rahi', 'tha', 'thi', 'jaise', 'isko', 'isme', 'iska', 'iski', 'uska', 'uski', 'apne', 'aap',
  'tum', 'hum', 'bhai', 'dekho', 'samjho', 'samjhe', 'samjhiye', 'chaliye', 'chalo', 'accha', 'achha', 'acha',
  'matlab', 'sirf', 'bilkul', 'sabse', 'asaan', 'aasan', 'tarika', 'padhai', 'hindi', 'kijiye', 'sikhe', 'seekhe',
  'wala', 'wali', 'wale', 'ekdum', 'jaldi', 'bahut', 'zaroor', 'liye', 'kaun', 'kab', 'kitna', 'yaha', 'yahan',
  'waha', 'wahan', 'agar', 'lekin', 'phir', 'fir', 'abhi', 'sab', 'kuch', 'koi', 'saath', 'baat', 'samajh',
};

/// Share of words that are romanised-Hindi function words.
double hinglishShare(String text) {
  final words = RegExp(r"[a-z']+").allMatches(text.toLowerCase()).map((m) => m.group(0)!).toList();
  if (words.isEmpty) return 0;
  return words.where(_hinglishWords.contains).length / words.length;
}

/// Romanised Hindi: two or more different words of it making up at least 1 word
/// in 12, or (in a short title) a single unmistakable one.
bool isHinglish(String text, {bool short = false}) {
  final words = RegExp(r"[a-z']+").allMatches(text.toLowerCase()).map((m) => m.group(0)!).toList();
  final hits = words.where(_hinglishWords.contains).length;
  final distinct = words.where(_hinglishWords.contains).toSet().length;
  if (short &&
      words.any(const {
        'kaise', 'kya', 'hai', 'hain', 'nahi', 'karte', 'samjho', 'hindi', 'mein', // Hindi
        'enna', 'epdi', 'eppadi', 'tamil', 'sollunga', 'paakalam', 'theriyuma', 'puriyuma', // Tamil
        'telugu', 'emiti', 'ela', 'cheyyandi', // Telugu
        'malayalam', 'enthanu', 'engane', // Malayalam
        'kannada', 'hegide', // Kannada
      }.contains)) {
    return true;
  }
  return distinct >= 2 && hits / words.length >= 1 / 12;
}

/// Title + description check: not another language, and not English letters
/// spelling Hindi. English only.
bool metadataIsEnglish(String title, String description) {
  final desc = description.length > 600 ? description.substring(0, 600) : description;
  if (isConfidentlyNonEnglish('$title\n$desc')) return false;
  return !isHinglish(title, short: true) && !isHinglish(desc);
}

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
    final hinglish = hinglishShare(c) >= 0.15; // e.g. "toh yeh formula hai jo hum use karte hain"
    final r = LanguageDetector.detect(c);
    if (nonLatin || hinglish || (r != null && r.isReliable)) {
      counted++;
      if (nonLatin || hinglish || r!.code != 'en') nonEn++;
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

// --- Gates 1 + 2 by rule: strong evidence -------------------------------------

/// Words that mark a teaching video in a title or description.
final _eduCueRe = RegExp(
  r'\b(explained|explanation|explain|lecture|lesson|tutorial|class ?\d{1,2}|grade ?\d{1,2}|chapter|physics|'
  r'maths?|mathematics|calculus|algebra|geometry|trigonometry|statistics|probability|chemistry|'
  r'computer science|algorithms?|proof|prove|theorem|derivation|derive|formula|ncert|cbse|icse|igcse|gcse|'
  r'a-level|jee|neet|ap physics|ap calculus|olympiad|numericals?|solved examples?|worked examples?|'
  r'concept|introduction to|intro to|how to (solve|find|calculate)|crash course|revision|visuali[sz]ed?|intuition)\b',
  caseSensitive: false,
);

bool _nameInTitle(List<String> names, String title) {
  final t = normalizeText(title);
  for (final n in names) {
    final nn = normalizeText(n);
    if (nn.length < 3) continue;
    if (RegExp('\\b${RegExp.escape(nn)}s?\\b').hasMatch(t)) return true;
    if (nn.split(' ').length > 1 && tokenSetRatio(nn, t) >= 90) return true;
  }
  return false;
}

/// How many different [others] (other concepts from the same material) the
/// text mentions. A physics video on echoes says "sound", "reflection",
/// "frequency"; a song called "Echo" doesn't.
int contextHits(Iterable<String> others, String text) {
  final t = normalizeText(text);
  var hits = 0;
  for (final o in others) {
    final n = normalizeText(o);
    if (n.length < 4) continue;
    if (RegExp('\\b${RegExp.escape(n)}s?\\b').hasMatch(t)) hits++;
    if (hits >= 3) break;
  }
  return hits;
}

/// Accept without the model: the title names the concept, the captions say it,
/// and either the title/description reads as a lesson or the captions mention
/// at least 2 other concepts from the same material. (The safety-keyword and
/// English gates have already passed.)
bool strongEvidence(List<String> names,
    {required String title,
    required String description,
    required String transcript,
    Iterable<String> materialConcepts = const []}) {
  if (!_nameInTitle(names, title) || isHinglish(title, short: true)) return false;
  final tr = normalizeText(transcript);
  final said = names.any((n) {
    final nn = normalizeText(n);
    return nn.length >= 3 && RegExp('\\b${RegExp.escape(nn)}').hasMatch(tr);
  });
  if (!said) return false;
  return _eduCueRe.hasMatch(title) ||
      _eduCueRe.hasMatch(description.length > 600 ? description.substring(0, 600) : description) ||
      contextHits(materialConcepts, transcript) >= 2;
}

// --- Gate 1 + 2 by model: one short on-device call -----------------------------

const videoCheckSystemPrompt = '''
You check a YouTube video for a study app. Answer with JSON only.
educational: true only if it mainly teaches math, science or computer science. False for vlogs, entertainment, music, gaming, news, motivation, "study with me".
safe: false if anything is sexual, violent, hateful or otherwise inappropriate.
on_topic: true if it mainly teaches the searched concept.
is_theorem: true if it states or proves a specific theorem, formula or result.
language: "en" only if the title and description are plain English; "other" for any other language, including Hindi or Tamil written in English letters ("kaise karte hain", "enna solringa").''';

/// Booleans only: the answer is about 25 tokens, so a sub-1B model on a phone
/// CPU answers in a second or two instead of writing sentences.
const videoCheckSchema = {
  'type': 'object',
  'properties': {
    'educational': {'type': 'boolean'},
    'safe': {'type': 'boolean'},
    'on_topic': {'type': 'boolean'},
    'is_theorem': {'type': 'boolean'},
    'language': {'type': 'string', 'enum': ['en', 'other']},
  },
  'required': ['educational', 'safe', 'on_topic', 'is_theorem', 'language'],
  'additionalProperties': false,
};

class VideoVerdict {
  VideoVerdict({
    required this.educational,
    required this.safe,
    required this.onTopic,
    required this.isTheorem,
    required this.english,
  });

  final bool educational;
  final bool safe;
  final bool onTopic;
  final bool isTheorem;
  final bool english;

  factory VideoVerdict.fromJson(Map<String, dynamic> j) => VideoVerdict(
        educational: j['educational'] as bool,
        safe: j['safe'] as bool,
        onTopic: j['on_topic'] as bool,
        isTheorem: j['is_theorem'] as bool,
        english: (j['language'] as String).toLowerCase() == 'en',
      );
}

/// One on-device model call covering the educational, (text-based) safety and
/// topic checks. Inputs are kept short: reading the prompt dominates on a phone.
Future<VideoVerdict> classifyVideo(
  JsonModel model, {
  required String searchedConcept,
  required String title,
  required String description,
  required String transcriptExcerpt,
  required int? durationSec,
  String? channel,
}) async {
  String clip(String s, int n) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ');
    return t.length > n ? t.substring(0, n) : t;
  }

  final json = await model.generateJson(
    system: videoCheckSystemPrompt,
    content: [
      TextContent('Searched concept: $searchedConcept\n'
          'Channel: ${channel ?? 'unknown'}\n'
          'Duration: ${durationSec ?? 'unknown'} seconds\n'
          'Title: $title\n'
          'Description: ${clip(description, 300)}\n'
          'Transcript start: ${clip(transcriptExcerpt, 700)}'),
    ],
    schema: videoCheckSchema,
    maxTokens: 48,
  );
  return VideoVerdict.fromJson(json);
}
