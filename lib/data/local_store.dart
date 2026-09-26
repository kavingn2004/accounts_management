import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'finance_repository.dart';

/// Persists each "table" as a JSON array string in shared_preferences
/// (NSUserDefaults on iOS, SharedPreferences on Android, localStorage on web).
/// Also stores a couple of plain settings (profile name).
class LocalStore {
  LocalStore(this._prefs);
  final SharedPreferences _prefs;

  static const _tablePrefix = 'tbl_';

  /// Namespace for cached mutual-fund NAV history, one key per scheme code.
  /// Kept apart from `tbl_` because it is derived data, not user data: it can
  /// be thrown away and refetched, and it must never appear as a "table".
  static const _navPrefix = 'nav_';
  static const _nameKey = 'profile_name';
  static const _seededKey = 'seeded_v1';

  /// Recent user actions for the History screen (see [HistoryLog]).
  static const _historyKey = 'history_log';

  List<Json> read(String table) {
    final raw = _prefs.getString('$_tablePrefix$table');
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List;
    return decoded.map((e) => Json.from(e as Map)).toList();
  }

  Future<void> write(String table, List<Json> rows) async {
    await _prefs.setString('$_tablePrefix$table', jsonEncode(rows));
  }

  /// Raw cached NAV blob for a scheme, or null when nothing is stored.
  String? readNav(String key) => _prefs.getString('$_navPrefix$key');

  Future<void> writeNav(String key, String json) =>
      _prefs.setString('$_navPrefix$key', json);

  Future<void> removeNav(String key) => _prefs.remove('$_navPrefix$key');

  List<Json> readHistory() {
    final raw = _prefs.getString(_historyKey);
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List).map((e) => Json.from(e as Map)).toList();
  }

  Future<void> writeHistory(List<Json> entries) =>
      _prefs.setString(_historyKey, jsonEncode(entries));

  String get name => _prefs.getString(_nameKey) ?? 'You';
  Future<void> setName(String value) => _prefs.setString(_nameKey, value);

  bool get isSeeded => _prefs.getBool(_seededKey) ?? false;
  Future<void> markSeeded() => _prefs.setBool(_seededKey, true);

  /// Wipe all app data (factory reset).
  ///
  /// Cached NAV history goes too: leaving it behind would orphan megabytes of
  /// scheme data belonging to holdings that no longer exist.
  Future<void> clearAll() async {
    final keys = _prefs.getKeys().where(
        (k) => k.startsWith(_tablePrefix) || k.startsWith(_navPrefix));
    for (final k in keys) {
      await _prefs.remove(k);
    }
    await _prefs.remove(_seededKey);
    // Undoing an action on data that no longer exists would resurrect it.
    await _prefs.remove(_historyKey);
  }
}
