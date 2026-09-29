## 2.0.0

* Reads surveys from the current MobSur dashboard. 1.x failed to parse any survey whose rule had an
  occurrence range (every survey launched from today's dashboard) and any survey without an end date,
  so no survey opened.
* Respects the dashboard's **From / Through occurrence** range, counting events per survey across
  launches. 1.x opened the survey on every matching event.
* Opens at most one survey per app session and never reopens a finished survey.
* Detects a finished survey whether or not it has a thank-you page, and closes the sheet.
* Keeps the server's priority order.
* Creates and keeps a random user ID when the app passes `null`.
* Refreshes surveys when the user ID changes and every 6 hours; ignores responses fetched for a
  previous user.
* Keeps the cached list through network errors, server errors and captive-portal pages; clears it
  when the server rejects the request (for example, over the plan's user limit).
* `logEvent` can be called without a `BuildContext` when `setup` gets a `navigatorKey`. It waits for
  the rule's delay and skips the survey if that screen has gone.
* New `setup` options: `debug`, `navigatorKey`, `baseUrl`. `setup` returns a `Future`.
* Never throws into the host app.
* Sends the preferred languages as `Accept-Language` and `sdk=flutter-2.0.0` with each request.
* Requires Dart 3 and Flutter 3.10. Uses `webview_flutter` 4, supports `http` 0.13 and 1.x and
  `package_info_plus` 4–10.
* **Breaking:** `Survey.startDate` / `endDate` are nullable and `SurveyRule.occurred` is a
  `SurveyOccurrence`.
* Adds an example app and offline tests.

## 1.0.4

* Updated README with Android min sdk versions

## 1.0.3

* Bugfix: Handling of null value for the delay property

## 1.0.2

* Fixed typos in the README file

## 1.0.1

* Updated documentation
* Added app version and language as dynamic parameters

## 1.0.0

* Initial release.
