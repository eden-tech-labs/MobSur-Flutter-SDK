# MobSur Flutter SDK

Show [MobSur](https://mobsur.com) surveys and in-app message experiments in your Flutter app at the
moments you choose, for example right after someone reports a wrong result. You build and launch
surveys in the MobSur dashboard; your app only reports events.

## Install

```yaml
dependencies:
  mobsur_flutter_sdk: ^2.1.1
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

## In-app message experiments

An experiment shows a short message (title, body, optional image, a call-to-action and a dismiss
button) when an event happens, and keeps a holdout group that sees nothing, so you can measure
whether the message works. The server assigns each person to `treatment` or `control`.

- **treatment:** after the rule's delay, the message opens in a bottom sheet styled by your app's
  theme.
- **control:** nothing is shown, but the SDK still records that the message *would* have been shown.
  This also uses up the session's slot, so both groups see the same number of other surveys and
  messages.

Experiments are checked before surveys, use the same occurrence rules, and share the one-per-session
limit with surveys. Each experiment runs at most once per person on the device, even if they switch
accounts and come back.

### Attributes

The server picks which experiments a person is in from the attributes your app sets:

```dart
MobSurSDK().setAttributes({'is_subscribed': false});
```

Values can be strings, numbers or booleans. They are merged with the ones you set before and kept
on the device. Pass `null` to remove one. When a value changes, the SDK fetches again; event counts
are kept. No experiment runs until that fetch succeeds, because the saved ones were chosen for the
old values. Attributes set before `setup` finishes are applied by `setup`.

### Handling the call-to-action

```dart
await MobSurSDK().setup(
  'YOUR-APP-ID',
  userId,
  navigatorKey: navigatorKey,
  onAction: (action) => router.open(action), // e.g. 'myapp://paywall?placement=welcome'
);
```

`onAction` is called after the sheet closes. Without it, the SDK opens the action as a URL with
[`url_launcher`](https://pub.dev/packages/url_launcher).

### Keeping messages off your own screens

Your app may show its own full-screen UI (a paywall, a purchase flow) during the rule's delay. Tell
the SDK when it must not show anything:

```dart
await MobSurSDK().setup(
  'YOUR-APP-ID',
  userId,
  canShowOverlay: () => !paywallIsOpen,
);
```

It is checked right before a survey or message would appear. When it returns `false`, nothing
appears or is reported, and a later event can try again. This applies to both experiment groups,
so they stay comparable.

### Reporting

The SDK reports `exposed`, `cta_tapped` and `dismissed` to MobSur. Reports are saved on the device
and retried until the server has them, so a flaky connection doesn't lose them, and each one goes to
the server it was made for, even if a later `setup` uses another `baseUrl`. A report the server keeps
refusing for 7 days is dropped, so it can't block the ones behind it; time offline doesn't count.

## Debugging

```dart
await MobSurSDK().setup('YOUR-APP-ID', userId, debug: true);
```

Debug mode prints what the SDK does to the console with a `MobSur ::` prefix: surveys received,
events that did or didn't match, and why a survey wasn't shown. `MobSurSDK().availableSurveys()`
and `MobSurSDK().availableExperiments()` return what is currently on the device.

The SDK never throws into your app. Calls made before `setup` finishes are ignored.

## Privacy

The SDK sends MobSur your App ID, the user ID, your app version, the platform, the device's preferred
languages, the SDK version and the attributes you set. For experiments it also sends which group the
person is in and when they saw, tapped or dismissed the message. On the device it stores the survey
and experiment lists, event counts for them, finished survey and experiment IDs, your attributes,
unsent experiment reports and the user ID in `SharedPreferences` under keys starting with `MobSur_`.

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
