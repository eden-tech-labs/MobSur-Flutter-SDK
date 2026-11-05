import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class SurveyRequest {
  const SurveyRequest({
    required this.appId,
    required this.userId,
    required this.appVersion,
    required this.platform,
    required this.acceptLanguage,
    required this.sdk,
    this.attributes = const {},
  });

  final String appId;
  final String userId;
  final String appVersion;
  final String platform;
  final String acceptLanguage;
  final String sdk;

  /// Sent as the `attributes` query parameter (JSON) when not empty.
  final Map<String, Object> attributes;
}

class SurveyClient {
  SurveyClient(Uri baseUrl, {http.Client? httpClient})
      : _baseUrl = baseUrl.path.endsWith('/') ? baseUrl : baseUrl.replace(path: '${baseUrl.path}/'),
        _http = httpClient ?? http.Client();

  static const Duration timeout = Duration(seconds: 20);

  final Uri _baseUrl;
  final http.Client _http;

  Uri surveysUri(SurveyRequest request) => _baseUrl.resolve('api/surveys').replace(queryParameters: {
        'app_id': request.appId,
        'user_reference_id': request.userId,
        'app_version': request.appVersion,
        'platform': request.platform,
        'sdk': request.sdk,
        if (request.attributes.isNotEmpty) 'attributes': jsonEncode(request.attributes),
      });

  Uri experimentEventsUri(String experimentId) =>
      _baseUrl.resolve('api/experiments/${Uri.encodeComponent(experimentId)}/events');

  /// Returns the HTTP status and body, or `null` when the server could not be
  /// reached.
  Future<(int, String)?> fetch(SurveyRequest request) async {
    try {
      final response = await _http.get(surveysUri(request), headers: {
        'Accept': 'application/json',
        'Accept-Language': request.acceptLanguage,
      }).timeout(timeout);
      return (response.statusCode, response.body);
    } catch (_) {
      return null;
    }
  }

  /// Posts one experiment event. Returns the HTTP status, or `null` when the
  /// server could not be reached.
  Future<int?> postEvent(String experimentId, Map<String, Object?> body, {String? acceptLanguage}) async {
    try {
      final response = await _http
          .post(
            experimentEventsUri(experimentId),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              if (acceptLanguage != null) 'Accept-Language': acceptLanguage,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      return response.statusCode;
    } catch (_) {
      return null;
    }
  }
}
