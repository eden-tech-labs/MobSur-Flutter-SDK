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
}
