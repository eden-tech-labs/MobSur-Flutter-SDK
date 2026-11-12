import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'client.dart';
import 'engine.dart';
import 'event_queue.dart';
import 'message_sheet.dart';
import 'models.dart';
import 'store.dart';
import 'survey_sheet.dart';

/// Shows MobSur surveys and in-app message experiments when your app reports
/// events.
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
  static const String version = '2.1.1';

  static final Uri defaultBaseUrl = Uri.parse('https://api.mobsur.com/');

  static const Duration _refreshAfter = Duration(hours: 6);

  /// Replaces the HTTP client in tests.
  @visibleForTesting
  static http.Client? httpClientOverride;

  /// Replaces `url_launcher` in tests.
  @visibleForTesting
  static Future<bool> Function(Uri url)? launchUrlOverride;

  String? _appId;
  Uri _baseUrl = defaultBaseUrl;
  String _platform = 'ios';
  String _appVersion = '0.0';
  bool _debug = false;
  GlobalKey<NavigatorState>? _navigatorKey;
  SurveyEngine? _engine;
  SurveyClient? _client;
  String? _pendingUserId;
  Future<void>? _fetching;
  DateTime? _lastFetchAttempt;
  void Function(String action)? _onAction;
  bool Function()? _canShowOverlay;
  ExperimentEventQueue? _queue;
  final Map<String, Object?> _pendingAttributes = {};

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
  /// [onAction] receives an experiment message's call-to-action (for example
  /// a deep link such as `myapp://paywall`) after the person taps it and the
  /// sheet has closed. Without it, the action is opened as a URL.
  ///
  /// [canShowOverlay] lets your app veto a survey or experiment message at
  /// the moment it would appear (after the rule's delay), for example while
  /// your own paywall is on screen. When it returns `false`, nothing appears,
  /// nothing is reported and the session's slot stays free, so a later event
  /// can try again.
  ///
  /// The returned future completes once saved state is loaded, without waiting
  /// for the network.
  Future<void> setup(
    String appID,
    String? clientID, {
    bool debug = false,
    GlobalKey<NavigatorState>? navigatorKey,
    Uri? baseUrl,
    void Function(String action)? onAction,
    bool Function()? canShowOverlay,
  }) async {
    _debug = debug;
    _navigatorKey = navigatorKey;
    _onAction = onAction;
    _canShowOverlay = canShowOverlay;
    final platform = _currentPlatform();
    if (platform == null) return _log('Only iOS and Android are supported.');
    if (appID.trim().isEmpty) return _log('setup() needs the App ID from your dashboard.');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('MobSurSurveysCache'); // 1.x cache
      _appVersion = await _readAppVersion();
      _platform = platform;
      _appId = appID.trim();
      _baseUrl = SurveyClient.normalize(baseUrl ?? defaultBaseUrl);
      final client = _client = SurveyClient(_baseUrl, httpClient: httpClientOverride);
      final store = SharedPreferencesStore(prefs);
      final engine = _engine = SurveyEngine(store, appId: _appId!);
      final requested = _clean(clientID) ?? _pendingUserId;
      _pendingUserId = null;
      engine.setUserId(requested ?? engine.userId ?? generateUserId());
      _applyAttributes(engine, Map.of(_pendingAttributes));
      _pendingAttributes.clear();
      _queue?.dispose();
      final queue = _queue = ExperimentEventQueue(
        store,
        // Each event goes to the server it was created for, not this setup's.
        (id, body, baseUrl) =>
            client.postEvent(id, body, acceptLanguage: _acceptLanguage(), baseUrl: Uri.parse(baseUrl)),
        log: _log,
      );
      _log('Ready for user ${engine.userId}.');
      unawaited(_fetch());
      unawaited(queue.flush());
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

  /// Sets attributes describing the person, such as `{'is_subscribed': false}`.
  ///
  /// The server uses them to decide which experiments this person is in.
  /// Values are merged into the attributes set before and kept across
  /// launches; a `null` value removes that key. Values must be strings,
  /// numbers or booleans. When anything changes, experiments and surveys are
  /// fetched again (event counts are kept), and no experiment runs until that
  /// fetch succeeds, because the ones saved were chosen for the old attributes.
  void setAttributes(Map<String, Object?> attributes) {
    try {
      final engine = _engine;
      if (engine == null) {
        _pendingAttributes.addAll(attributes);
        return;
      }
      if (_applyAttributes(engine, attributes)) {
        _log('Attributes changed to ${jsonEncode(engine.attributes)}.');
        unawaited(_fetch());
      }
    } catch (error) {
      _log('setAttributes() failed: $error');
    }
  }

  bool _applyAttributes(SurveyEngine engine, Map<String, Object?> attributes) {
    final (:changed, :rejected) = engine.mergeAttributes(attributes);
    if (rejected.isNotEmpty) {
      _log('Ignored attributes ${rejected.join(', ')}: values must be strings, numbers or booleans.');
    }
    return changed;
  }

  /// Reports that [name] happened. If a live experiment or survey listens for
  /// this event and its occurrence rule matches, it runs after the rule's
  /// delay. Experiments are checked before surveys, and at most one of them
  /// appears per app session.
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
      if (decision == null) return _log('Nothing to show for "$name".');
      final experiment = decision.experiment;
      final survey = decision.survey;
      final pending = (token: decision.token, userId: engine.userId);
      if (experiment != null) {
        _log('Experiment ${experiment.id} (${experiment.arm}) triggered by "$name"; '
            'running in ${decision.delay.inMilliseconds} ms.');
        Future.delayed(decision.delay, () {
          _presentExperiment(engine, experiment, pending, context != null && context.mounted ? context : null);
        });
      } else if (survey != null) {
        _log('Showing survey ${survey.id} for "$name" in ${decision.delay.inMilliseconds} ms.');
        Future.delayed(decision.delay, () {
          _present(engine, survey, pending, context != null && context.mounted ? context : null);
        });
      }
    } catch (error) {
      _log('logEvent("$name") failed: $error');
    }
  }

  /// The surveys currently available to this person, in priority order.
  List<Survey>? availableSurveys() => _engine?.surveys;

  /// The experiments this person is in that haven't run yet on this device.
  List<Experiment>? availableExperiments() => _engine?.experiments;

  /// Whether [pending] still stands: nothing dropped or replaced it, and the
  /// person is the same. Checked again after `canShowOverlay`, because that is
  /// app code: it may switch the account, change attributes or log another
  /// event before returning `true`.
  static bool _stillPending(SurveyEngine engine, _Pending pending) =>
      engine.isPending(pending.token) && engine.userId == pending.userId;

  void _presentExperiment(SurveyEngine engine, Experiment experiment, _Pending pending, BuildContext? context) {
    try {
      // Dropped (the person changed) or replaced since: nothing to do.
      if (!_stillPending(engine, pending)) return;
      if (!engine.isLive(experiment)) {
        engine.presentationAbandoned();
        return _log('Experiment ${experiment.id} not run: the person or their attributes changed during the delay.');
      }
      // Both arms need the UI the treatment would use, so they are exposed
      // under the same conditions.
      final target = context ?? _navigatorKey?.currentContext;
      if (target == null || !target.mounted) {
        engine.presentationAbandoned();
        return _log('Experiment ${experiment.id} not run: no mounted BuildContext or navigatorKey.');
      }
      if (!_hostAllowsOverlay()) {
        engine.presentationAbandoned();
        return _log('Experiment ${experiment.id} not run: canShowOverlay returned false.');
      }
      if (!_stillPending(engine, pending) || !engine.isLive(experiment)) {
        if (engine.isPending(pending.token)) engine.presentationAbandoned();
        return _log('Experiment ${experiment.id} not run: the person or their attributes changed while canShowOverlay ran.');
      }
      engine.presentationStarted();
      engine.markExperimentDone(experiment.id);
      // Every event from this exposure belongs to this person, even if someone
      // else signs in while the sheet is open.
      final userId = pending.userId;
      _report(experiment, 'exposed', userId);
      final message = experiment.message;
      if (experiment.isControl || message == null) {
        return _log('Experiment ${experiment.id}: control arm, nothing shown.');
      }
      _log('Experiment ${experiment.id}: showing the message.');
      unawaited(showExperimentSheet(
        target,
        message,
        onCtaTapped: () => _report(experiment, 'cta_tapped', userId),
      ).then((tapped) {
        if (tapped) {
          _runAction(message.ctaAction);
        } else {
          _report(experiment, 'dismissed', userId);
        }
      }).catchError((Object error) {
        _log('Experiment ${experiment.id} message failed: $error');
      }));
    } catch (error) {
      _log('Experiment ${experiment.id} could not run: $error');
    }
  }

  /// A gate that throws counts as "not now".
  bool _hostAllowsOverlay() {
    final gate = _canShowOverlay;
    if (gate == null) return true;
    try {
      return gate();
    } catch (error) {
      _log('canShowOverlay threw: $error');
      return false;
    }
  }

  void _report(Experiment experiment, String kind, String? userId) {
    final queue = _queue;
    final appId = _appId;
    if (userId == null || queue == null || appId == null) return;
    queue.add(experiment.id, {
      'event_id': generateUserId(),
      'app_id': appId,
      'user_reference_id': userId,
      'kind': kind,
      'arm': experiment.arm,
      'occurred_at': _timestamp(DateTime.now()),
      'platform': _platform,
      'app_version': _appVersion,
      'sdk': 'flutter-$version',
    }, _baseUrl.toString());
  }

  void _runAction(String action) {
    final onAction = _onAction;
    if (onAction != null) {
      try {
        onAction(action);
      } catch (error) {
        _log('onAction("$action") threw: $error');
      }
      return;
    }
    final url = Uri.tryParse(action);
    if (url == null) return _log('Call-to-action "$action" is not a URL and no onAction was given to setup().');
    final launch = launchUrlOverride ?? launchUrl;
    unawaited(Future(() => launch(url)).then((opened) {
      if (!opened) _log('Could not open "$action".');
    }).catchError((Object error) {
      _log('Could not open "$action": $error');
    }));
  }

  /// `2026-10-31T09:12:44Z`
  static String _timestamp(DateTime time) {
    final iso = time.toUtc().toIso8601String();
    return '${iso.substring(0, 19)}Z';
  }

  void _present(SurveyEngine engine, Survey survey, _Pending pending, BuildContext? context) {
    if (!_stillPending(engine, pending)) return;
    final target = context ?? _navigatorKey?.currentContext;
    if (target == null || !target.mounted) {
      engine.presentationAbandoned();
      return _log('Survey ${survey.id} not shown: no mounted BuildContext or navigatorKey.');
    }
    if (!_hostAllowsOverlay()) {
      engine.presentationAbandoned();
      return _log('Survey ${survey.id} not shown: canShowOverlay returned false.');
    }
    if (!_stillPending(engine, pending) || !engine.surveys.any((cached) => cached.id == survey.id)) {
      if (engine.isPending(pending.token)) engine.presentationAbandoned();
      return _log('Survey ${survey.id} not shown: the person or their surveys changed while canShowOverlay ran.');
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
      final attributes = engine.attributes;
      final attributesJson = jsonEncode(attributes);
      _lastFetchAttempt = DateTime.now();
      final result = await client.fetch(SurveyRequest(
        appId: appId,
        userId: userId,
        appVersion: _appVersion,
        platform: _platform,
        acceptLanguage: _acceptLanguage(),
        sdk: 'flutter-$version',
        attributes: attributes,
      ));
      // The person or their attributes changed while this request was in flight.
      if (engine.userId != userId || jsonEncode(engine.attributes) != attributesJson) continue;
      if (result == null) return _log('Surveys not updated: the server could not be reached.');
      final (status, body) = result;
      final outcome = engine.applyResponse(status, body);
      return _log(switch (outcome) {
        FetchOutcome.replaced =>
          'Received ${engine.surveys.length} surveys and ${engine.experiments.length} experiments.',
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
    _baseUrl = defaultBaseUrl;
    _engine = null;
    _client = null;
    _pendingUserId = null;
    _fetching = null;
    _lastFetchAttempt = null;
    _navigatorKey = null;
    _debug = false;
    _onAction = null;
    _canShowOverlay = null;
    _queue?.dispose();
    _queue = null;
    _pendingAttributes.clear();
  }

  /// Completes when queued experiment events have been sent or rescheduled.
  @visibleForTesting
  Future<void> get pendingEvents => _queue?.flush() ?? Future.value();

  /// Completes when the current background fetch, if any, has finished.
  @visibleForTesting
  Future<void> get pendingFetch => _fetching ?? Future.value();
}

/// The decision a delayed survey or message belongs to.
typedef _Pending = ({int token, String? userId});
