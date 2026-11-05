import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobsur_flutter_sdk/mobsur_flutter_sdk.dart';
import 'package:mobsur_flutter_sdk/src/message_sheet.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const appId = 'afb605c0-0000-4000-8000-000000000000';
const event = 'Snap_Results_Viewed';

Map<String, Object?> experiment({String arm = 'treatment', int delay = 0, int min = 1}) => {
      'id': 'exp_01JB',
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
          : {
              'title': 'Know every plant you meet',
              'body': 'Unlimited identifications and plant care plans with Premium.',
              'cta_label': 'Try Premium free',
              'cta_action': 'plantsnap://paywall?placement=mob_exp_01',
              'dismiss_label': 'Not now',
              'image_url': null,
            },
    };

/// A survey on the same event, to check the shared one-per-session slot.
Map<String, Object?> survey() => {
      'id': 42,
      'url': 'https://web.mobsur.com/survey/42',
      'start_date': '2026-01-01T00:00:00+00:00',
      'end_date': null,
      'rules': [
        {'type': 'counted_event', 'name': event, 'occurred': null, 'delay': 0},
      ],
    };

void main() {
  late List<http.Request> requests;
  late List<Map<String, Object?>> experiments;
  late List<Map<String, Object?>> surveys;
  late int eventStatus;
  late int fetchStatus;

  List<http.Request> fetches() => requests.where((r) => r.method == 'GET').toList();
  List<Map<String, dynamic>> events() => [
        for (final r in requests)
          if (r.method == 'POST') jsonDecode(r.body) as Map<String, dynamic>,
      ];

  setUp(() {
    requests = [];
    experiments = [experiment()];
    surveys = [];
    eventStatus = 202;
    fetchStatus = 200;
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'PlantSnap',
      packageName: 'com.plantsnap',
      version: '8.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
    MobSurSDK().resetForTesting();
    MobSurSDK.launchUrlOverride = null;
    MobSurSDK.httpClientOverride = MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST') return http.Response('', eventStatus);
      return http.Response(jsonEncode({'data': surveys, 'experiments': experiments}), fetchStatus);
    });
  });

  group('attributes', () {
    test('are sent as JSON and a change refetches', () async {
      await MobSurSDK().setup(appId, 'firebase-uid');
      await MobSurSDK().pendingFetch;
      expect(fetches().single.url.queryParameters.containsKey('attributes'), isFalse);

      MobSurSDK().setAttributes({'is_subscribed': false, 'snaps': 3});
      await MobSurSDK().pendingFetch;
      MobSurSDK().setAttributes({'is_subscribed': false}); // unchanged: no fetch
      await MobSurSDK().pendingFetch;
      MobSurSDK().setAttributes({'snaps': null});
      await MobSurSDK().pendingFetch;

      final sent = fetches().skip(1).map((r) => r.url.queryParameters['attributes']).toList();
      expect(sent, ['{"is_subscribed":false,"snaps":3}', '{"is_subscribed":false}']);
      expect(fetches()[1].url.query, contains('attributes=%7B%22is_subscribed%22%3Afalse%2C%22snaps%22%3A3%7D'));
    });

    test('set before setup are used by the first fetch and kept across launches', () async {
      MobSurSDK().setAttributes({'is_subscribed': true});
      await MobSurSDK().setup(appId, 'firebase-uid');
      await MobSurSDK().pendingFetch;
      MobSurSDK().resetForTesting();
      await MobSurSDK().setup(appId, 'firebase-uid');
      await MobSurSDK().pendingFetch;

      expect(fetches().map((r) => r.url.queryParameters['attributes']),
          ['{"is_subscribed":true}', '{"is_subscribed":true}']);
    });

    test('a change does not reset event counts', () async {
      experiments = [experiment(min: 2)];
      await MobSurSDK().setup(appId, 'firebase-uid');
      await MobSurSDK().pendingFetch;
      MobSurSDK().logEvent(event);
      MobSurSDK().setAttributes({'is_subscribed': false});
      await MobSurSDK().pendingFetch;

      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('MobSur_experiment_counters')!), {
        'exp_01JB': {event: 1},
      });
    });

    test('ignore unsupported values and never throw', () async {
      await MobSurSDK().setup(appId, 'firebase-uid');
      await MobSurSDK().pendingFetch;
      MobSurSDK().setAttributes({'tags': ['a'], 'when': DateTime(2026)});
      await MobSurSDK().pendingFetch;

      expect(fetches(), hasLength(1));
    });

    test('experiments are parsed from the fetch', () async {
      await MobSurSDK().setup(appId, 'firebase-uid');
      await MobSurSDK().pendingFetch;

      final parsed = MobSurSDK().availableExperiments()!.single;
      expect(parsed.id, 'exp_01JB');
      expect(parsed.message!.ctaLabel, 'Try Premium free');
    });
  });

  group('running an experiment', () {
    final navigator = GlobalKey<NavigatorState>();
    late List<String> actions;

    Future<void> start(WidgetTester tester, {bool withOnAction = true}) async {
      actions = [];
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(colorSchemeSeed: Colors.green),
        home: const Scaffold(),
      ));
      await tester.runAsync(() async {
        await MobSurSDK().setup(
          appId,
          'firebase-uid',
          navigatorKey: navigator,
          onAction: withOnAction ? actions.add : null,
        );
        await MobSurSDK().pendingFetch;
      });
    }

    testWidgets('treatment shows the message and reports exposed', (tester) async {
      experiments = [experiment(delay: 800)];
      await start(tester);

      MobSurSDK().logEvent(event);
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(ExperimentSheet), findsNothing);
      await pumpSheet(tester);

      expect(find.byType(ExperimentSheet), findsOneWidget);
      expect(find.text('Know every plant you meet'), findsOneWidget);
      expect(find.text('Unlimited identifications and plant care plans with Premium.'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      final exposed = events().single;
      expect(exposed.keys.toSet(), {
        'event_id', 'app_id', 'user_reference_id', 'kind', 'arm', 'occurred_at', 'platform', 'app_version', 'sdk' //
      });
      expect(exposed['event_id'], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(exposed['app_id'], appId);
      expect(exposed['user_reference_id'], 'firebase-uid');
      expect(exposed['kind'], 'exposed');
      expect(exposed['arm'], 'treatment');
      expect(exposed['occurred_at'], matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')));
      expect(exposed['app_version'], '8.1.0');
      expect(exposed['sdk'], 'flutter-2.1.0');
      final post = requests.firstWhere((r) => r.method == 'POST');
      expect(post.url.toString(), 'https://api.mobsur.com/api/experiments/exp_01JB/events');
      expect(post.headers['Content-Type'], startsWith('application/json'));
      expect(MobSurSDK().availableExperiments(), isEmpty);
    });

    testWidgets('the CTA reports cta_tapped, closes the sheet, then calls onAction', (tester) async {
      await start(tester);
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);

      await tester.tap(find.text('Try Premium free'));
      await pumpSheet(tester);

      expect(find.byType(ExperimentSheet), findsNothing);
      expect(actions, ['plantsnap://paywall?placement=mob_exp_01']);
      expect(events().map((e) => e['kind']), ['exposed', 'cta_tapped']);
      expect(events().map((e) => e['event_id']).toSet(), hasLength(2));
    });

    testWidgets('without onAction the CTA is opened as a URL', (tester) async {
      final opened = <Uri>[];
      MobSurSDK.launchUrlOverride = (url) async {
        opened.add(url);
        return true;
      };
      await start(tester, withOnAction: false);
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      await tester.tap(find.text('Try Premium free'));
      await pumpSheet(tester);

      expect(opened, [Uri.parse('plantsnap://paywall?placement=mob_exp_01')]);
    });

    testWidgets('an onAction that throws stays inside the SDK', (tester) async {
      await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const Scaffold()));
      await tester.runAsync(() async {
        await MobSurSDK().setup(appId, 'firebase-uid',
            navigatorKey: navigator, onAction: (_) => throw StateError('host bug'));
        await MobSurSDK().pendingFetch;
      });
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      await tester.tap(find.text('Try Premium free'));
      await pumpSheet(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(ExperimentSheet), findsNothing);
    });

    testWidgets('the dismiss button and the back button report dismissed', (tester) async {
      await start(tester);
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      await tester.tap(find.text('Not now'));
      await pumpSheet(tester);

      expect(find.byType(ExperimentSheet), findsNothing);
      expect(actions, isEmpty);
      expect(events().map((e) => e['kind']), ['exposed', 'dismissed']);
    });

    testWidgets('a swipe or tap outside reports dismissed too', (tester) async {
      await start(tester);
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      navigator.currentState!.pop();
      await pumpSheet(tester);

      expect(events().map((e) => e['kind']), ['exposed', 'dismissed']);
    });

    testWidgets('it runs once per person', (tester) async {
      await start(tester);
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      await tester.tap(find.text('Not now'));
      await pumpSheet(tester);

      // A new app session, with a server that still returns it (exposure not yet received).
      await tester.runAsync(() async {
        MobSurSDK().resetForTesting();
        await MobSurSDK().setup(appId, 'firebase-uid', navigatorKey: navigator);
        await MobSurSDK().pendingFetch;
      });
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);

      expect(find.byType(ExperimentSheet), findsNothing);
      expect(events().where((e) => e['kind'] == 'exposed'), hasLength(1));
    });

    testWidgets('control shows nothing, reports exposed and uses the session slot', (tester) async {
      experiments = [experiment(arm: 'control', delay: 500)];
      surveys = [survey()];
      await start(tester);

      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      expect(find.byType(ExperimentSheet), findsNothing);
      expect(events().single['kind'], 'exposed');
      expect(events().single['arm'], 'control');

      // The survey listens for the same event, but the slot is used.
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(events(), hasLength(1));
    });

    testWidgets('treatment uses the session slot too', (tester) async {
      surveys = [survey()];
      await start(tester);
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      await tester.tap(find.text('Not now'));
      await pumpSheet(tester);

      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('neither arm is exposed when the UI is gone after the delay', (tester) async {
      for (final arm in ['treatment', 'control']) {
        requests.clear();
        MobSurSDK().resetForTesting();
        SharedPreferences.setMockInitialValues({});
        experiments = [experiment(arm: arm, delay: 500)];
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('results', key: ValueKey('results')))));
        await tester.runAsync(() async {
          await MobSurSDK().setup(appId, 'firebase-uid');
          await MobSurSDK().pendingFetch;
        });

        MobSurSDK().logEvent(event, tester.element(find.text('results')));
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('camera', key: ValueKey('camera')))));
        await pumpSheet(tester);

        expect(events(), isEmpty, reason: arm);
        expect(MobSurSDK().availableExperiments(), hasLength(1), reason: arm);
      }
    });

    testWidgets('an experiment waiting on its delay does not run for someone who just signed in', (tester) async {
      for (final arm in ['treatment', 'control']) {
        requests.clear();
        MobSurSDK().resetForTesting();
        SharedPreferences.setMockInitialValues({});
        experiments = [experiment(arm: arm, delay: 800)];
        await start(tester);

        MobSurSDK().logEvent(event);
        await tester.pump(const Duration(milliseconds: 100));
        experiments = []; // the new person isn't in it
        await tester.runAsync(() async {
          MobSurSDK().updateClientId('someone-else');
          await MobSurSDK().pendingFetch;
        });
        await pumpSheet(tester);

        expect(find.byType(ExperimentSheet), findsNothing, reason: arm);
        expect(events(), isEmpty, reason: arm);
      }
    });

    testWidgets('it runs for the new person if they are in the same arm, under their own ID', (tester) async {
      experiments = [experiment(delay: 800)];
      await start(tester);

      MobSurSDK().logEvent(event);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() async {
        MobSurSDK().updateClientId('someone-else');
        await MobSurSDK().pendingFetch;
      });
      await pumpSheet(tester);

      expect(find.byType(ExperimentSheet), findsOneWidget);
      expect(events().single['user_reference_id'], 'someone-else');
    });

    testWidgets('a different arm for the new person is not run with the old one', (tester) async {
      experiments = [experiment(delay: 800)];
      await start(tester);

      MobSurSDK().logEvent(event);
      await tester.pump(const Duration(milliseconds: 100));
      experiments = [experiment(arm: 'control', delay: 800)];
      await tester.runAsync(() async {
        MobSurSDK().updateClientId('someone-else');
        await MobSurSDK().pendingFetch;
      });
      await pumpSheet(tester);

      expect(find.byType(ExperimentSheet), findsNothing);
      expect(events(), isEmpty);
    });

    testWidgets('events from an open sheet stay with the person who saw it', (tester) async {
      experiments = [experiment()];
      await start(tester);

      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      expect(find.byType(ExperimentSheet), findsOneWidget);

      await tester.runAsync(() async {
        MobSurSDK().updateClientId('someone-else');
        await MobSurSDK().pendingFetch;
      });
      await tester.tap(find.text('Not now'));
      await pumpSheet(tester);
      await tester.runAsync(() => MobSurSDK().pendingEvents);

      final kinds = {for (final e in events()) e['kind']: e['user_reference_id']};
      expect(kinds['exposed'], 'firebase-uid');
      expect(kinds['dismissed'], 'firebase-uid');
    });

    testWidgets('someone who just subscribed is not shown a saved experiment', (tester) async {
      experiments = [experiment(delay: 800)];
      await start(tester);

      // Subscribes during the delay, and the fetch for the new value fails.
      MobSurSDK().logEvent(event);
      await tester.pump(const Duration(milliseconds: 100));
      fetchStatus = 500;
      await tester.runAsync(() async {
        MobSurSDK().setAttributes({'is_subscribed': true});
        await MobSurSDK().pendingFetch;
      });
      await pumpSheet(tester);
      expect(find.byType(ExperimentSheet), findsNothing);
      expect(events(), isEmpty);

      // Later events don't use the saved one either, until a fetch succeeds.
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      expect(find.byType(ExperimentSheet), findsNothing);
      expect(events(), isEmpty);
      expect(MobSurSDK().availableExperiments(), isEmpty);
    });

    testWidgets('a veto with a one-occurrence rule still lets a later event run it', (tester) async {
      experiments = [
        {
          ...experiment(),
          'rules': [
            {
              'type': 'counted_event',
              'name': event,
              'occurred': {'min': 1, 'max': 1},
              'delay': 0
            },
          ],
        },
      ];
      var allowed = false;
      await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const Scaffold()));
      await tester.runAsync(() async {
        await MobSurSDK().setup(appId, 'firebase-uid', navigatorKey: navigator, canShowOverlay: () => allowed);
        await MobSurSDK().pendingFetch;
      });

      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      expect(find.byType(ExperimentSheet), findsNothing);
      expect(events(), isEmpty);

      allowed = true;
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      expect(find.byType(ExperimentSheet), findsOneWidget);
    });

    testWidgets('canShowOverlay=false drops both arms without exposure or using the slot', (tester) async {
      for (final arm in ['treatment', 'control']) {
        requests.clear();
        MobSurSDK().resetForTesting();
        SharedPreferences.setMockInitialValues({});
        experiments = [experiment(arm: arm, delay: 800)];
        var allowed = false;
        var asked = 0;
        await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const Scaffold()));
        await tester.runAsync(() async {
          await MobSurSDK().setup(appId, 'firebase-uid', navigatorKey: navigator, canShowOverlay: () {
            asked++;
            return allowed;
          });
          await MobSurSDK().pendingFetch;
        });

        MobSurSDK().logEvent(event);
        await tester.pump(const Duration(milliseconds: 700));
        expect(asked, 0, reason: 'checked after the delay, not before');
        await pumpSheet(tester);
        expect(asked, 1);
        expect(find.byType(ExperimentSheet), findsNothing, reason: arm);
        expect(events(), isEmpty, reason: arm);
        expect(MobSurSDK().availableExperiments(), hasLength(1), reason: arm);

        // The slot is still free: the next event runs once the host allows it.
        allowed = true;
        MobSurSDK().logEvent(event);
        await pumpSheet(tester);
        expect(events().single['kind'], 'exposed', reason: arm);
        expect(find.byType(ExperimentSheet), arm == 'treatment' ? findsOneWidget : findsNothing);
        if (arm == 'treatment') {
          await tester.tap(find.text('Not now'));
          await pumpSheet(tester);
        }
      }
    });

    testWidgets('canShowOverlay also gates surveys', (tester) async {
      experiments = [];
      surveys = [survey()];
      await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const Scaffold()));
      await tester.runAsync(() async {
        await MobSurSDK().setup(appId, 'firebase-uid', navigatorKey: navigator, canShowOverlay: () => false);
        await MobSurSDK().pendingFetch;
      });
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);

      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('exposures the server cannot take yet are kept for later', (tester) async {
      eventStatus = 503;
      await start(tester);
      MobSurSDK().logEvent(event);
      await pumpSheet(tester);
      await tester.tap(find.text('Not now'));
      await pumpSheet(tester);

      final prefs = await SharedPreferences.getInstance();
      final queued = jsonDecode(prefs.getString('MobSur_experiment_events')!) as List;
      expect(queued.map((e) => e['body']['kind']), ['exposed', 'dismissed']);

      // The next launch delivers them with the same event IDs.
      eventStatus = 202;
      final queuedIds = queued.map((e) => e['body']['event_id']).toList();
      await tester.runAsync(() async {
        MobSurSDK().resetForTesting();
        await MobSurSDK().setup(appId, 'firebase-uid', navigatorKey: navigator);
        await MobSurSDK().pendingFetch;
        await MobSurSDK().pendingEvents;
      });
      MobSurSDK().resetForTesting(); // stops the retry timer
      expect(jsonDecode(prefs.getString('MobSur_experiment_events')!), isEmpty);
      final attempts = events().length;
      expect(events().skip(attempts - 2).map((e) => e['event_id']), queuedIds);
    });
  });
}

/// Runs the pending delay and the sheet's animations.
Future<void> pumpSheet(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
