import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'store.dart';

/// Sends one experiment event to [baseUrl]. Returns the HTTP status, or `null`
/// when the server could not be reached.
typedef ExperimentEventSender = Future<int?> Function(String experimentId, Map<String, Object?> body, String baseUrl);

/// Runs [callback] after [delay]; returns something that cancels it.
typedef RetryScheduler = void Function() Function(Duration delay, void Function() callback);

/// A persisted queue of `POST /api/experiments/{id}/events` calls.
///
/// Each event keeps the `event_id` it was created with, so retries are
/// idempotent on the server, and the server it was created for, so a later
/// `setup` with another base URL never receives it. Events are sent in order and
/// retried with exponential backoff until the server answers 2xx, or a 4xx other
/// than 408/429 (which is final: the event is dropped). An event the server has
/// kept refusing for [giveUpAfter] is dropped too, so it can't hold back the
/// rest forever. Only time between two refusals counts: an attempt that finds
/// the device offline ends the streak.
class ExperimentEventQueue {
  ExperimentEventQueue(
    this._store,
    this._send, {
    DateTime Function()? clock,
    RetryScheduler? schedule,
    void Function(String message)? log,
  })  : _clock = clock ?? DateTime.now,
        _schedule = schedule ?? _timer,
        _log = log ?? ((_) {}) {
    final saved = _store.getString(storeKey);
    if (saved == null) return;
    try {
      final list = jsonDecode(saved);
      if (list is! List) return;
      for (final item in list) {
        // Events saved by 2.1.0 have no base URL; they are dropped rather than
        // sent to whatever server the app is set up with now.
        final event = _QueuedEvent.tryParse(item);
        // A new app launch is a good moment to retry, whatever the old backoff.
        if (event != null) _events.add(event..retryAt = null);
      }
    } on FormatException {
      // A corrupt queue is dropped rather than blocking new events.
    }
  }

  static const String storeKey = 'MobSur_experiment_events';

  /// Oldest events are dropped beyond this, so a server that is down for a
  /// long time can't grow storage without bound.
  static const int maxEvents = 500;

  static const Duration firstRetry = Duration(seconds: 5);
  static const Duration maxRetry = Duration(hours: 1);

  /// How long the server may keep refusing an event before it is dropped,
  /// counted only between refusals, so time offline never drops an exposure.
  static const Duration giveUpAfter = Duration(days: 7);

  final KeyValueStore _store;
  final ExperimentEventSender _send;
  final DateTime Function() _clock;
  final RetryScheduler _schedule;
  final void Function(String message) _log;
  final List<_QueuedEvent> _events = [];
  Future<void>? _flushing;
  void Function()? _cancelRetry;

  /// Event bodies still waiting to be accepted, oldest first.
  List<Map<String, Object?>> get pending => [for (final event in _events) Map.unmodifiable(event.body)];

  /// Adds an event for the server at [baseUrl] and starts sending it.
  void add(String experimentId, Map<String, Object?> body, String baseUrl) {
    _events.add(_QueuedEvent(experimentId, baseUrl, body, 0, null));
    while (_events.length > maxEvents) {
      _events.removeAt(0);
    }
    _save();
    unawaited(flush());
  }

  /// Sends every event that is due. Never runs twice at once.
  Future<void> flush() => _flushing ??= _flush().whenComplete(() => _flushing = null);

