import 'package:dio/dio.dart';

import '../models/feed.dart';
import '../models/resolved_video.dart';
import 'config.dart';

/// Thrown when /resolve returns {"error": "resolve_failed", "retry_after": N}.
class ResolveFailed implements Exception {
  ResolveFailed(this.retryAfterSec);
  final int retryAfterSec;
  @override
  String toString() => 'ResolveFailed(retry in ${retryAfterSec}s)';
}

/// Thin HTTP client for the personal backend. No auth, no analytics headers.
class ApiClient {
  ApiClient({Dio? dio, String baseUrl = apiBase})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 10),
              // yt-dlp resolution can take up to 20s server-side.
              receiveTimeout: const Duration(seconds: 30),
            ));

  final Dio _dio;

  Future<FeedResponse> longformFeed() async {
    final r = await _dio.get<Map<String, dynamic>>('/feed/longform');
    return FeedResponse.fromJson(r.data!);
  }

  Future<ResolvedVideo> resolve(String videoId) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/resolve', queryParameters: {'video_id': videoId});
      return ResolvedVideo.fromJson(r.data!);
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['error'] == 'resolve_failed') {
        throw ResolveFailed((data['retry_after'] as num?)?.toInt() ?? 30);
      }
      rethrow;
    }
  }

  /// Fetches a caption file (VTT/SRT) as text.
  Future<String> fetchText(String url) async {
    final r = await Dio().get<String>(url, options: Options(responseType: ResponseType.plain));
    return r.data ?? '';
  }
}
