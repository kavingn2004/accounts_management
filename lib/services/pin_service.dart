import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// On-device numeric PIN lock.
///
/// The PIN is never stored raw. We keep a random salt + sha256(salt:pin) in the
/// OS keychain (Keystore on Android, Keychain on iOS). The PIN gates access to
/// the already-authenticated Supabase session stored on the device.
class PinService {
  static const _storage = FlutterSecureStorage();
  static const _saltKey = 'pin_salt';
  static const _hashKey = 'pin_hash';

  Future<bool> hasPin() async =>
      (await _storage.read(key: _hashKey)) != null;

  Future<void> setPin(String pin) async {
    final salt = _randomSalt();
    await _storage.write(key: _saltKey, value: salt);
    await _storage.write(key: _hashKey, value: _hash(pin, salt));
  }

  Future<bool> verifyPin(String pin) async {
    final salt = await _storage.read(key: _saltKey);
    final hash = await _storage.read(key: _hashKey);
    if (salt == null || hash == null) return false;
    return _hash(pin, salt) == hash;
  }

  Future<void> clearPin() async {
    await _storage.delete(key: _saltKey);
    await _storage.delete(key: _hashKey);
  }

  String _randomSalt() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return base64Url.encode(bytes);
  }

  String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();
}