  Future<void> _flush() async {
    _cancelRetry?.call();
    _cancelRetry = null;
    while (true) {
      // Events go out in order; one waiting for a retry holds back the rest.
      final now = _clock();
      if (_events.isEmpty) break;
      final event = _events.first;
      if (event.retryAt != null && event.retryAt!.isAfter(now)) break;
      int? status;
      try {
        status = await _send(event.experimentId, event.body, event.baseUrl);
      } catch (_) {
        status = null;
      }
      if (status != null && (status ~/ 100 == 2 || _isFinal(status))) {
        if (status ~/ 100 != 2) {
          _log('Experiment ${event.experimentId} rejected the ${event.body['kind']} event with $status; dropped.');
        }
        _events.remove(event);
        _save();
        continue;
      }
      if (status != null) {
        final lastRefusal = event.lastRefusalAt;
        if (lastRefusal != null && now.isAfter(lastRefusal)) event.refusedFor += now.difference(lastRefusal);
        event.lastRefusalAt = now;
        if (event.refusedFor >= giveUpAfter) {
          _log('Experiment ${event.experimentId} kept refusing the ${event.body['kind']} event with $status; dropped.');
          _events.remove(event);
          _save();
          continue;
        }
      } else {
        // Offline: the time until the server is reached again does not count as refusing.
        event.lastRefusalAt = null;
      }
      // Retry later. The server is probably unavailable, so stop for now.
      event.attempts++;
      event.retryAt = now.add(backoff(event.attempts));
      _save();
      _log('Experiment event not sent (${status ?? 'offline'}); retrying in ${backoff(event.attempts).inSeconds} s.');
      break;
    }
    _scheduleNext();
  }

  void _scheduleNext() {
    if (_events.isEmpty) return;
    final wait = (_events.first.retryAt ?? _clock()).difference(_clock());
    _cancelRetry = _schedule(wait.isNegative ? Duration.zero : wait, () {
      _cancelRetry = null;
      unawaited(flush());
    });
  }

  /// Stops the retry timer, for tests and teardown.
  void dispose() {
    _cancelRetry?.call();
    _cancelRetry = null;
  }

  static bool _isFinal(int status) => status >= 400 && status < 500 && status != 408 && status != 429;

  /// 5 s, 10 s, 20 s, … up to an hour.
  static Duration backoff(int attempts) {
    // Ten doublings already pass the cap, and attempts are kept across launches:
    // an uncapped power overflows at about 62 attempts and the delay becomes zero.
    final seconds = firstRetry.inSeconds * pow(2, min(max(0, attempts - 1), 10));
    return seconds >= maxRetry.inSeconds ? maxRetry : Duration(seconds: seconds.toInt());
  }

  void _save() => _store.setString(storeKey, jsonEncode(_events.map((event) => event.toJson()).toList()));

  static void Function() _timer(Duration delay, void Function() callback) => Timer(delay, callback).cancel;
}

class _QueuedEvent {
  _QueuedEvent(this.experimentId, this.baseUrl, this.body, this.attempts, this.retryAt,
      {this.refusedFor = Duration.zero, this.lastRefusalAt});

  final String experimentId;

  /// The server the event was created for (`setup`'s base URL then).
  final String baseUrl;
  final Map<String, Object?> body;
  int attempts;
  DateTime? retryAt;

  /// How long the server has been refusing this event, counted only between refusals.
  Duration refusedFor;

  /// The latest refusal, if the attempts since then have not found the device offline.
  DateTime? lastRefusalAt;

  static _QueuedEvent? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['experiment_id'];
    final baseUrl = json['base_url'];
    final body = json['body'];
    if (id is! String || baseUrl is! String || body is! Map || body['event_id'] is! String) return null;
    final retryAt = json['retry_at'];
    final refusedFor = json['refused_for_ms'];
    final lastRefusalAt = json['last_refusal_at'];
    return _QueuedEvent(
      id,
      baseUrl,
      Map<String, Object?>.from(body),
      json['attempts'] is int ? json['attempts'] as int : 0,
      retryAt is String ? DateTime.tryParse(retryAt) : null,
      refusedFor: refusedFor is int ? Duration(milliseconds: refusedFor) : Duration.zero,
      lastRefusalAt: lastRefusalAt is String ? DateTime.tryParse(lastRefusalAt) : null,
    );
  }

  Map<String, Object?> toJson() => {
        'experiment_id': experimentId,
        'base_url': baseUrl,
        'body': body,
        'attempts': attempts,
        'retry_at': retryAt?.toUtc().toIso8601String(),
        'refused_for_ms': refusedFor.inMilliseconds,
        'last_refusal_at': lastRefusalAt?.toUtc().toIso8601String(),
      };
}
