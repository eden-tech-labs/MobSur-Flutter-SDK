import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobsur_flutter_sdk/src/event_queue.dart';
import 'package:mobsur_flutter_sdk/src/store.dart';

void main() {
  late MemoryStore store;
  late DateTime now;
  late List<(String, Map<String, Object?>)> sent;
  late List<int?> answers;
  late List<Duration> scheduled;

  ExperimentEventQueue queue() => ExperimentEventQueue(
        store,
        (id, body) async {
          sent.add((id, body));
          return answers.isEmpty ? 202 : answers.removeAt(0);
        },
        clock: () => now,
        schedule: (delay, _) {
          scheduled.add(delay);
          return () {};
        },
      );

  Map<String, Object?> event(String id, [String kind = 'exposed']) => {'event_id': id, 'kind': kind};

  setUp(() {
    store = MemoryStore();
    now = DateTime.utc(2026, 10, 31, 9);
    sent = [];
    answers = [];
    scheduled = [];
  });

  test('sends and forgets an accepted event', () async {
    final q = queue()..add('exp_a', event('e1'));
    await q.flush();

    expect(sent.single.$1, 'exp_a');
    expect(sent.single.$2, event('e1'));
    expect(q.pending, isEmpty);
    expect(jsonDecode(store.values[ExperimentEventQueue.storeKey]!), isEmpty);
  });

  test('retries temporary failures with backoff, with the same event_id', () async {
    answers = [null, 503, 429, 408, 202];
    final q = queue()..add('exp_a', event('e1'));
    await q.flush();
    expect(q.pending, hasLength(1));
    expect(scheduled.last, const Duration(seconds: 5));

    // Not due yet: nothing is sent.
    await q.flush();
    expect(sent, hasLength(1));

    for (final wait in [5, 10, 20, 40]) {
      now = now.add(Duration(seconds: wait));
      await q.flush();
    }
    expect(sent, hasLength(5));
    expect(sent.map((s) => s.$2['event_id']).toSet(), {'e1'});
    expect(q.pending, isEmpty);
  });

  test('drops events the server rejects for good', () async {
    answers = [404, 422, 400];
    final q = queue()
      ..add('gone', event('e1'))
      ..add('mismatch', event('e2'))
      ..add('bad', event('e3'));
    await q.flush();

    expect(sent.map((s) => s.$1), ['gone', 'mismatch', 'bad']);
    expect(q.pending, isEmpty);
  });

  test('survives a relaunch and keeps the order', () async {
    answers = [null];
    final first = queue()..add('exp_a', event('e1'));
    await first.flush();
    first.add('exp_a', event('e2', 'dismissed'));
    await first.flush();
    expect(first.pending.map((e) => e['event_id']), ['e1', 'e2']);

    final relaunched = queue(); // retries at once, without waiting out the backoff
    expect(relaunched.pending.map((e) => e['event_id']), ['e1', 'e2']);
    await relaunched.flush();
    expect(relaunched.pending, isEmpty);
    expect(sent.map((s) => s.$2['event_id']), ['e1', 'e1', 'e2']);
  });

  test('backoff doubles up to an hour', () {
    expect(ExperimentEventQueue.backoff(1), const Duration(seconds: 5));
    expect(ExperimentEventQueue.backoff(2), const Duration(seconds: 10));
    expect(ExperimentEventQueue.backoff(10), const Duration(seconds: 2560));
    expect(ExperimentEventQueue.backoff(11), const Duration(hours: 1));
    expect(ExperimentEventQueue.backoff(60), const Duration(hours: 1));
  });

  test('backoff stays at the cap however many attempts have failed', () {
    // An uncapped power of two wraps around from about 62 attempts.
    for (final attempts in [61, 62, 63, 64, 65, 66, 100, 1000]) {
      expect(ExperimentEventQueue.backoff(attempts), const Duration(hours: 1), reason: '$attempts attempts');
    }
  });

  test('gives up on an event the server keeps refusing, so later events get out', () async {
    answers = [500];
    var q = queue()
      ..add('exp_a', event('e1'))
      ..add('exp_a', event('e2'));
    await q.flush();
    expect(q.pending, hasLength(2));

    // The first refusal's date survives a relaunch.
    now = now.add(const Duration(days: 6, hours: 23));
    q = queue();
    answers = [500];
    await q.flush();
    expect(q.pending, hasLength(2));

    now = now.add(const Duration(hours: 1));
    answers = [500];
    await q.flush();
    expect(q.pending, isEmpty);
    expect(sent.last.$2, event('e2'));
  });

  test('time offline does not count towards giving up', () async {
    answers = [null];
    final q = queue()..add('exp_a', event('e1'));
    await q.flush();

    now = now.add(const Duration(days: 30));
    answers = [null];
    await q.flush();
    expect(q.pending, hasLength(1));

    // The first real refusal only starts the clock.
    now = now.add(const Duration(hours: 2));
    answers = [500];
    await q.flush();
    expect(q.pending, hasLength(1));
  });

  test('ignores a corrupt saved queue', () {
    store.values[ExperimentEventQueue.storeKey] = 'not json';
    expect(queue().pending, isEmpty);
    store.values[ExperimentEventQueue.storeKey] = jsonEncode([
      {'experiment_id': 'a', 'body': {'kind': 'exposed'}}, // no event_id
      {'experiment_id': 'b', 'body': event('ok')},
    ]);
    expect(queue().pending.single['event_id'], 'ok');
  });
}
