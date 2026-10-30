import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobsur_flutter_sdk/src/engine.dart';
import 'package:mobsur_flutter_sdk/src/store.dart';

Map<String, Object?> survey(int id,
        {String event = 'negative_id_feedback', int? min, int? max, int delay = 0, String? end}) =>
    {
      'id': id,
      'url': 'https://web.mobsur.com/survey/$id',
      'start_date': '2026-01-01T00:00:00+00:00',
      'end_date': end,
      'rules': [
        {
          'type': 'counted_event',
          'name': event,
          'occurred': {'min': min, 'max': max},
          'delay': delay
        },
      ],
    };

String body(List<Map<String, Object?>> surveys) => jsonEncode({'data': surveys});

void main() {
  final now = DateTime.utc(2026, 9, 28, 12);
  late MemoryStore store;

  SurveyEngine engine() {
    final engine = SurveyEngine(store, clock: () => now);
    if (engine.userId == null) engine.setUserId('person-1');
    return engine;
  }

  setUp(() => store = MemoryStore());

  test('shows on the first matching event with the rule delay', () {
    final sdk = engine()..applyResponse(200, body([survey(1, delay: 1500)]));

    final decision = sdk.recordEvent('negative_id_feedback')!;
    expect(decision.survey!.id, 1);
    expect(decision.delay, const Duration(milliseconds: 1500));
  });

  test('ignores events nobody listens for and never counts them', () {
    final sdk = engine()..applyResponse(200, body([survey(1)]));

    expect(sdk.recordEvent('App_Launched'), isNull);
    expect(jsonDecode(store.values[SurveyEngine.countersKey]!), isEmpty);
  });

  test('counts occurrences across relaunches and respects the window', () {
    engine().applyResponse(200, body([survey(1, min: 3, max: 4)]));

    // Each "launch" is a new engine over the same saved state.
    expect(engine().recordEvent('negative_id_feedback'), isNull); // 1
    expect(engine().recordEvent('negative_id_feedback'), isNull); // 2
    expect(engine().recordEvent('negative_id_feedback')?.survey?.id, 1); // 3
    expect(engine().recordEvent('negative_id_feedback')?.survey?.id, 1); // 4
    expect(engine().recordEvent('negative_id_feedback'), isNull); // 5
  });

  test('shows at most one survey per session; pending and shown both block', () {
    final sdk = engine()..applyResponse(200, body([survey(1), survey(2)]));

    expect(sdk.recordEvent('negative_id_feedback')?.survey?.id, 1);
    expect(sdk.recordEvent('negative_id_feedback'), isNull); // pending
    sdk.presentationStarted();
    expect(sdk.recordEvent('negative_id_feedback'), isNull); // shown
    expect(jsonDecode(store.values[SurveyEngine.countersKey]!), {
      '1': {'negative_id_feedback': 1},
    });
  });

  test('an abandoned presentation lets a later event try again', () {
    final sdk = engine()..applyResponse(200, body([survey(1)]));

    sdk.recordEvent('negative_id_feedback');
    sdk.presentationAbandoned();
    expect(sdk.recordEvent('negative_id_feedback')?.survey?.id, 1);
  });

  test('uses server order and only counts up to the survey it shows', () {
    final sdk = engine()..applyResponse(200, body([survey(9, min: 2), survey(4), survey(6)]));

    expect(sdk.recordEvent('negative_id_feedback')?.survey?.id, 4);
    expect(jsonDecode(store.values[SurveyEngine.countersKey]!), {
      '9': {'negative_id_feedback': 1},
      '4': {'negative_id_feedback': 1},
    });
  });

  test('skips surveys outside their dates', () {
    final sdk = engine()..applyResponse(200, body([survey(1, end: '2026-09-28T11:59:59+00:00'), survey(2)]));

    expect(sdk.recordEvent('negative_id_feedback')?.survey?.id, 2);
  });

  test('completed surveys never show again, even from a stale cache', () {
    final sdk = engine()..applyResponse(200, body([survey(1), survey(2)]));
    sdk.markCompleted(1);

    final relaunched = engine();
    expect(relaunched.surveys.map((s) => s.id), [2]);
    relaunched.applyResponse(200, body([survey(1), survey(2)])); // fetched before the answer was saved
    expect(relaunched.surveys.map((s) => s.id), [2]);
    relaunched.applyResponse(200, body([survey(2)]));
    expect(jsonDecode(store.values[SurveyEngine.completedKey]!), isEmpty);
  });

  test('a new person starts with a clean slate', () {
    final sdk = engine()..applyResponse(200, body([survey(1, min: 2)]));
    sdk.recordEvent('negative_id_feedback');
    sdk.markCompleted(1);

    expect(sdk.setUserId('person-1'), isFalse);
    expect(sdk.setUserId('person-2'), isTrue);
    expect(sdk.surveys, isEmpty);
    expect(jsonDecode(store.values[SurveyEngine.countersKey]!), isEmpty);
    expect(jsonDecode(store.values[SurveyEngine.completedKey]!), isEmpty);
  });

  test('drops counters for surveys the server no longer returns', () {
    final sdk = engine()..applyResponse(200, body([survey(1, min: 5), survey(2, min: 5)]));
    sdk.recordEvent('negative_id_feedback');

    sdk.applyResponse(200, body([survey(2, min: 5)]));
    expect(jsonDecode(store.values[SurveyEngine.countersKey]!), {
      '2': {'negative_id_feedback': 1},
    });
  });

  test('client errors empty the list; temporary failures and junk keep it', () {
    final sdk = engine()..applyResponse(200, body([survey(1)]));

    for (final status in [408, 429, 500, 503]) {
      expect(sdk.applyResponse(status, '{}'), FetchOutcome.kept);
    }
    expect(sdk.applyResponse(200, '<html>captive portal</html>'), FetchOutcome.kept);
    expect(sdk.surveys, hasLength(1));

    expect(sdk.applyResponse(403, '{"message":"MTU limit"}'), FetchOutcome.cleared);
    expect(sdk.surveys, isEmpty);
  });

  test('recognises the survey page completion URLs', () {
    expect(SurveyEngine.isCloseUrl('https://web.mobsur.com/survey/success/42?close=1#close'), isTrue);
    expect(SurveyEngine.isCloseUrl('https://web.mobsur.com/survey/result/42/3#close'), isTrue);
    expect(SurveyEngine.isCloseUrl('https://web.mobsur.com/survey/42?closed=1'), isFalse);
    expect(SurveyEngine.isSuccessUrl('https://web.mobsur.com/survey/success/42'), isTrue);
    expect(SurveyEngine.isSuccessUrl('https://web.mobsur.com/survey/42/question/9'), isFalse);
  });

  test('generated user IDs are random version 4 UUIDs', () {
    final pattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    expect(generateUserId(Random(1)), matches(pattern));
    expect(generateUserId(), isNot(generateUserId()));
  });

  group('experiments', () {
    Map<String, Object?> experiment(String id,
            {String arm = 'treatment', String event = 'negative_id_feedback', int? min, int delay = 0}) =>
        {
          'id': id,
          'arm': arm,
          'start_date': '2026-01-01T00:00:00+00:00',
          'end_date': null,
          'rules': [
            {
              'type': 'counted_event',
              'name': event,
              'occurred': {'min': min, 'max': null},
              'delay': delay
            },
          ],
          'message': arm == 'control'
              ? null
              : {'title': 'T', 'body': 'B', 'cta_label': 'Go', 'cta_action': 'app://go', 'dismiss_label': null},
        };

    String withExperiments(List<Map<String, Object?>> surveys, List<Map<String, Object?>> experiments) =>
        jsonEncode({'data': surveys, 'experiments': experiments});

    test('are evaluated before surveys and keep their own counters', () {
      final sdk = engine()..applyResponse(200, withExperiments([survey(1)], [experiment('exp_a', min: 2, delay: 800)]));

      // First occurrence: the experiment counts but isn't due, so the survey shows.
      expect(sdk.recordEvent('negative_id_feedback')?.survey?.id, 1);
      sdk.presentationAbandoned();
      final decision = sdk.recordEvent('negative_id_feedback')!;
      expect(decision.experiment!.id, 'exp_a');
      expect(decision.survey, isNull);
      expect(decision.delay, const Duration(milliseconds: 800));
      expect(jsonDecode(store.values[SurveyEngine.experimentCountersKey]!), {
        'exp_a': {'negative_id_feedback': 2},
      });
      // Surveys are not counted for the event that triggered the experiment.
      expect(jsonDecode(store.values[SurveyEngine.countersKey]!), {
        '1': {'negative_id_feedback': 1},
      });
    });

    test('share the one-per-session slot with surveys, in both arms', () {
      for (final arm in ['treatment', 'control']) {
        store = MemoryStore();
        final sdk = engine()..applyResponse(200, withExperiments([survey(1)], [experiment('exp_a', arm: arm)]));

        expect(sdk.recordEvent('negative_id_feedback')?.experiment?.arm, arm);
        expect(sdk.recordEvent('negative_id_feedback'), isNull); // pending
        sdk.presentationStarted();
        sdk.markExperimentDone('exp_a');
        expect(sdk.recordEvent('negative_id_feedback'), isNull); // shown
      }
    });

    test('run once per person, even when a stale fetch returns them again', () {
      final sdk = engine()..applyResponse(200, withExperiments([], [experiment('exp_a'), experiment('exp_b')]));
      sdk.markExperimentDone('exp_a');

      final relaunched = engine();
      expect(relaunched.experiments.map((e) => e.id), ['exp_b']);
      relaunched.applyResponse(200, withExperiments([], [experiment('exp_a'), experiment('exp_b')]));
      expect(relaunched.experiments.map((e) => e.id), ['exp_b']);
      expect(relaunched.recordEvent('negative_id_feedback')?.experiment?.id, 'exp_b');
    });

    test('client errors clear them; counters go with experiments the server drops', () {
      final sdk = engine()
        ..applyResponse(200, withExperiments([], [experiment('exp_a', min: 5), experiment('exp_b', min: 5)]));
      sdk.recordEvent('negative_id_feedback');
      sdk.applyResponse(200, withExperiments([], [experiment('exp_b', min: 5)]));
      expect(jsonDecode(store.values[SurveyEngine.experimentCountersKey]!), {
        'exp_b': {'negative_id_feedback': 1},
      });

      sdk.applyResponse(500, '{}');
      expect(sdk.experiments, hasLength(1));
      sdk.applyResponse(403, '{}');
      expect(sdk.experiments, isEmpty);
    });

    test('a new person starts with no experiments, counters or done ids', () {
      final sdk = engine()..applyResponse(200, withExperiments([], [experiment('exp_a', min: 3)]));
      sdk.recordEvent('negative_id_feedback');
      sdk.markExperimentDone('exp_a');

      sdk.setUserId('person-2');
      expect(sdk.experiments, isEmpty);
      expect(jsonDecode(store.values[SurveyEngine.experimentCountersKey]!), isEmpty);
      expect(jsonDecode(store.values[SurveyEngine.experimentsDoneKey]!), isEmpty);
    });
  });

  group('attributes', () {
    test('merge, persist, and null removes a key', () {
      final sdk = engine();
      expect(sdk.mergeAttributes({'is_subscribed': false, 'plan': 'free'}).changed, isTrue);
      expect(sdk.mergeAttributes({'is_subscribed': false}).changed, isFalse);
      expect(sdk.mergeAttributes({'plan': null, 'snaps': 3}).changed, isTrue);
      expect(sdk.mergeAttributes({'missing': null}).changed, isFalse);

      expect(engine().attributes, {'is_subscribed': false, 'snaps': 3});
    });

    test('only strings, numbers and booleans are accepted', () {
      final sdk = engine();
      final result = sdk.mergeAttributes({'ok': 'yes', 'list': [1], 'map': {}, 'nan': double.nan});

      expect(result.changed, isTrue);
      expect(result.rejected, ['list', 'map', 'nan']);
      expect(sdk.attributes, {'ok': 'yes'});
    });

    test('changing attributes keeps counters; changing the person keeps attributes', () {
      final sdk = engine()..applyResponse(200, body([survey(1, min: 3)]));
      sdk.recordEvent('negative_id_feedback');
      sdk.mergeAttributes({'is_subscribed': true});

      expect(jsonDecode(store.values[SurveyEngine.countersKey]!), {
        '1': {'negative_id_feedback': 1},
      });
      sdk.setUserId('person-2');
      expect(sdk.attributes, {'is_subscribed': true});
    });
  });
}
