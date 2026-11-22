/// Minimal Claude Messages API client (raw HTTPS; Dart has no official SDK).
///
/// The phone calls api.anthropic.com directly with the user's own API key.
/// No other server is involved.
///
/// Every call returns schema-validated JSON via structured outputs
/// (`output_config.format`). Server-side refusal fallbacks are enabled; a
/// response that still ends in `refusal` raises [ModelRefusal], which callers
/// treat conservatively (e.g. the safety gate rejects).
///
/// Optional provider: the default is the free Gemini tier (gemini_client.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'llm.dart';

const claudeModel = 'claude-opus-5-5';
const _apiUrl = 'https://api.anthropic.com/v1/messages';
const _apiVersion = '2026-10-21';
const _fallbackBeta = 'server-side-fallback-2026-07-01';

class ClaudeClient implements JsonModel {
  ClaudeClient({
    required this.apiKey,
    http.Client? httpClient,
    this.model = claudeModel,
    this.maxRetries = 3,
    this.timeout = const Duration(seconds: 90),
    Future<void> Function(Duration)? sleep,
  })  : _http = httpClient ?? http.Client(),
        _sleep = sleep ?? Future<void>.delayed;

  final String apiKey;
  final String model;
  final int maxRetries;
  final Duration timeout;
  final http.Client _http;
  final Future<void> Function(Duration) _sleep;

  @override
  Future<Map<String, dynamic>> generateJson({
    required String system,
    required List<LlmContent> content,
    required Map<String, Object?> schema,
    String effort = 'low',
    int maxTokens = 4096,
  }) async {
    final body = jsonEncode({
      'model': model,
      'max_tokens': maxTokens,
      'system': system,
      'messages': [
        {'role': 'user', 'content': content.map(_block).toList()},
      ],
      'output_config': {
        'effort': effort,
        'format': {'type': 'json_schema', 'schema': schema},
      },
      'fallbacks': 'default',
    });

    final response = await _postWithRetries(body);
    final stop = response['stop_reason'];
    if (stop == 'refusal') {
      throw ModelRefusal((response['stop_details'] as Map?)?['category'] as String?);
    }
    if (stop == 'max_tokens') {
      throw ModelApiError(200, 'max_tokens', 'response truncated at max_tokens=$maxTokens');
    }
    final text = [
      for (final block in (response['content'] as List).cast<Map<String, dynamic>>())
        if (block['type'] == 'text') block['text'] as String,
    ].join();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  static Map<String, Object?> _block(LlmContent c) => switch (c) {
        TextContent(:final text) => {'type': 'text', 'text': text},
        ImageUrlContent(:final url) => {
            'type': 'image',
            'source': {'type': 'url', 'url': url},
          },
      };

  Future<Map<String, dynamic>> _postWithRetries(String body) async {
    for (var attempt = 0;; attempt++) {
      http.Response res;
      try {
        res = await _http
            .post(
              Uri.parse(_apiUrl),
              headers: {
                'content-type': 'application/json',
                'x-api-key': apiKey,
                'anthropic-version': _apiVersion,
                'anthropic-beta': _fallbackBeta,
              },
              body: body,
            )
            .timeout(timeout);
      } on TimeoutException {
        if (attempt >= maxRetries) rethrow;
        await _sleep(_backoff(attempt, null));
        continue;
      } on SocketException {
        if (attempt >= maxRetries) rethrow;
        await _sleep(_backoff(attempt, null));
        continue;
      } on http.ClientException {
        if (attempt >= maxRetries) rethrow;
        await _sleep(_backoff(attempt, null));
        continue;
      }

      if (res.statusCode == 200) return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;

      final retryable = res.headers['x-should-retry'] != 'false' &&
          (res.statusCode == 408 || res.statusCode == 409 || res.statusCode == 429 || res.statusCode >= 500);
      if (retryable && attempt < maxRetries) {
        await _sleep(_backoff(attempt, res.headers['retry-after']));
        continue;
      }
      var type = 'http_error';
      var message = res.body;
      try {
        final err = (jsonDecode(res.body) as Map<String, dynamic>)['error'] as Map<String, dynamic>;
        type = err['type'] as String? ?? type;
        message = err['message'] as String? ?? message;
      } catch (_) {}
      throw ModelApiError(res.statusCode, type, message, isAuth: res.statusCode == 401 || res.statusCode == 403);
    }
  }

  Duration _backoff(int attempt, String? retryAfter) {
    final s = double.tryParse(retryAfter ?? '');
    if (s != null) return Duration(milliseconds: (s * 1000).round());
    final base = 1000 * math.pow(2, attempt);
    return Duration(milliseconds: base.round() + math.Random().nextInt(500));
  }

  void close() => _http.close();
}
