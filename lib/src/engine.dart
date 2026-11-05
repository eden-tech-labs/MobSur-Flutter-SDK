import 'dart:convert';
import 'dart:math';

import 'models.dart';
import 'store.dart';

/// What an event shows, and how long to wait before showing it. Exactly one
/// of [survey] and [experiment] is set.
class EventDecision {
  const EventDecision(Survey this.survey, this.delay) : experiment = null;

  const EventDecision.experiment(Experiment this.experiment, this.delay) : survey = null;

  final Survey? survey;
  final Experiment? experiment;
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
    _readCounters(countersKey, _counters);
    _experiments = _readList(experimentsKey).map(Experiment.tryParse).whereType<Experiment>().toList();
    _experimentsDone = _readList(experimentsDoneKey).whereType<String>().toSet();
    _readCounters(experimentCountersKey, _experimentCounters);
    final attributes = _readJson(attributesKey);
    if (attributes is Map) {
      attributes.forEach((key, value) {
        if (key is String && isValidAttribute(value)) _attributes[key] = value as Object;
      });
    }
  }

  static const String surveysKey = 'MobSur_surveys';
  static const String countersKey = 'MobSur_counters';
  static const String completedKey = 'MobSur_completed';
  static const String userIdKey = 'MobSur_user_id';
  static const String experimentsKey = 'MobSur_experiments';
  static const String experimentCountersKey = 'MobSur_experiment_counters';
  static const String experimentsDoneKey = 'MobSur_experiments_done';
  static const String attributesKey = 'MobSur_attributes';

  final KeyValueStore _store;
  final DateTime Function() _clock;

  List<Survey> _surveys = [];
  Set<int> _completed = {};
  final Map<String, Map<String, int>> _counters = {};
  List<Experiment> _experiments = [];
  Set<String> _experimentsDone = {};
  final Map<String, Map<String, int>> _experimentCounters = {};
  final Map<String, Object> _attributes = {};
  _Session _session = _Session.idle;
  // The count behind the pending presentation, given back if it is abandoned.
  ({Map<String, int> events, String name})? _pendingCount;

  List<Survey> get surveys => List.unmodifiable(_surveys);

  List<Experiment> get experiments => List.unmodifiable(_experiments);

  /// The attributes sent with each fetch, sorted by key.
  Map<String, Object> get attributes =>
      Map.unmodifiable(Map.fromEntries(_attributes.entries.toList()..sort((a, b) => a.key.compareTo(b.key))));

  /// v1 attributes are strings, finite numbers and booleans.
  static bool isValidAttribute(Object? value) =>
      value is String || value is bool || (value is num && value.isFinite);

  /// Merges [changes] into the saved attributes; `null` removes a key. Values of
  /// other types are ignored and their keys returned in `rejected`.
  ///
  /// The cached experiments were chosen for the old attributes (someone who just
  /// subscribed may no longer qualify), so a change stops using them until the
  /// next successful fetch. Their counters are kept.
  ({bool changed, List<String> rejected}) mergeAttributes(Map<String, Object?> changes) {
    var changed = false;
    final rejected = <String>[];
    changes.forEach((key, value) {
      if (value == null) {
        if (_attributes.remove(key) != null) changed = true;
      } else if (!isValidAttribute(value)) {
        rejected.add(key);
      } else if (_attributes[key] != value || _attributes[key].runtimeType != value.runtimeType) {
        _attributes[key] = value;
        changed = true;
      }
    });
    if (changed) {
      _store.setString(attributesKey, jsonEncode(_attributes));
      _experiments = [];
      _save();
    }
    return (changed: changed, rejected: rejected);
  }

  String? get userId => _store.getString(userIdKey);

  /// Switches to [id]. Everything cached belonged to the previous person, so it
  /// is discarded. Returns whether the ID changed.
  bool setUserId(String id) {
    if (userId == id) return false;
    _store.setString(userIdKey, id);
    _surveys = [];
    _completed = {};
    _counters.clear();
    _experiments = [];
    _experimentsDone = {};
    _experimentCounters.clear();
    _save();
    return true;
  }

  /// Applies the result of `GET /api/surveys`.
  FetchOutcome applyResponse(int status, String body) {
    if (status == 200) {
      final surveys = parseSurveyList(body);
      final experiments = parseExperimentList(body);
      if (surveys == null || experiments == null) return FetchOutcome.kept;
      _replace(surveys);
      _replaceExperiments(experiments);
      return FetchOutcome.replaced;
    }
    if (status >= 400 && status < 500 && status != 408 && status != 429) {
      _replace(const []);
      _replaceExperiments(const []);
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

  // Experiments shown on this device stay done for this person even when the
  // server stops returning them (it does once it has the exposure), so a
  // stale cache or an exposure still in the send queue can't show one twice.
  void _replaceExperiments(List<Experiment> experiments) {
    final ids = experiments.map((experiment) => experiment.id).toSet();
    _experimentCounters.removeWhere((id, _) => !ids.contains(id));
    _experiments = experiments.where((experiment) => !_experimentsDone.contains(experiment.id)).toList();
    _save();
  }

  /// Counts [name] for the experiments and surveys that listen for it and
  /// returns what to show, if anything. Experiments are evaluated first. At
  /// most one experiment or survey is shown per app session.
  EventDecision? recordEvent(String name) {
    if (_session != _Session.idle) return null;
    final now = _clock();
    for (final experiment in _experiments) {
      if (_experimentsDone.contains(experiment.id) || !experiment.isActiveAt(now)) continue;
      final rules = experiment.rules.where((rule) => rule.isCountedEvent && rule.name == name);
      if (rules.isEmpty) continue;
      final events = _experimentCounters.putIfAbsent(experiment.id, () => {});
      final count = events[name] = (events[name] ?? 0) + 1;
      _save();
      for (final rule in rules) {
        if (rule.allows(count)) {
          _session = _Session.pending;
          _pendingCount = (events: events, name: name);
          return EventDecision.experiment(experiment, Duration(milliseconds: rule.delay));
        }
      }
    }
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
          _pendingCount = (events: events, name: name);
          return EventDecision(survey, Duration(milliseconds: rule.delay));
        }
      }
    }
    return null;
  }

  /// The pending survey is now on screen; no other survey shows this session.
  void presentationStarted() {
    _session = _Session.shown;
    _pendingCount = null;
  }

  /// The pending survey could not be shown, so a later event may try again.
  /// The event that triggered it doesn't count, or a rule that only matches
  /// one occurrence would never get another chance.
  void presentationAbandoned() {
    if (_session != _Session.pending) return;
    _session = _Session.idle;
    final pending = _pendingCount;
    _pendingCount = null;
    if (pending == null) return;
    pending.events[pending.name] = max(0, (pending.events[pending.name] ?? 0) - 1);
    _save();
  }

  /// Whether this person is still in [experiment], in the same arm. A change of
  /// person or attributes takes it out of the cache, including during a rule's
  /// delay.
  bool isLive(Experiment experiment) =>
      _experiments.any((other) => other.id == experiment.id && other.arm == experiment.arm);

  /// The experiment was exposed (shown, or for `control` would have been).
  /// It never triggers again for this person.
  void markExperimentDone(String experimentId) {
    _experimentsDone.add(experimentId);
    _experiments.removeWhere((experiment) => experiment.id == experimentId);
    _save();
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
    _store.setString(experimentsKey, jsonEncode(_experiments.map((experiment) => experiment.toJson()).toList()));
    _store.setString(experimentsDoneKey, jsonEncode(_experimentsDone.toList()));
    _store.setString(experimentCountersKey, jsonEncode(_experimentCounters));
  }

  void _readCounters(String key, Map<String, Map<String, int>> into) {
    final counters = _readJson(key);
    if (counters is! Map) return;
    counters.forEach((id, events) {
      if (events is! Map) return;
      into[id.toString()] = {
        for (final entry in events.entries)
          if (entry.value is int) entry.key.toString(): entry.value as int,
      };
    });
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
