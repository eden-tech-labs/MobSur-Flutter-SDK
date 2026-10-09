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
    expect(decision.survey.id, 1);
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
    expect(engine().recordEvent('negative_id_feedback')?.survey.id, 1); // 3
    expect(engine().recordEvent('negative_id_feedback')?.survey.id, 1); // 4
    expect(engine().recordEvent('negative_id_feedback'), isNull); // 5
  });

  test('shows at most one survey per session; pending and shown both block', () {
    final sdk = engine()..applyResponse(200, body([survey(1), survey(2)]));

    expect(sdk.recordEvent('negative_id_feedback')?.survey.id, 1);
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
    expect(sdk.recordEvent('negative_id_feedback')?.survey.id, 1);
  });

  test('uses server order and only counts up to the survey it shows', () {
    final sdk = engine()..applyResponse(200, body([survey(9, min: 2), survey(4), survey(6)]));

    expect(sdk.recordEvent('negative_id_feedback')?.survey.id, 4);
    expect(jsonDecode(store.values[SurveyEngine.countersKey]!), {
      '9': {'negative_id_feedback': 1},
      '4': {'negative_id_feedback': 1},
    });
  });

  test('skips surveys outside their dates', () {
    final sdk = engine()..applyResponse(200, body([survey(1, end: '2026-09-28T11:59:59+00:00'), survey(2)]));

    expect(sdk.recordEvent('negative_id_feedback')?.survey.id, 2);
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
}
