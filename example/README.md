# MobSur SDK example

Reports events to the MobSur Flutter SDK so you can check a survey end to end.

```sh
flutter run --dart-define=MOBSUR_APP_ID=YOUR-APP-ID
```

To test against a local MobSur server, add `--dart-define=MOBSUR_BASE_URL=http://localhost:8095/`.
The example allows plain HTTP only to local addresses (iOS) and only in debug builds (Android).
