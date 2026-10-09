# MobSur Flutter SDK

Show [MobSur](https://mobsur.com) surveys in your Flutter app at the moments you choose, for example
right after someone reports a wrong result. You build and launch surveys in the MobSur dashboard;
your app only reports events.

## Install

```yaml
dependencies:
  mobsur_flutter_sdk: ^2.0.0
```

Requirements: Dart 3, Flutter 3.10 or newer, iOS and Android. Surveys are shown with
[`webview_flutter`](https://pub.dev/packages/webview_flutter), so your app follows its minimum
iOS and Android versions (Android API 21–24 depending on the `webview_flutter_android` version you
resolve).

## Set up

Call `setup` once, early. Pass the App ID from **Apps & setup** in the dashboard and a stable ID for
the person using your app.

```dart
import 'package:mobsur_flutter_sdk/mobsur_flutter_sdk.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MobSurSDK().setup('YOUR-APP-ID', currentUser?.id, navigatorKey: navigatorKey);
  runApp(MaterialApp(navigatorKey: navigatorKey, home: const HomePage()));
}
```

`setup` returns once saved state is loaded. It never waits for the network, so it is safe to await
before `runApp`.

### The user ID

MobSur uses this ID to sample your audience, to avoid asking someone who already answered, to apply
the time between surveys, and to count monthly tracked users for billing.

- Use an ID that stays the same for the same person, such as your account ID.
- If you don't have one yet, pass `null`. The SDK creates a random ID once and keeps it on the device.
- When the person signs in, call `MobSurSDK().updateClientId(accountId)`.
- Never pass a new random value on every launch. Every launch would look like a new person: people
  would be asked again after answering, and each launch would count as another tracked user.

## Report events

```dart
MobSurSDK().logEvent('negative_id_feedback');
```

If a live survey listens for that event name and its occurrence rule matches, the survey opens in a
sheet after the rule's delay. Pass a `BuildContext` as the second argument if you didn't give `setup`
a `navigatorKey`. Report events after your own dialogs close, so the survey isn't stacked on top of
them.

It is fine to report all your app's events. Only the ones used in the dashboard ever show a survey.

## How the dashboard settings behave

| Setting | What the SDK does |
|---|---|
| App event | Matched exactly, including case. |
| From / Through occurrence | The SDK counts each event per survey on the device, across launches. The survey can open when the count is inside this range, e.g. from 3 to ask after the third time. |
| Delay after event | Waits this long before opening. If the screen that reported the event is gone by then, nothing opens and a later event can try again. |
| Audience, platform, language, version, dates, response target, time between surveys | Applied by the server when the SDK fetches surveys. |

Also:

- At most one survey opens per app session.
- A survey the person finished never opens again.
- If the person closes a survey without finishing, a later session can show it again while the
  occurrence count is still inside the range. Set **Through occurrence** to limit repeats.
- The list of surveys is refreshed at launch, when the user ID changes, and every 6 hours after that.

## Debugging

```dart
await MobSurSDK().setup('YOUR-APP-ID', userId, debug: true);
```

Debug mode prints what the SDK does to the console with a `MobSur ::` prefix: surveys received,
events that did or didn't match, and why a survey wasn't shown. `MobSurSDK().availableSurveys()`
returns the surveys currently on the device.

The SDK never throws into your app. Calls made before `setup` finishes are ignored.

## Privacy

The SDK sends MobSur your App ID, the user ID, your app version, the platform, the device's preferred
languages and the SDK version. On the device it stores the survey list, event counts for those
surveys, finished survey IDs and the user ID in `SharedPreferences` under keys starting with `MobSur_`.

## Upgrading from 1.x

- Update the dependency to `^2.0.0`. Your `setup`, `updateClientId` and `logEvent(name, context)`
  calls keep working.
- 1.x could not read surveys launched from the current dashboard, so they never opened. 2.0 reads
  them, respects **From / Through occurrence** (1.x ignored it), and no longer reopens a survey on
  every event.
- `setup` now returns a `Future` and accepts `debug`, `navigatorKey` and `baseUrl`.
- `Survey.startDate` and `Survey.endDate` are nullable. `SurveyRule.occurred` is now a
  `SurveyOccurrence` with `min` and `max`.
- 2.0 needs Dart 3, `webview_flutter` 4 and `http` 0.13 or 1.x.

## Example

[`example/`](example) contains a small app that reports events. Run it with your App ID:

```sh
cd example
flutter run --dart-define=MOBSUR_APP_ID=YOUR-APP-ID
```
