import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobsur_flutter_sdk/mobsur_flutter_sdk.dart';
import 'package:mobsur_flutter_sdk/src/survey_sheet.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

const appId = 'afb605c0-0000-4000-8000-000000000000';

String surveysBody({String event = 'negative_id_feedback', int delay = 0}) => jsonEncode({
      'data': [
        {
          'id': 42,
          'url':
              'https://web.mobsur.com/survey/42?user_reference_id=u&app_version=7.6.9&platform=android&app_id=$appId',
          'start_date': '2026-01-01T00:00:00+00:00',
          'end_date': null,
          'rules': [
            {
              'type': 'counted_event',
              'name': event,
              'occurred': {'min': 1, 'max': null},
              'delay': delay
            },
          ],
        },
      ],
    });

void main() {
  late List<http.Request> requests;
  late FakeWebViewPlatform webViews;
  final logs = <String>[];

  setUp(() {
    requests = [];
    logs.clear();
    webViews = FakeWebViewPlatform();
    WebViewPlatform.instance = webViews;
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'PlantSnap',
      packageName: 'com.plantsnap',
      version: '7.6.9',
      buildNumber: '651354',
      buildSignature: '',
    );
    MobSurSDK().resetForTesting();
    MobSurSDK.httpClientOverride = MockClient((request) async {
      requests.add(request);
      return http.Response(surveysBody(), 200, headers: {'content-type': 'application/json'});
    });
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  // Only in plain tests: widget tests fail when debugPrint is replaced.
  void captureLogs() {
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    addTearDown(() => debugPrint = original);
  }

  test('requests surveys with the contract parameters', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await MobSurSDK().setup(appId, 'user-1');
    await MobSurSDK().pendingFetch;

    final request = requests.single;
    expect(request.url.origin, 'https://api.mobsur.com');
    expect(request.url.path, '/api/surveys');
    expect(request.url.queryParameters, {
      'app_id': appId,
      'user_reference_id': 'user-1',
      'app_version': '7.6.9',
      'platform': 'ios',
      'sdk': 'flutter-${MobSurSDK.version}',
    });
    expect(request.headers['Accept-Language'], isNotEmpty);
    expect(MobSurSDK().availableSurveys()!.single.id, 42);
  });

  test('keeps one generated ID per install when the app has none', () async {
    await MobSurSDK().setup(appId, null);
    await MobSurSDK().pendingFetch;
    MobSurSDK().resetForTesting();
    await MobSurSDK().setup(appId, '  ');
    await MobSurSDK().pendingFetch;

    final ids = requests.map((r) => r.url.queryParameters['user_reference_id']).toList();
    expect(ids[0], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(ids[1], ids[0]);
  });

  test('a user ID given before setup finishes is used by setup', () async {
    MobSurSDK().updateClientId('signed-in');
    await MobSurSDK().setup(appId, null);
    await MobSurSDK().pendingFetch;

    expect(requests.single.url.queryParameters['user_reference_id'], 'signed-in');
  });

  test('changing the user refetches for the new person', () async {
    await MobSurSDK().setup(appId, 'a');
    await MobSurSDK().pendingFetch;
    MobSurSDK().updateClientId('a');
    MobSurSDK().updateClientId('b');
    await MobSurSDK().pendingFetch;

    expect(requests.map((r) => r.url.queryParameters['user_reference_id']), ['a', 'b']);
  });

  test('never throws into the app', () async {
    captureLogs();
    MobSurSDK().logEvent('before_setup');
    MobSurSDK.httpClientOverride = MockClient((_) async => throw http.ClientException('offline'));
    await MobSurSDK().setup(appId, 'user-1', debug: true);
    await MobSurSDK().pendingFetch;
    MobSurSDK().logEvent('negative_id_feedback');

    expect(logs, contains('MobSur :: Surveys not updated: the server could not be reached.'));
  });

  test('the usage-limit response empties the list', () async {
    captureLogs();
    await MobSurSDK().setup(appId, 'user-1', debug: true);
    await MobSurSDK().pendingFetch;
    MobSurSDK.httpClientOverride = MockClient((_) async => http.Response('{"message":"MTU limit"}', 403));
    MobSurSDK().resetForTesting();
    await MobSurSDK().setup(appId, 'user-1', debug: true);
    await MobSurSDK().pendingFetch;

    expect(MobSurSDK().availableSurveys(), isEmpty);
    expect(logs.last, 'MobSur :: No surveys: the server answered 403. MTU limit');
  });

  testWidgets('an event opens the survey; Finish closes it and it never returns', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const Scaffold()));
    await tester.runAsync(() async {
      await MobSurSDK().setup(appId, 'user-1', navigatorKey: navigator);
      await MobSurSDK().pendingFetch;
    });

    MobSurSDK().logEvent('negative_id_feedback');
    await pumpSheet(tester);
    expect(find.byType(SurveySheet), findsOneWidget);
    expect(webViews.controller!.loaded.toString(), startsWith('https://web.mobsur.com/survey/42?'));

    final decision = await webViews.delegate!.onNavigationRequest!(const NavigationRequest(
      url: 'https://web.mobsur.com/survey/success/42?close=1#close',
      isMainFrame: true,
    ));
    await tester.pumpAndSettle();

    expect(decision, NavigationDecision.prevent);
    expect(find.byType(SurveySheet), findsNothing);
    expect(MobSurSDK().availableSurveys(), isEmpty);
  });

  testWidgets('closing early keeps the survey but nothing else shows this session', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const Scaffold()));
    await tester.runAsync(() async {
      await MobSurSDK().setup(appId, 'user-1', navigatorKey: navigator);
      await MobSurSDK().pendingFetch;
    });

    MobSurSDK().logEvent('negative_id_feedback');
    await pumpSheet(tester);
    await tester.tap(find.byIcon(Icons.close));
    await pumpSheet(tester);
    expect(find.byType(SurveySheet), findsNothing);
    MobSurSDK().logEvent('negative_id_feedback');
    await pumpSheet(tester);

    expect(find.byType(SurveySheet), findsNothing);
    expect(MobSurSDK().availableSurveys()!.single.id, 42);
  });

  testWidgets('the success page marks completion without closing', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const Scaffold()));
    await tester.runAsync(() async {
      await MobSurSDK().setup(appId, 'user-1', navigatorKey: navigator);
      await MobSurSDK().pendingFetch;
    });

    MobSurSDK().logEvent('negative_id_feedback');
    await pumpSheet(tester);
    webViews.delegate!.onPageFinished!('https://web.mobsur.com/survey/success/42');
    await tester.pumpAndSettle();

    expect(find.byType(SurveySheet), findsOneWidget);
    expect(MobSurSDK().availableSurveys(), isEmpty);
  });

  testWidgets('waits for the rule delay before opening', (tester) async {
    MobSurSDK.httpClientOverride = MockClient((_) async => http.Response(surveysBody(delay: 2000), 200));
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.runAsync(() async {
      await MobSurSDK().setup(appId, 'user-1');
      await MobSurSDK().pendingFetch;
    });
    final context = tester.element(find.byType(Scaffold));

    MobSurSDK().logEvent('negative_id_feedback', context);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.byType(SurveySheet), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    await pumpSheet(tester);
    expect(find.byType(SurveySheet), findsOneWidget);
  });

  testWidgets('a context that goes away during the delay shows nothing, and a later event can', (tester) async {
    MobSurSDK.httpClientOverride = MockClient((_) async => http.Response(surveysBody(delay: 500), 200));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('results', key: ValueKey('results')))));
    await tester.runAsync(() async {
      await MobSurSDK().setup(appId, 'user-1');
      await MobSurSDK().pendingFetch;
    });

    MobSurSDK().logEvent('negative_id_feedback', tester.element(find.text('results')));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('camera', key: ValueKey('camera')))));
    await pumpSheet(tester);
    expect(find.byType(SurveySheet), findsNothing);

    MobSurSDK().logEvent('negative_id_feedback', tester.element(find.text('camera')));
    await pumpSheet(tester);
    expect(find.byType(SurveySheet), findsOneWidget);
  });
}

/// Runs the pending delay and the sheet's entry animation.
Future<void> pumpSheet(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class FakeWebViewPlatform extends WebViewPlatform {
  FakeController? controller;
  FakeNavigationDelegate? delegate;

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) =>
      controller = FakeController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      delegate = FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      FakeWebViewWidget(params);
}

class FakeController extends PlatformWebViewController {
  FakeController(super.params) : super.implementation();

  Uri? loaded;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async => loaded = params.uri;
}

class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageFinished;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async =>
      this.onNavigationRequest = onNavigationRequest;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async => this.onPageFinished = onPageFinished;

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async {}
}

class FakeWebViewWidget extends PlatformWebViewWidget {
  FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
