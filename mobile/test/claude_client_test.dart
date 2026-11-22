import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:theoremfeed/services/claude_client.dart';

http.Response _ok(Map<String, Object?> body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Map<String, Object?> _message(String text, {String stop = 'end_turn'}) => {
      'content': [
        {'type': 'thinking', 'thinking': ''},
        {'type': 'text', 'text': text},
      ],
      'stop_reason': stop,
    };

void main() {
  final schema = {
    'type': 'object',
    'properties': {'educational': {'type': 'boolean'}},
    'required': ['educational'],
    'additionalProperties': false,
  };

  test('sends the right request and parses structured JSON', () async {
    late http.Request sent;
    final client = ClaudeClient(
      apiKey: 'sk-test',
      httpClient: MockClient((req) async {
        sent = req;
        return _ok(_message('{"educational": true}'));
      }),
    );
    final out = await client.generateJson(
      system: 'sys',
      content: [TextContent('hello'), ImageUrlContent('https://i.ytimg.com/vi/x/hqdefault.jpg')],
      schema: schema,
    );
    expect(out, {'educational': true});
    expect(sent.headers['x-api-key'], 'sk-test');
    expect(sent.headers['anthropic-version'], '2026-10-21');
    expect(sent.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['model'], 'claude-opus-5-5');
    expect(body['fallbacks'], 'default');
    expect(body['output_config']['effort'], 'low');
    expect(body['output_config']['format']['type'], 'json_schema');
    expect(body.containsKey('thinking'), isFalse); // Opus 5.5: thinking always on; never send disabled
    expect(body['messages'][0]['content'][1], {
      'type': 'image',
      'source': {'type': 'url', 'url': 'https://i.ytimg.com/vi/x/hqdefault.jpg'},
    });
  });

  test('retries 429/529 honoring retry-after, then succeeds', () async {
    var calls = 0;
    final slept = <Duration>[];
    final client = ClaudeClient(
      apiKey: 'k',
      sleep: (d) async => slept.add(d),
      httpClient: MockClient((req) async {
        calls++;
        if (calls == 1) return http.Response('{"error":{"type":"rate_limit_error","message":"slow"}}', 429, headers: {'retry-after': '2'});
        if (calls == 2) return http.Response('{"error":{"type":"overloaded_error","message":"busy"}}', 529);
        return _ok(_message('{"educational": false}'));
      }),
    );
    expect(await client.generateJson(system: 's', content: [TextContent('x')], schema: schema), {'educational': false});
    expect(calls, 3);
    expect(slept.first, const Duration(seconds: 2));
  });

  test('does not retry 400/401 and surfaces the API error type', () async {
    var calls = 0;
    final client = ClaudeClient(
      apiKey: 'bad',
      sleep: (_) async {},
      httpClient: MockClient((req) async {
        calls++;
        return http.Response('{"error":{"type":"authentication_error","message":"invalid x-api-key"}}', 401);
      }),
    );
    await expectLater(
      client.generateJson(system: 's', content: [TextContent('x')], schema: schema),
      throwsA(isA<ClaudeApiError>().having((e) => e.isAuth, 'isAuth', isTrue)),
    );
    expect(calls, 1);
  });

  test('refusal stop reason raises ClaudeRefusal', () async {
    final client = ClaudeClient(
      apiKey: 'k',
      httpClient: MockClient((req) async => _ok({
            'content': <Object>[],
            'stop_reason': 'refusal',
            'stop_details': {'type': 'refusal', 'category': 'general_harms'},
          })),
    );
    await expectLater(
      client.generateJson(system: 's', content: [TextContent('x')], schema: schema),
      throwsA(isA<ClaudeRefusal>().having((e) => e.category, 'category', 'general_harms')),
    );
  });
}
