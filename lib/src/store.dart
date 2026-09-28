import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// The small amount of state the SDK keeps between launches.
abstract class KeyValueStore {
  String? getString(String key);
  void setString(String key, String value);
  void remove(String key);
}

class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);

  // SharedPreferences updates its in-memory copy synchronously; the write to
  // disk finishes in the background.
  @override
  void setString(String key, String value) => unawaited(_prefs.setString(key, value));

  @override
  void remove(String key) => unawaited(_prefs.remove(key));
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  String? getString(String key) => values[key];

  @override
  void setString(String key, String value) => values[key] = value;

  @override
  void remove(String key) => values.remove(key);
}
