import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'client.dart';
import 'engine.dart';
import 'models.dart';
import 'store.dart';
import 'survey_sheet.dart';

/// Shows MobSur surveys when your app reports events.
///
/// ```dart
/// MobSurSDK().setup('YOUR-APP-ID', currentUser.id);
/// // later, when something happens:
/// MobSurSDK().logEvent('onboarding_completed', context);
/// ```
class MobSurSDK {
  factory MobSurSDK() => _instance;

  MobSurSDK._();

  static final MobSurSDK _instance = MobSurSDK._();

  /// This SDK's version, sent to the server as `sdk=flutter-<version>`.
  static const String version = '2.0.0';

  static final Uri defaultBaseUrl = Uri.parse('https://api.mobsur.com/');

  static const Duration _refreshAfter = Duration(hours: 6);

  /// Replaces the HTTP client in tests.
  @visibleForTesting
  static http.Client? httpClientOverride;

  String? _appId;
  String _platform = 'ios';
  String _appVersion = '0.0';
  bool _debug = false;
  GlobalKey<NavigatorState>? _navigatorKey;
  SurveyEngine? _engine;
  SurveyClient? _client;
  String? _pendingUserId;
  Future<void>? _fetching;
  DateTime? _lastFetchAttempt;

  /// Starts the SDK and fetches the surveys for this person in the background.
  ///
  /// [appID] is the App ID from the MobSur dashboard. [clientID] is a stable
  /// identifier for the person using your app. If you don't have one yet, pass
  /// `null`: the SDK then creates a random ID once and keeps it on the device.
  /// Call [updateClientId] when the person signs in.
  ///
  /// Pass a [navigatorKey] (the one given to your `MaterialApp`) to call
  /// [logEvent] without a `BuildContext`. [debug] prints what the SDK does.
  /// [baseUrl] is only for testing against another MobSur server.
  ///
  /// The returned future completes once saved state is loaded, without waiting
  /// for the network.
  Future<void> setup(
    String appID,
    String? clientID, {
    bool debug = false,
    GlobalKey<NavigatorState>? navigatorKey,
    Uri? baseUrl,
  }) async {
    _debug = debug;
    _navigatorKey = navigatorKey;
    final platform = _currentPlatform();
    if (platform == null) return _log('Only iOS and Android are supported.');
    if (appID.trim().isEmpty) return _log('setup() needs the App ID from your dashboard.');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('MobSurSurveysCache'); // 1.x cache
      _appVersion = await _readAppVersion();
      _platform = platform;
      _appId = appID.trim();
      _client = SurveyClient(baseUrl ?? defaultBaseUrl, httpClient: httpClientOverride);
      final engine = _engine = SurveyEngine(SharedPreferencesStore(prefs));
      final requested = _clean(clientID) ?? _pendingUserId;
      _pendingUserId = null;
      engine.setUserId(requested ?? engine.userId ?? generateUserId());
      _log('Ready for user ${engine.userId}.');
      unawaited(_fetch());
    } catch (error) {
      _log('Setup failed: $error');
    }
  }

  /// Changes the person surveys are shown to, for example after sign-in.
  void updateClientId(String clientID) {
    final id = _clean(clientID);
    if (id == null) return _log('updateClientId() needs a non-empty ID.');
    final engine = _engine;
    if (engine == null) {
      _pendingUserId = id;
      return;
    }
    if (engine.setUserId(id)) {
      _log('User changed to $id.');
      unawaited(_fetch());
    }
  }

  /// Reports that [name] happened. If a live survey listens for this event and
  /// its occurrence rule matches, the survey opens after the rule's delay.
  ///
  /// [context] is used to show the survey. It may be omitted when a
  /// `navigatorKey` was passed to [setup].
  void logEvent(String name, [BuildContext? context]) {
    final engine = _engine;
    if (engine == null) return _log('logEvent("$name") ignored: setup() has not finished.');
    try {
      final last = _lastFetchAttempt;
      if (last == null || DateTime.now().difference(last) > _refreshAfter) unawaited(_fetch());
      final decision = engine.recordEvent(name);
      if (decision == null) return _log('No survey to show for "$name".');
      _log('Showing survey ${decision.survey.id} for "$name" in ${decision.delay.inMilliseconds} ms.');
      Future.delayed(decision.delay, () {
        _present(engine, decision.survey, context != null && context.mounted ? context : null);
      });
    } catch (error) {
      _log('logEvent("$name") failed: $error');
    }
  }

  /// The surveys currently available to this person, in priority order.
  List<Survey>? availableSurveys() => _engine?.surveys;

  void _present(SurveyEngine engine, Survey survey, BuildContext? context) {
    final target = context ?? _navigatorKey?.currentContext;
    if (target == null || !target.mounted) {
      engine.presentationAbandoned();
      return _log('Survey ${survey.id} not shown: no mounted BuildContext or navigatorKey.');
    }
    try {
      engine.presentationStarted();
      unawaited(showSurveySheet(target, survey, onCompleted: () {
        engine.markCompleted(survey.id);
        _log('Survey ${survey.id} completed.');
      }));
    } catch (error) {
      _log('Survey ${survey.id} could not be shown: $error');
    }
  }

  Future<void> _fetch() => _fetching ??= _fetchLatest().whenComplete(() => _fetching = null);

  Future<void> _fetchLatest() async {
    final engine = _engine;
    final client = _client;
    final appId = _appId;
    if (engine == null || client == null || appId == null) return;
    while (true) {
      final userId = engine.userId!;
      _lastFetchAttempt = DateTime.now();
      final result = await client.fetch(SurveyRequest(
        appId: appId,
        userId: userId,
        appVersion: _appVersion,
        platform: _platform,
        acceptLanguage: _acceptLanguage(),
        sdk: 'flutter-$version',
      ));
      // The person changed while this request was in flight.
      if (engine.userId != userId) continue;
      if (result == null) return _log('Surveys not updated: the server could not be reached.');
      final (status, body) = result;
      final outcome = engine.applyResponse(status, body);
      return _log(switch (outcome) {
        FetchOutcome.replaced => 'Received ${engine.surveys.length} surveys.',
        FetchOutcome.cleared => 'No surveys: the server answered $status. ${_message(body)}',
        FetchOutcome.kept => 'Surveys not updated: the server answered $status.',
      });
    }
  }

  static String? _currentPlatform() {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      _ => null,
    };
  }

  static Future<String> _readAppVersion() async {
    try {
      final version = (await PackageInfo.fromPlatform()).version.trim();
      return version.isEmpty ? '0.0' : version;
    } catch (_) {
      return '0.0';
    }
  }

  static String _acceptLanguage() {
    final tags = WidgetsBinding.instance.platformDispatcher.locales
        .map((locale) => locale.toLanguageTag())
        .where((tag) => tag.isNotEmpty && tag != 'und')
        .toSet();
    return tags.isEmpty ? 'en' : tags.join(',');
  }

  static String? _clean(String? id) {
    final trimmed = id?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String _message(String body) {
    final match = RegExp(r'"message"\s*:\s*"([^"]*)"').firstMatch(body);
    return match?.group(1) ?? '';
  }

  void _log(String message) {
    if (_debug) debugPrint('MobSur :: $message');
  }

  /// Forgets in-memory state so tests can call [setup] again.
  @visibleForTesting
  void resetForTesting() {
    _appId = null;
    _engine = null;
    _client = null;
    _pendingUserId = null;
    _fetching = null;
    _lastFetchAttempt = null;
    _navigatorKey = null;
    _debug = false;
  }

  /// Completes when the current background fetch, if any, has finished.
  @visibleForTesting
  Future<void> get pendingFetch => _fetching ?? Future.value();
}
