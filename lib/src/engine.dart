import 'dart:convert';
import 'dart:math';

import 'models.dart';
import 'store.dart';

/// A survey to show and how long to wait before showing it.
class EventDecision {
  const EventDecision(this.survey, this.delay);

  final Survey survey;
  final Duration delay;
}

enum FetchOutcome { replaced, cleared, kept }

enum _Session { idle, pending, shown }

/// Decides which survey an event shows. It has no UI or network code, so the
/// rules in `docs/sdk-contract.md` of the MobSur backend can be tested directly.
class SurveyEngine {
  SurveyEngine(this._store, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    _surveys = _readList(surveysKey).map(Survey.tryParse).whereType<Survey>().toList();
    _completed = _readList(completedKey).whereType<int>().toSet();
    final counters = _readJson(countersKey);
    if (counters is Map) {
      counters.forEach((survey, events) {
        if (events is! Map) return;
        _counters[survey.toString()] = {
          for (final entry in events.entries)
            if (entry.value is int) entry.key.toString(): entry.value as int,
        };
      });
    }
  }

  static const String surveysKey = 'MobSur_surveys';
  static const String countersKey = 'MobSur_counters';
  static const String completedKey = 'MobSur_completed';
  static const String userIdKey = 'MobSur_user_id';

  final KeyValueStore _store;
  final DateTime Function() _clock;

  List<Survey> _surveys = [];
  Set<int> _completed = {};
  final Map<String, Map<String, int>> _counters = {};
  _Session _session = _Session.idle;

  List<Survey> get surveys => List.unmodifiable(_surveys);

  String? get userId => _store.getString(userIdKey);

  /// Switches to [id]. Everything cached belonged to the previous person, so it
  /// is discarded. Returns whether the ID changed.
  bool setUserId(String id) {
    if (userId == id) return false;
    _store.setString(userIdKey, id);
    _surveys = [];
    _completed = {};
    _counters.clear();
    _save();
    return true;
  }

  /// Applies the result of `GET /api/surveys`.
  FetchOutcome applyResponse(int status, String body) {
    if (status == 200) {
      final surveys = parseSurveyList(body);
      if (surveys == null) return FetchOutcome.kept;
      _replace(surveys);
      return FetchOutcome.replaced;
    }
    if (status >= 400 && status < 500 && status != 408 && status != 429) {
      _replace(const []);
      return FetchOutcome.cleared;
    }
    return FetchOutcome.kept;
  }

  void _replace(List<Survey> surveys) {
    final ids = surveys.map((survey) => survey.id).toSet();
    _completed.retainWhere(ids.contains);
    _counters.removeWhere((survey, _) => !ids.contains(int.tryParse(survey)));
    _surveys = surveys.where((survey) => !_completed.contains(survey.id)).toList();
    _save();
  }

  /// Counts [name] for the surveys that listen for it and returns the survey to
  /// show, if any. At most one survey is shown per app session.
  EventDecision? recordEvent(String name) {
    if (_session != _Session.idle) return null;
    final now = _clock();
    for (final survey in _surveys) {
      if (_completed.contains(survey.id) || !survey.isActiveAt(now)) continue;
      final rules = survey.rules.where((rule) => rule.isCountedEvent && rule.name == name);
      if (rules.isEmpty) continue;
      final events = _counters.putIfAbsent('${survey.id}', () => {});
      final count = events[name] = (events[name] ?? 0) + 1;
      _save();
      for (final rule in rules) {
        if (rule.allows(count)) {
          _session = _Session.pending;
          return EventDecision(survey, Duration(milliseconds: rule.delay));
        }
      }
    }
    return null;
  }

  /// The pending survey is now on screen; no other survey shows this session.
  void presentationStarted() => _session = _Session.shown;

  /// The pending survey could not be shown, so a later event may try again.
  void presentationAbandoned() {
    if (_session == _Session.pending) _session = _Session.idle;
  }

  void markCompleted(int surveyId) {
    _completed.add(surveyId);
    _surveys.removeWhere((survey) => survey.id == surveyId);
    _save();
  }

  /// The thank-you page's Finish button navigates to `?close=1#close`.
  static bool isCloseUrl(String url) => Uri.tryParse(url)?.fragment == 'close';

  static bool isSuccessUrl(String url) => Uri.tryParse(url)?.path.contains('/survey/success/') ?? false;

  void _save() {
    _store.setString(surveysKey, jsonEncode(_surveys.map((survey) => survey.toJson()).toList()));
    _store.setString(completedKey, jsonEncode(_completed.toList()));
    _store.setString(countersKey, jsonEncode(_counters));
  }

  Object? _readJson(String key) {
    final value = _store.getString(key);
    if (value == null) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }

  List<Object?> _readList(String key) {
    final value = _readJson(key);
    return value is List ? value : const [];
  }
}

/// A random (version 4) UUID, used when the host app has no user ID of its own.
String generateUserId([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
