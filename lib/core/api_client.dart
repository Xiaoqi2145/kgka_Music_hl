import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  String? token;
  String? t1;
  String? sessionId;

  Future<dynamic> get(String path, [Map<String, Object?> query = const {}]) {
    return _sendWithRetry(
      () => _client.get(AppConfig.apiUri(path, query), headers: _headers),
    );
  }

  /// 直接请求外部 URI（不经过 AppConfig.apiUri），返回原始 JSON。
  /// 用于跨平台 API 调用（如网易云 API）。
  Future<dynamic> getRaw(Uri uri) {
    return _sendWithRetry(
      () => _client.get(uri, headers: {'Accept': 'application/json'}),
    );
  }

  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
    bool allowRetry = false,
  }) {
    return _sendWithRetry(
      () => _client.post(
        AppConfig.apiUri(path, query),
        headers: _headers,
        body: body == null ? null : jsonEncode(body),
      ),
      allowRetry: allowRetry,
    );
  }

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };

    if (token case final value?) {
      //headers['Authorization'] = 'Bearer $value';
      headers['X-Kg-Session-Id'] = value;
    }
    if (t1 case final value?) {
      headers['t1'] = value;
    }
    if (sessionId case final value?) {
      headers['X-Kg-Session-Id'] = value;
    }

    return headers;
  }

  /// 为幂等请求提供有限重试、单次超时和总体 deadline。
  Future<dynamic> _sendWithRetry(
    Future<http.Response> Function() request, {
    int maxRetries = 2,
    bool allowRetry = true,
  }) async {
    const attemptTimeout = Duration(seconds: 15);
    const overallTimeout = Duration(seconds: 45);
    final deadline = DateTime.now().add(overallTimeout);

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('API request deadline exceeded');
      }
      try {
        final response = await request().timeout(
          remaining < attemptTimeout ? remaining : attemptTimeout,
        );
        final retryableStatus = const {
          500,
          502,
          503,
          504,
        }.contains(response.statusCode);
        if (allowRetry && retryableStatus && attempt < maxRetries) {
          await _waitBeforeRetry(response, attempt, deadline);
          continue;
        }
        return _processResponse(response);
      } on TimeoutException {
        if (!allowRetry || attempt >= maxRetries) rethrow;
        await _waitBeforeRetry(null, attempt, deadline);
      } on http.ClientException {
        if (!allowRetry || attempt >= maxRetries) rethrow;
        await _waitBeforeRetry(null, attempt, deadline);
      } on FormatException {
        rethrow;
      }
    }
    throw ApiException('请求失败，已重试 $maxRetries 次');
  }

  Future<void> _waitBeforeRetry(
    http.Response? response,
    int attempt,
    DateTime deadline,
  ) async {
    final retryAfter = int.tryParse(response?.headers['retry-after'] ?? '');
    final baseMs = retryAfter == null
        ? 500 * (1 << attempt)
        : (retryAfter * 1000).clamp(0, 15000);
    final jitterMs = math.Random().nextInt(250);
    final delay = Duration(milliseconds: baseMs + jitterMs);
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero)
      throw TimeoutException('API request deadline exceeded');
    await Future.delayed(delay < remaining ? delay : remaining);
  }

  /// 处理响应：更新 sessionId、校验状态码、解码 JSON。
  Future<dynamic> _processResponse(http.Response response) {
    final responseSessionId = response.headers['x-kg-session-id'];
    if (responseSessionId != null && responseSessionId.isNotEmpty) {
      sessionId = responseSessionId;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.body, statusCode: response.statusCode);
    }
    if (response.body.trim().isEmpty) {
      return Future.value(null);
    }
    try {
      final decoded = jsonDecode(response.body);
      return Future.value(unwrapData(decoded));
    } on FormatException {
      return Future.value(response.body);
    }
  }

  void close() => _client.close();
}

dynamic unwrapData(dynamic json) {
  if (json is Map<String, dynamic>) {
    final data = json['data'];
    if (data != null) {
      return data;
    }
  }
  return json;
}
