import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The user's Claude API key, kept in Android's encrypted storage (Keystore).
/// It never leaves the phone except in requests to api.anthropic.com.
abstract class ApiKeyStore {
  Future<String?> read();
  Future<void> write(String key);
  Future<void> clear();
}

class SecureApiKeyStore implements ApiKeyStore {
  SecureApiKeyStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();
  static const _key = 'anthropic_api_key';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String key) => _storage.write(key: _key, value: key.trim());

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class MemoryApiKeyStore implements ApiKeyStore {
  MemoryApiKeyStore([this._value]);
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String key) async => _value = key.trim();
  @override
  Future<void> clear() async => _value = null;
}
