/// The on-device language model (llama.cpp via llamadart). Free, no API key,
/// no rate limits; nothing but the one-time model download leaves the phone.
///
/// Small by design: the jobs it does (is this a lesson on X? which concepts
/// does this clear PDF section define?) are narrow, and every output is
/// constrained to a JSON schema during decoding, so even a sub-1B model
/// returns well-formed answers.
library;

import 'dart:async';

import 'package:llamadart/llamadart.dart';

import 'llm.dart';

class LocalModelSpec {
  const LocalModelSpec({required this.source, required this.name, required this.approxSizeMb});
  final String source; // hf://owner/repo/file.gguf
  final String name;
  final int approxSizeMb;
}

/// Qwen3.5 0.8B, 4-bit: the smallest widely used instruct model that follows
/// schema-constrained classification and extraction prompts reliably.
const defaultLocalModel = LocalModelSpec(
  source: 'hf://unsloth/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q4_K_M.gguf',
  name: 'Qwen3.5 0.8B (4-bit)',
  approxSizeMb: 530,
);

class LocalLlmModel implements JsonModel {
  LocalLlmModel({this.spec = defaultLocalModel, this.contextSize = 4096});

  final LocalModelSpec spec;
  final int contextSize;
  LlamaEngine? _engine;
  Future<LlamaEngine>? _loading;
  Future<void> _queue = Future.value(); // one generation at a time

  bool get isLoaded => _engine != null;

  /// Downloads the model on first use (then reuses the cached file) and loads it.
  /// [onProgress] receives a 0..1 fraction while downloading, or null if unknown.
  Future<void> ensureLoaded({void Function(double? fraction)? onProgress}) async {
    if (_engine != null) return;
    _loading ??= LlamaEngine.load(
      LlamaModel(ModelSource.parse(spec.source)),
      params: ModelParams(contextSize: contextSize),
      onProgress: (p) => onProgress?.call(p.fraction),
    ).then((e) => _engine = e).whenComplete(() => _loading = null);
    try {
      await _loading;
    } on LlamaException catch (e) {
      throw ModelApiError(0, 'local_model_load', '$e');
    }
  }

  @override
  Future<Map<String, dynamic>> generateJson({
    required String system,
    required List<LlmContent> content,
    required Map<String, Object?> schema,
    String effort = 'low',
    int maxTokens = 512,
  }) {
    final result = _queue.then((_) => _generate(system, content, schema, maxTokens));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, dynamic>> _generate(
      String system, List<LlmContent> content, Map<String, Object?> schema, int maxTokens) async {
    await ensureLoaded();
    // Text only: this model has no vision. Image parts are skipped.
    final text = [for (final c in content) if (c is TextContent) c.text].join('\n\n');
    try {
      return await _engine!.createStructuredJson<Map<String, dynamic>>(
        [
          LlamaChatMessage.fromText(role: LlamaChatRole.system, text: system),
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: text),
        ],
        output: LlamaStructuredOutput<Map<String, dynamic>>.jsonSchema(
          schema: Map<String, dynamic>.from(schema),
          decoder: (json) => json,
        ),
        params: GenerationParams(maxTokens: maxTokens, temp: 0),
        enableThinking: false,
      );
    } on LlamaException catch (e) {
      throw ModelApiError(0, 'local_model', '$e');
    }
  }

  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
  }
}
