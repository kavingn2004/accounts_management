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
  static const _nameKey = 'profile_name';
  static const _seededKey = 'seeded_v1';

  List<Json> read(String table) {
    final raw = _prefs.getString('$_tablePrefix$table');
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List;
    return decoded.map((e) => Json.from(e as Map)).toList();
  }

  Future<void> write(String table, List<Json> rows) async {
    await _prefs.setString('$_tablePrefix$table', jsonEncode(rows));
  }

  String get name => _prefs.getString(_nameKey) ?? 'You';
  Future<void> setName(String value) => _prefs.setString(_nameKey, value);

  bool get isSeeded => _prefs.getBool(_seededKey) ?? false;
  Future<void> markSeeded() => _prefs.setBool(_seededKey, true);

  /// Wipe all app data (factory reset).
  Future<void> clearAll() async {
    final keys = _prefs.getKeys().where((k) => k.startsWith(_tablePrefix));
    for (final k in keys) {
      await _prefs.remove(k);
    }
    await _prefs.remove(_seededKey);
  }
}
