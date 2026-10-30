import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobsur_flutter_sdk/src/models.dart';

Map<String, Object?> survey({
  Object? id = 7,
  Object? startDate = '2026-09-28T10:00:00+00:00',
  Object? endDate,
  List<Object?>? rules,
}) =>
    {
      'id': id,
      'url': 'https://web.mobsur.com/survey/$id?user_reference_id=u&app_version=1&platform=ios&app_id=a',
      'start_date': startDate,
      'end_date': endDate,
      'rules': rules ??
          [
            {
              'type': 'counted_event',
              'name': 'negative_id_feedback',
              'occurred': {'min': 1, 'max': null},
              'delay': 500
            },
          ],
    };

String body(List<Object?> surveys) => jsonEncode({'data': surveys});

void main() {
  test('parses what the current dashboard produces, including open-ended surveys', () {
    final surveys = parseSurveyList(body([survey()]))!;

    expect(surveys, hasLength(1));
    final parsed = surveys.single;
    expect(parsed.id, 7);
    expect(parsed.startDate, DateTime.utc(2026, 9, 28, 10));
    expect(parsed.endDate, isNull);
    expect(parsed.rules.single.name, 'negative_id_feedback');
    expect(parsed.rules.single.occurred!.min, 1);
    expect(parsed.rules.single.occurred!.max, isNull);
    expect(parsed.rules.single.delay, 500);
  });

  test('accepts null and partial occurrence windows and a missing delay', () {
    final parsed = parseSurveyList(body([
      survey(rules: [
        {'type': 'counted_event', 'name': 'a', 'occurred': null, 'delay': null},
        {
          'type': 'counted_event',
          'name': 'b',
          'occurred': {'max': 3}
        },
      ]),
    ]))!;

    final rules = parsed.single.rules;
    expect(rules[0].occurred, isNull);
    expect(rules[0].delay, 0);
    expect(rules[1].occurred!.min, isNull);
    expect(rules[1].occurred!.max, 3);
  });

  test('keeps unknown rule types in the model but never treats them as counted events', () {
    final parsed = parseSurveyList(body([
      survey(rules: [
        {'type': 'screen_view', 'name': 'home'},
        {'type': 'counted_event', 'name': 'home'},
      ]),
    ]))!;

    expect(parsed.single.rules.map((rule) => rule.isCountedEvent), [false, true]);
  });

  test('skips malformed surveys without losing the others, in server order', () {
    final parsed = parseSurveyList(body([
      survey(id: 3),
      survey(id: 'x'),
      {'id': 4},
      survey(id: 5, endDate: 'next tuesday'),
      'nonsense',
      survey(id: 1),
    ]))!;

    expect(parsed.map((survey) => survey.id), [3, 1]);
  });

  test('treats anything that is not the survey document as unusable', () {
    expect(parseSurveyList('<html>Wi-Fi login</html>'), isNull);
    expect(parseSurveyList('{"message":"nope"}'), isNull);
    expect(parseSurveyList('{"data":{}}'), isNull);
    expect(parseSurveyList('{"data":[]}'), isEmpty);
  });

  test('occurrence windows default to the first occurrence and include both bounds', () {
    const open = SurveyRule(type: 'counted_event', name: 'e');
    const fromThird = SurveyRule(type: 'counted_event', name: 'e', occurred: SurveyOccurrence(min: 3));
    const secondToFourth = SurveyRule(type: 'counted_event', name: 'e', occurred: SurveyOccurrence(min: 2, max: 4));

    expect([1, 2, 9].map(open.allows), [true, true, true]);
    expect([2, 3, 4].map(fromThird.allows), [false, true, true]);
    expect([1, 2, 4, 5].map(secondToFourth.allows), [false, true, true, false]);
  });

  test('active dates treat null bounds as open', () {
    final now = DateTime.utc(2026, 9, 28, 12);
    expect(Survey(id: 1, url: 'u').isActiveAt(now), isTrue);
    expect(Survey(id: 1, url: 'u', startDate: now.add(const Duration(minutes: 1))).isActiveAt(now), isFalse);
    expect(Survey(id: 1, url: 'u', endDate: now).isActiveAt(now), isFalse);
    expect(Survey(id: 1, url: 'u', endDate: now.add(const Duration(minutes: 1))).isActiveAt(now), isTrue);
  });

  test('round-trips through the cache format', () {
    final original = parseSurveyList(body([survey(endDate: '2026-10-28T10:00:00+00:00')]))!;
    final restored = parseSurveyList(jsonEncode({'data': original.map((s) => s.toJson()).toList()}))!;

    expect(restored.single.toJson(), original.single.toJson());
    expect(restored.single.endDate, DateTime.utc(2026, 10, 28, 10));
  });

  group('experiments', () {
    Map<String, Object?> experiment({Object? id = 'exp_01', Object? arm = 'treatment', Object? message = ''}) => {
          'id': id,
          'arm': arm,
          'start_date': '2026-10-31T00:00:00+00:00',
          'end_date': null,
          'rules': [
            {
              'type': 'counted_event',
              'name': 'Snap_Results_Viewed',
              'occurred': {'min': 3, 'max': null},
              'delay': 800
            },
          ],
          'message': message == ''
              ? {
                  'title': 'Know every plant you meet',
                  'body': 'Unlimited identifications and plant care plans with Premium.',
                  'cta_label': 'Try Premium free',
                  'cta_action': 'plantsnap://paywall?placement=mob_exp_01',
                  'dismiss_label': 'Not now',
                  'image_url': null,
                }
              : message,
        };

    String withExperiments(Object? experiments) => jsonEncode({'data': [], 'experiments': experiments});

    test('parses the contract example for both arms', () {
      final parsed = parseExperimentList(withExperiments([
        experiment(),
        experiment(id: 'exp_02', arm: 'control', message: null),
      ]))!;

      final treatment = parsed[0];
      expect(treatment.id, 'exp_01');
      expect(treatment.arm, Experiment.treatment);
      expect(treatment.isControl, isFalse);
      expect(treatment.startDate, DateTime.utc(2026, 10, 31));
      expect(treatment.endDate, isNull);
      expect(treatment.rules.single.name, 'Snap_Results_Viewed');
      expect(treatment.rules.single.occurred!.min, 3);
      expect(treatment.rules.single.delay, 800);
      expect(treatment.message!.title, 'Know every plant you meet');
      expect(treatment.message!.ctaAction, 'plantsnap://paywall?placement=mob_exp_01');
      expect(treatment.message!.dismissLabel, 'Not now');
      expect(treatment.message!.imageUrl, isNull);

      expect(parsed[1].isControl, isTrue);
      expect(parsed[1].message, isNull);
    });

    test('a missing or malformed experiments key means none, so old servers keep working', () {
      expect(parseExperimentList('{"data":[]}'), isEmpty);
      expect(parseExperimentList(withExperiments({'nope': 1})), isEmpty);
      expect(parseExperimentList('<html>Wi-Fi login</html>'), isNull);
      expect(parseExperimentList('{"experiments":[]}'), isNull);
    });

    test('skips unusable experiments without losing the others, in server order', () {
      final parsed = parseExperimentList(withExperiments([
        experiment(id: 'a'),
        experiment(id: 7),
        experiment(id: 'b', arm: 'holdout'),
        experiment(id: 'c', message: null), // treatment needs a message
        experiment(id: 'd', message: {'title': 'No call to action'}),
        'nonsense',
        experiment(id: 'e', arm: 'control', message: {'title': 'ignored'}),
      ]))!;

      expect(parsed.map((e) => e.id), ['a', 'e']);
      expect(parsed[1].message, isNull);
    });

    test('round-trips through the cache format', () {
      final original = parseExperimentList(withExperiments([experiment()]))!;
      final restored = parseExperimentList(withExperiments(original.map((e) => e.toJson()).toList()))!;

      expect(restored.single.toJson(), original.single.toJson());
    });
  });
}
