/// Provider-neutral interface for the few LLM calls the app makes
/// (classification now; PDF extraction and relevance judging later).
///
/// Implementations: [GeminiClient] (free tier, the default) and [ClaudeClient].
library;

/// A text or image content block for the single user turn.
sealed class LlmContent {}

class TextContent extends LlmContent {
  TextContent(this.text);
  final String text;
}

/// An image the provider should look at, given by URL. Providers that can't
/// fetch URLs themselves download the bytes and send them inline.
class ImageUrlContent extends LlmContent {
  ImageUrlContent(this.url);
  final String url;
}

/// HTTP/API failure. [isAuth] means the key is missing, invalid or not allowed.
class ModelApiError implements Exception {
  ModelApiError(this.status, this.type, this.message, {this.isAuth = false});
  final int status;
  final String type;
  final String message;
  final bool isAuth;
  @override
  String toString() => 'ModelApiError($status $type: $message)';
}

/// The model declined (safety block / refusal). Callers treat this conservatively.
class ModelRefusal implements Exception {
  ModelRefusal(this.category);
  final String? category;
  @override
  String toString() => 'ModelRefusal($category)';
}

/// A free tier's daily quota is used up. Long runs stop and resume later.
class QuotaExhausted implements Exception {
  QuotaExhausted(this.message);
  final String message;
  @override
  String toString() => 'QuotaExhausted($message)';
}

abstract class JsonModel {
  /// Returns JSON conforming to [schema] (standard JSON Schema: type, properties,
  /// required, enum, items, additionalProperties: false).
  Future<Map<String, dynamic>> generateJson({
    required String system,
    required List<LlmContent> content,
    required Map<String, Object?> schema,
    String effort = 'low',
    int maxTokens = 4096,
  });
}
